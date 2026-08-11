//
//  RemoteCoachingEngine.swift
//  CameraCoach
//
//  Layer 2 alternative: instead of Apple's on-device Foundation Models,
//  send the frame signals to a user-provided OpenAI-compatible endpoint
//  (OpenAI, Ollama, LM Studio, or any server speaking /v1/chat/completions)
//  and parse the JSON tip it returns. Text-only, like the on-device path.
//

import UIKit
import Observation

@MainActor
@Observable
final class RemoteCoachingEngine: TipEngine {

    var currentTip: String = "Getting a feel for the scene…"
    var readyToShoot: Bool = false
    var isModelAvailable: Bool = true
    var unavailableReason: String?
    /// Live-togglable from the camera screen: attach the frame to requests?
    var sendsImage: Bool

    private let config: PersonalModelConfig
    private var lastRequestTime: Date = .distantPast
    /// Hard floor between requests, even if the scene keeps changing.
    private let minInterval: TimeInterval = 5.0
    private var inFlight = false
    private var hasSucceeded = false

    var isBusy: Bool { inFlight }
    /// Signals from the last request actually sent — used to skip requests
    /// entirely while the framing hasn't meaningfully changed, so holding
    /// the phone steady costs nothing.
    private var lastRequestedSignals: FrameSignals?
    /// 8×8 luma signature of the last-sent frame: motion detection that
    /// survives sensor noise. A phone left on a desk sends nothing.
    private var lastFrameSignature: [Float]?

    // Session usage tracking (reset each launch).
    private var totalRequests = 0
    private var totalPromptTokens = 0
    private var totalCompletionTokens = 0

    var usageSummary: String? {
        guard totalRequests > 0 else { return "0 requests" }
        let tokens = totalPromptTokens + totalCompletionTokens
        return "\(totalRequests) req · \(tokens) tok"
    }

    init(config: PersonalModelConfig) {
        self.config = config
        self.sendsImage = config.sendsImage
        if URL(string: config.baseURL) == nil || config.baseURL.isEmpty {
            isModelAvailable = false
            unavailableReason = "The AI model server URL is invalid — check it in Settings."
        } else if let url = URL(string: config.baseURL),
                  url.scheme?.lowercased() == "http",
                  !Self.isPrivateHost(url.host ?? "") {
            // Never let the API key travel unencrypted over the internet.
            isModelAvailable = false
            unavailableReason = "Plain http is only allowed for local/private servers — use https for internet endpoints."
        }
    }

    /// Local or private-range hosts where plain http is acceptable.
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    func maybeRequestTip(image: UIImage, signals: FrameSignals) {
        guard isModelAvailable, !inFlight else { return }
        guard Date().timeIntervalSince(lastRequestTime) >= minInterval else { return }

        // Change detection 1: skip when the numeric framing signals haven't
        // meaningfully changed since the last request we sent.
        if let last = lastRequestedSignals, !Self.hasMeaningfulChange(from: last, to: signals) {
            return
        }

        // Change detection 2: pixel-level motion check. Signal values can
        // jitter from sensor noise even on a completely static scene — the
        // frame signature can't. Both gates must open before we spend money.
        let signature = Self.signature(of: image)
        if let last = lastFrameSignature, let signature, !Self.framesDiffer(last, signature) {
            return
        }

        lastRequestTime = Date()
        lastRequestedSignals = signals
        lastFrameSignature = signature
        inFlight = true

        Task { [weak self] in
            guard let self else { return }
            await self.requestTip(image: image, signals: signals)
            self.inFlight = false
        }
    }

    // MARK: - Change detection

    /// Downsamples the frame to an 8×8 grid of average luma values.
    private static func signature(of image: UIImage) -> [Float]? {
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let ctx = CGContext(
            data: &pixels, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return (0..<64).map { i in
            (Float(pixels[i * 4]) + Float(pixels[i * 4 + 1]) + Float(pixels[i * 4 + 2])) / 3
        }
    }

    /// Mean absolute luma difference above ~3% of full scale counts as motion.
    private static func framesDiffer(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        let meanAbsDiff = zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(a.count)
        return meanAbsDiff > 8
    }

    /// True when the difference between two frames is worth a fresh tip:
    /// the aesthetics score shifted, the horizon tilted, the subject moved,
    /// or faces entered/left the frame.
    private static func hasMeaningfulChange(from old: FrameSignals, to new: FrameSignals) -> Bool {
        if abs(new.aestheticsScore - old.aestheticsScore) >= 0.15 { return true }

        switch (old.horizonAngleDegrees, new.horizonAngleDegrees) {
        case let (o?, n?):
            if abs(n - o) >= 3.0 { return true }
        case (nil, nil):
            break
        default:
            return true // horizon appeared or disappeared
        }

        switch (old.subjectOffset, new.subjectOffset) {
        case let (o?, n?):
            if hypot(n.x - o.x, n.y - o.y) >= 0.15 { return true }
        case (nil, nil):
            break
        default:
            return true // subject appeared or disappeared
        }

        if new.faceCount != old.faceCount { return true }

        return false
    }

    // MARK: - Request

    private struct ContentPart: Encodable {
        let type: String
        var text: String? = nil
        var image_url: ImageURL? = nil
        struct ImageURL: Encodable { let url: String }
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: [ContentPart]
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        // Note: no max_tokens or temperature — newer OpenAI/Azure models
        // (e.g. the GPT-5 family) reject non-default temperature and use
        // max_completion_tokens instead of max_tokens. Defaults work
        // everywhere, and the prompt already demands a tiny JSON response.
    }

    private struct APIErrorResponse: Decodable {
        struct APIError: Decodable { let message: String? }
        let error: APIError?
    }

    private enum RemoteError: Error {
        case http(Int, String)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let choices: [Choice]
        let usage: Usage?
    }

    private struct TipPayload: Decodable {
        let tip: String
        let readyToShoot: Bool
    }

    private var systemPrompt: String {
        let language = TipLanguage.resolved(config.tipLanguage)
        let styleRule = config.detailLevel == "detailed"
            ? "Give one focused critique of 2-3 short sentences covering the most important improvements (framing, light, background, timing) — plain language, encouraging, never mentioning scores, angles, or technical numbers."
            : "Give exactly one short, encouraging, actionable tip the person can act on immediately — 12 words or fewer, phrased naturally, never mentioning scores, angles, or technical numbers."
        return """
        You are a friendly, concise photography coach watching the user's live \
        camera viewfinder. On each turn you'll receive a short set of measurements \
        about the current frame (an aesthetics score, horizon tilt, how far the main \
        subject sits from center, and face quality if a face is visible), and usually \
        the frame itself. Judge composition, lighting, background clutter, and timing \
        from the image when it is provided. \(styleRule) \
        Write the tip in \(language). If the shot already looks good, say so warmly and set \
        readyToShoot to true. Respond with ONLY compact JSON in exactly this shape, \
        no code fences, no extra text: {"tip":"...","readyToShoot":false}
        """
    }

    private func requestTip(image: UIImage, signals: FrameSignals) async {
        guard let base = URL(string: config.baseURL) else { return }
        let url = base.appendingPathComponent("chat/completions")

        let horizonText = signals.horizonAngleDegrees.map { String(format: "%.1f degrees from level", $0) } ?? "no clear horizon"
        let subjectText = signals.subjectOffset.map { offset in
            String(format: "offset x=%.2f y=%.2f from center (-1 to 1 scale)", offset.x, offset.y)
        } ?? "no clear subject detected"
        let faceText = signals.faceCount > 0
            ? String(format: "%d face(s), quality %.2f (0-1 scale)", signals.faceCount, signals.faceQuality ?? 0)
            : "no faces in frame"

        let userMessage = """
            Aesthetics score (-1 to 1, higher is better): \(String(format: "%.2f", signals.aestheticsScore))
            Horizon: \(horizonText)
            Subject framing: \(subjectText)
            Faces: \(faceText)
            Exposure bias: \(String(format: "%.1f", signals.exposureBiasEV)) EV
            """

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var userParts: [ContentPart] = [ContentPart(type: "text", text: userMessage)]
        if sendsImage {
            // Downsize, then pixellate any faces before the frame leaves the
            // phone. Face-quality coaching still works: Layer 1 computes the
            // numeric face signals on-device from the unblurred frame.
            let prepared = await image.preparedForModel(maxLongEdge: 768).withFacesBlurred()
            if let jpeg = prepared.jpegData(compressionQuality: 0.5) {
                let dataURI = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                userParts.append(ContentPart(type: "image_url", image_url: .init(url: dataURI)))
            }
        }

        let body = ChatRequest(
            model: config.modelName,
            messages: [
                ChatMessage(role: "system", content: [ContentPart(type: "text", text: systemPrompt)]),
                ChatMessage(role: "user", content: userParts),
            ]
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let serverMessage = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error?.message
                    ?? String(data: data.prefix(300), encoding: .utf8)
                    ?? "no details"
                throw RemoteError.http(http.statusCode, serverMessage)
            }

            let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = chat.choices.first?.message.content else {
                throw URLError(.cannotParseResponse)
            }

            totalRequests += 1
            totalPromptTokens += chat.usage?.prompt_tokens ?? 0
            totalCompletionTokens += chat.usage?.completion_tokens ?? 0

            // Also accumulate persistent all-time totals, shown in Settings.
            let defaults = UserDefaults.standard
            defaults.set(defaults.integer(forKey: "usageTotalRequests") + 1,
                         forKey: "usageTotalRequests")
            defaults.set(defaults.integer(forKey: "usageTotalPromptTokens") + (chat.usage?.prompt_tokens ?? 0),
                         forKey: "usageTotalPromptTokens")
            defaults.set(defaults.integer(forKey: "usageTotalCompletionTokens") + (chat.usage?.completion_tokens ?? 0),
                         forKey: "usageTotalCompletionTokens")

            let payload = try Self.parseTip(from: content)
            currentTip = payload.tip
            readyToShoot = payload.readyToShoot
            hasSucceeded = true
            unavailableReason = nil
        } catch let RemoteError.http(code, message) {
            if !hasSucceeded {
                unavailableReason = "Server error \(code): \(message)"
            }
        } catch {
            // Keep the last good tip on transient failures. Only surface an
            // error message if we've never successfully reached the server.
            if !hasSucceeded {
                unavailableReason = "Can't reach your AI model — \(error.localizedDescription)"
            }
        }
    }

    /// Models sometimes wrap JSON in code fences or add prose despite
    /// instructions — extract the first {...} block and decode it.
    private static func parseTip(from content: String) throws -> TipPayload {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { throw URLError(.cannotParseResponse) }
        return try JSONDecoder().decode(TipPayload.self, from: data)
    }
}
