//
//  CoachingEngine.swift
//  CameraCoach
//
//  Layer 2: turns Layer 1's numbers into a short, friendly sentence, using
//  Apple's on-device Foundation Models framework. Runs on a throttle
//  (minInterval), not on every frame — this is the "heavier" layer.
//
//  Requires: iPhone 15 Pro or newer (A17 Pro+), Apple Intelligence enabled
//  in Settings, iOS 26+ for text-only respond(), iOS 27+ for the image
//  attachment API used in requestTip(image:signals:) below.
//
//  NOTE ON API SURFACE: the `Prompt { }` builder and `Attachment(_:)` image
//  attachment initializer are new in the iOS 27 betas (WWDC26). Apple's own
//  materials flag these exact symbol names as subject to change during
//  beta. If `Attachment` doesn't resolve, check Xcode's autocomplete for
//  the current image-attachment type in your SDK — the rest of this file's
//  structure (Prompt builder + @Generable result type) should stay valid.
//

import FoundationModels
import UIKit
import Observation

@Generable
struct CoachingTip: Equatable {
    @Guide(description: "One short, warm, actionable photography tip, 12 words or fewer, phrased like a friend glancing at the viewfinder over your shoulder. No jargon, no numbers.")
    var tip: String

    @Guide(description: "True only if the shot is already well framed, well lit, and level enough to just take it now.")
    var readyToShoot: Bool
}

@available(iOS 26.0, *)
@MainActor
@Observable
final class CoachingEngine {

    var currentTip: String = "Getting a feel for the scene…"
    var readyToShoot: Bool = false
    var isModelAvailable: Bool = false
    var unavailableReason: String?

    private var session: LanguageModelSession?
    private var lastRequestTime: Date = .distantPast
    private var lastRequestedSignals: FrameSignals?
    private let minInterval: TimeInterval = 1.5
    private var activeTask: Task<Void, Never>?

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            isModelAvailable = true
            unavailableReason = nil
            let language = TipLanguage.resolved(
                UserDefaults.standard.string(forKey: "tipLanguage") ?? "auto")
            session = LanguageModelSession(
                instructions: """
                You are a friendly, concise photography coach watching the user's live \
                camera viewfinder. On each turn you'll receive a short set of measurements \
                about the current frame (an aesthetics score, horizon tilt, how far the main \
                subject sits from center, and face quality if a face is visible), plus the \
                frame itself. Give exactly one short, encouraging, actionable tip the person \
                can act on immediately — phrased naturally, never mentioning scores, angles, \
                or technical numbers. Write the tip in \(language). If the shot already \
                looks good, say so warmly and set readyToShoot to true.
                """
            )
        case .unavailable(let reason):
            isModelAvailable = false
            session = nil
            switch reason {
            case .deviceNotEligible:
                unavailableReason = "This device doesn't support on-device coaching (needs iPhone 15 Pro or newer)."
            case .appleIntelligenceNotEnabled:
                unavailableReason = "Turn on Apple Intelligence in Settings to get live coaching tips."
            case .modelNotReady:
                unavailableReason = "The on-device model is still preparing — try again shortly."
            @unknown default:
                unavailableReason = "Live coaching isn't available right now."
            }
        }
    }

    /// Call this periodically (e.g. from the frame pipeline). Internally
    /// throttled so it's safe to call more often than you actually want
    /// requests to fire.
    func maybeRequestTip(image: UIImage, signals: FrameSignals) {
        guard isModelAvailable, let session, !session.isResponding else { return }
        guard Date().timeIntervalSince(lastRequestTime) >= minInterval else { return }

        // Skip when the framing hasn't meaningfully changed. On-device
        // inference is free but not cheap in battery terms, so a still
        // scene shouldn't keep the Neural Engine busy.
        if let last = lastRequestedSignals, !Self.hasMeaningfulChange(from: last, to: signals) {
            return
        }
        lastRequestTime = Date()
        lastRequestedSignals = signals

        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.requestTip(session: session, signals: signals)
        }
    }

    /// Matches the remote engine's gate: a fresh tip is only worth producing
    /// when the score, tilt, subject position, or face count actually moved.
    private static func hasMeaningfulChange(from old: FrameSignals, to new: FrameSignals) -> Bool {
        if abs(new.aestheticsScore - old.aestheticsScore) >= 0.15 { return true }

        switch (old.horizonAngleDegrees, new.horizonAngleDegrees) {
        case let (o?, n?): if abs(n - o) >= 3.0 { return true }
        case (nil, nil): break
        default: return true
        }

        switch (old.subjectOffset, new.subjectOffset) {
        case let (o?, n?): if hypot(n.x - o.x, n.y - o.y) >= 0.15 { return true }
        case (nil, nil): break
        default: return true
        }

        return new.faceCount != old.faceCount
    }

    private func requestTip(session: LanguageModelSession, signals: FrameSignals) async {
        let horizonText = signals.horizonAngleDegrees.map { String(format: "%.1f degrees from level", $0) } ?? "no clear horizon"
        let subjectText = signals.subjectOffset.map { offset in
            String(format: "offset x=%.2f y=%.2f from center (-1 to 1 scale)", offset.x, offset.y)
        } ?? "no clear subject detected"
        let faceText = signals.faceCount > 0
            ? String(format: "%d face(s), quality %.2f (0-1 scale)", signals.faceCount, signals.faceQuality ?? 0)
            : "no faces in frame"

        // Text-only prompt: the iOS 27 beta image-attachment API
        // (Attachment(_:) inside the Prompt builder) isn't available in the
        // iOS 26 SDK, so we send just the FrameSignals summary. See README.
        let prompt = Prompt(
            """
            Aesthetics score (-1 to 1, higher is better): \(String(format: "%.2f", signals.aestheticsScore))
            Horizon: \(horizonText)
            Subject framing: \(subjectText)
            Faces: \(faceText)
            Exposure bias: \(String(format: "%.1f", signals.exposureBiasEV)) EV
            """
        )

        do {
            let response = try await session.respond(
                to: prompt,
                generating: CoachingTip.self,
                options: GenerationOptions(temperature: 0.4, maximumResponseTokens: 80)
            )
            guard !Task.isCancelled else { return }
            currentTip = response.content.tip
            readyToShoot = response.content.readyToShoot
        } catch is CancellationError {
            // A newer frame superseded this request — nothing to do.
        } catch {
            // Keep showing the previous tip rather than flashing an error
            // on every transient hiccup (e.g. a momentarily busy model).
        }
    }
}
