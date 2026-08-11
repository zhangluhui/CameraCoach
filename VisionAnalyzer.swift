//
//  VisionAnalyzer.swift
//  CameraCoach
//
//  Layer 1: fast, on-device Vision framework analysis. No LLM involved here
//  at all — this is pure computer vision, and it's what runs on every
//  sampled frame (see CameraSessionManager.frameStride).
//
//  NOTE ON API SURFACE: this file uses the Swift-concurrency-based Vision
//  API redesigned around iOS 18 (requests conform to a protocol and expose
//  `perform(on:)` directly, replacing the old VNImageRequestHandler +
//  completion-handler pattern). CalculateImageAestheticsScoresRequest and
//  the saliency/face-quality requests below are real, shipping APIs as of
//  iOS 18/26. Exact property names (e.g. on HorizonObservation) can vary
//  slightly by SDK version — if something doesn't compile, Option-click the
//  type in Xcode to see the exact property list for your SDK and adjust.
//

import Vision
import CoreImage
import CoreVideo

actor VisionAnalyzer {

    /// Runs the full Layer 1 analysis pass on one pixel buffer.
    /// All four requests run concurrently since they're independent.
    func analyze(pixelBuffer: CVPixelBuffer, exposureBiasEV: Float) async -> FrameSignals {
        async let aesthetics = aestheticsScore(pixelBuffer)
        async let horizon = horizonAngle(pixelBuffer)
        async let subject = subjectOffset(pixelBuffer)
        async let face = faceQuality(pixelBuffer)

        let (aestheticsResult, horizonResult, subjectResult, faceResult) =
            await (aesthetics, horizon, subject, face)

        return FrameSignals(
            aestheticsScore: aestheticsResult?.score ?? 0,
            isUtilityShot: aestheticsResult?.isUtility ?? false,
            horizonAngleDegrees: horizonResult,
            subjectOffset: subjectResult,
            faceQuality: faceResult?.quality,
            faceCount: faceResult?.count ?? 0,
            exposureBiasEV: exposureBiasEV,
            timestamp: Date()
        )
    }

    // MARK: - Aesthetics

    private func aestheticsScore(_ pixelBuffer: CVPixelBuffer) async -> (score: Double, isUtility: Bool)? {
        do {
            let request = CalculateImageAestheticsScoresRequest()
            let observation = try await request.perform(on: pixelBuffer)
            return (Double(observation.overallScore), observation.isUtility)
        } catch {
            return nil
        }
    }

    // MARK: - Horizon

    private func horizonAngle(_ pixelBuffer: CVPixelBuffer) async -> Double? {
        do {
            let request = DetectHorizonRequest()
            guard let observation = try await request.perform(on: pixelBuffer) else {
                return nil
            }
            // In the new Vision API, angle is a Measurement<UnitAngle>.
            return observation.angle.converted(to: .degrees).value
        } catch {
            return nil
        }
    }

    // MARK: - Subject framing (saliency)

    private func subjectOffset(_ pixelBuffer: CVPixelBuffer) async -> CGPoint? {
        do {
            let request = GenerateAttentionBasedSaliencyImageRequest()
            // perform(on:) and salientObjects are non-optional in the new API.
            let observation = try await request.perform(on: pixelBuffer)
            let salientObjects = observation.salientObjects
            guard !salientObjects.isEmpty else { return nil }

            // Average the centers of all salient regions, weighted by
            // confidence, to get one "where's the subject" point.
            var sumX: CGFloat = 0
            var sumY: CGFloat = 0
            var totalWeight: CGFloat = 0

            for object in salientObjects {
                let box = object.boundingBox.cgRect // NormalizedRect -> CGRect (0...1, origin bottom-left)
                let centerX = box.midX
                let centerY = box.midY
                let weight = CGFloat(object.confidence)
                sumX += centerX * weight
                sumY += centerY * weight
                totalWeight += weight
            }

            guard totalWeight > 0 else { return nil }

            let avgX = sumX / totalWeight
            let avgY = sumY / totalWeight

            // Convert from normalized 0...1 to a -1...1 offset from center,
            // and flip Y since Vision's origin is bottom-left, UI is top-left.
            let offsetX = (avgX - 0.5) * 2
            let offsetY = (0.5 - avgY) * 2

            return CGPoint(x: offsetX, y: offsetY)
        } catch {
            return nil
        }
    }

    // MARK: - Face quality

    private func faceQuality(_ pixelBuffer: CVPixelBuffer) async -> (quality: Double, count: Int)? {
        do {
            let request = DetectFaceCaptureQualityRequest()
            let observations = try await request.perform(on: pixelBuffer)
            guard !observations.isEmpty else { return (0, 0) }

            let qualities = observations.compactMap { $0.captureQuality?.score }
            guard !qualities.isEmpty else { return (0, observations.count) }

            let avg = qualities.reduce(0, +) / Float(qualities.count)
            return (Double(avg), observations.count)
        } catch {
            return nil
        }
    }
}
