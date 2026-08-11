//
//  CoachingBackend.swift
//  CameraCoach
//
//  Defines the two Layer 2 backends the user can choose between at launch:
//  Apple Intelligence (on-device Foundation Models) or a personal model
//  reachable over an OpenAI-compatible API (OpenAI, Ollama, LM Studio, …).
//

import UIKit

enum CoachingBackend: String, CaseIterable, Identifiable {
    case appleIntelligence
    case personalModel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .personalModel: return "Other AI models"
        }
    }

    /// Backends offered in the settings picker.
    static var selectable: [CoachingBackend] { allCases }
}

struct PersonalModelConfig: Equatable {
    /// Base URL of an OpenAI-compatible server, e.g.
    ///   https://api.openai.com/v1
    ///   http://192.168.1.20:11434/v1   (Ollama on your Mac)
    ///   http://192.168.1.20:1234/v1    (LM Studio)
    var baseURL: String
    var modelName: String
    var apiKey: String
    /// When true, the downsized camera frame is attached to each request so
    /// vision-capable models can critique the actual composition. Turn off
    /// for text-only models.
    var sendsImage: Bool = true
    /// "brief" (one ≤12-word tip) or "detailed" (2–3 sentence critique).
    var detailLevel: String = "brief"
    /// "auto" (device language) or an English language name like "Chinese".
    var tipLanguage: String = "auto"
}

enum TipLanguage {
    /// Turns the stored setting into an English language name the model
    /// understands ("auto" resolves to the device's preferred language).
    static func resolved(_ setting: String) -> String {
        guard setting == "auto" else { return setting }
        let code = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

/// The minimal surface ContentView needs from a Layer 2 engine, so the
/// Apple and personal-model implementations are interchangeable.
@MainActor
protocol TipEngine: AnyObject {
    var currentTip: String { get }
    var readyToShoot: Bool { get }
    var isModelAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// One-line usage/cost summary for paid backends; nil when free (on-device).
    var usageSummary: String? { get }
    /// True while a coaching request is on the wire (used for the on-screen
    /// upload indicator and tip dimming).
    var isBusy: Bool { get }
    func maybeRequestTip(image: UIImage, signals: FrameSignals)
}

extension TipEngine {
    var usageSummary: String? { nil }
    var isBusy: Bool { false }
}

extension CoachingEngine: TipEngine {}
