//
//  FrameSignals.swift
//  CameraCoach
//
//  Layer 1 output: the structured, numeric result of analyzing one camera
//  frame with the Vision framework. This is intentionally "dumb data" —
//  no natural language yet. CoachingEngine (Layer 2) turns this into words.
//

import Foundation
import CoreGraphics

struct FrameSignals: Equatable {

    /// Overall aesthetic quality, -1 (poor) to 1 (great).
    /// From Vision's CalculateImageAestheticsScoresRequest, which factors in
    /// blur, exposure, color balance, composition, and subject matter.
    var aestheticsScore: Double

    /// True if Vision thinks this is a "utility" shot (technically fine but
    /// forgettable — e.g. a screenshot or memo), as opposed to a genuinely
    /// well-composed photo.
    var isUtilityShot: Bool

    /// Horizon tilt in degrees. 0 = perfectly level. nil = no confident
    /// horizon line detected (e.g. indoors, close-up shots).
    var horizonAngleDegrees: Double?

    /// Where the main subject sits relative to frame center, from Vision's
    /// saliency (attention heatmap) analysis.
    /// x, y each range roughly -1...1. (0, 0) = dead center.
    /// Negative x = subject is left of center, positive = right.
    /// Negative y = subject is above center, positive = below.
    var subjectOffset: CGPoint?

    /// Face capture quality, 0...1, from DetectFaceCaptureQualityRequest.
    /// nil if no face is in frame.
    var faceQuality: Double?

    /// How many faces Vision found in frame.
    var faceCount: Int

    /// Current exposure bias reported by the capture device, in EV stops.
    /// Positive = camera is compensating brighter, negative = darker.
    var exposureBiasEV: Float

    /// When this analysis was produced.
    var timestamp: Date

    static let placeholder = FrameSignals(
        aestheticsScore: 0,
        isUtilityShot: false,
        horizonAngleDegrees: nil,
        subjectOffset: nil,
        faceQuality: nil,
        faceCount: 0,
        exposureBiasEV: 0,
        timestamp: .distantPast
    )
}
