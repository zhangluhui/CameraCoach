//
//  BackendPickerView.swift
//  CameraCoach
//
//  Shown at every launch, and again from the camera screen's gear button:
//  pick which Layer 2 backend powers the coaching tips. Preferences persist
//  in UserDefaults; the API key goes to the Keychain, never UserDefaults.
//

import SwiftUI

struct BackendPickerView: View {

    @AppStorage("coachingBackend") private var backendRaw = CoachingBackend.appleIntelligence.rawValue
    @AppStorage("personalModelBaseURL") private var baseURL = ""
    @AppStorage("personalModelName") private var modelName = ""
    @AppStorage("personalModelSendsImage") private var sendsImage = true
    @AppStorage("tipDetailLevel") private var detailLevel = "brief"
    @AppStorage("tipLanguage") private var tipLanguage = "auto"
    @State private var apiKey = ""

    // All-time usage stats, persisted by RemoteCoachingEngine.
    @State private var totalRequests = 0
    @State private var totalPromptTokens = 0
    @State private var totalCompletionTokens = 0

    /// "Start Camera" at launch; "Apply Settings" when opened from the
    /// camera screen's gear button.
    var buttonTitle: String = "Start Camera"
    let onStart: (CoachingBackend, PersonalModelConfig) -> Void

    private var backend: CoachingBackend {
        CoachingBackend(rawValue: backendRaw) ?? .appleIntelligence
    }

    private var canStart: Bool {
        switch backend {
        case .appleIntelligence:
            return true
        case .personalModel:
            return URL(string: baseURL) != nil && !baseURL.isEmpty && !modelName.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Coaching model", selection: $backendRaw) {
                        ForEach(CoachingBackend.selectable) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Who coaches your shots?")
                } footer: {
                    switch backend {
                    case .appleIntelligence:
                        Text("Runs fully on-device via Apple Intelligence. Requires iPhone 15 Pro or newer with Apple Intelligence enabled.")
                    case .personalModel:
                        Text("Works with any provider speaking the industry-standard chat-completions format, including OpenAI, Anthropic Claude, Google Gemini, Azure, OpenRouter, or local Ollama / LM Studio, etc. For \"AI sees photo\", pick a vision-capable model.")
                    }
                }

                if backend == .personalModel {
                    Section("Server") {
                        TextField("Base URL  e.g. http://192.168.1.20:11434/v1", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Model name  e.g. llama3.2", text: $modelName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("API key (leave empty for local servers)", text: $apiKey)
                        Toggle("Share camera frames with AI model", isOn: $sendsImage)
                    }
                    Section {
                    } footer: {
                        Text(sendsImage
                             ? "ON: a small copy of what your camera sees is sent to the AI model with each coaching request, so it can judge composition and lighting directly. Faces are automatically blurred on your phone before anything is uploaded. Best tips; requires a vision-capable model."
                             : "OFF: only numeric measurements (score, tilt, subject position) are sent — your images never leave the phone. Works with any model; tips are less specific.")
                    }
                }

                Section {
                    Picker("AI language", selection: $tipLanguage) {
                        Text("Auto (device language)").tag("auto")
                        ForEach(["English", "Chinese (Simplified)", "Chinese (Traditional)", "Spanish", "French", "German", "Japanese", "Korean", "Portuguese", "Italian", "Russian", "Arabic", "Hindi", "Vietnamese", "Thai", "Indonesian", "Turkish", "Dutch", "Polish", "Swedish", "Ukrainian", "Hebrew"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("Detail level", selection: $detailLevel) {
                        Text("Brief").tag("brief")
                        Text("Detailed").tag("detailed")
                    }
                } header: {
                    Text("Coaching style")
                } footer: {
                    Text("Language applies to both backends. Detail level applies to other AI models — Apple Intelligence always keeps tips brief.")
                }

                Section {
                    Button {
                        KeychainStore.save(apiKey.trimmingCharacters(in: .whitespaces), forKey: "personalModelAPIKey")
                        let config = PersonalModelConfig(
                            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                            modelName: modelName.trimmingCharacters(in: .whitespaces),
                            apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                            sendsImage: sendsImage,
                            detailLevel: detailLevel,
                            tipLanguage: tipLanguage
                        )
                        onStart(backend, config)
                    } label: {
                        Text(buttonTitle)
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(!canStart)
                }

                Section {
                    LabeledContent("Requests", value: "\(totalRequests)")
                    LabeledContent("Tokens used", value: "\(totalPromptTokens + totalCompletionTokens)")
                    Button("Reset usage statistics", role: .destructive) {
                        resetUsage()
                    }
                } header: {
                    Text("AI usage (all time)")
                } footer: {
                    Text("Counts every coaching request since the last reset.")
                }

                Section {
                    LabeledContent("Developer", value: "Luhui Zhang")
                    Link(destination: URL(string: "https://github.com/zhangluhui/")!) {
                        LabeledContent("GitHub", value: "zhangluhui")
                    }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } header: {
                    Text("About")
                } footer: {
                    Text("CameraCoach stores nothing outside your device. Photos stay in your photo library; coaching requests (measurements, and frames only if you allow it) go directly to the model provider you configured, and their data retention policy applies. Frames are re-rendered before sending — no location or EXIF metadata ever leaves the phone — and any faces are blurred on-device before upload.")
                }
            }
            .navigationTitle("CameraCoach")
            .onAppear {
                // Migrate any selection saved by an older build.
                if CoachingBackend(rawValue: backendRaw) == nil {
                    backendRaw = CoachingBackend.appleIntelligence.rawValue
                }
                apiKey = KeychainStore.load(forKey: "personalModelAPIKey")
                // Migrate (then clear) a key left in UserDefaults by an
                // earlier build, so upgrading doesn't silently lose it.
                if let legacy = UserDefaults.standard.string(forKey: "personalModelAPIKey"),
                   !legacy.isEmpty {
                    if apiKey.isEmpty {
                        apiKey = legacy
                        KeychainStore.save(legacy, forKey: "personalModelAPIKey")
                    }
                    UserDefaults.standard.removeObject(forKey: "personalModelAPIKey")
                }
                loadUsage()
            }
        }
    }

    // MARK: - Usage stats

    private func loadUsage() {
        let defaults = UserDefaults.standard
        totalRequests = defaults.integer(forKey: "usageTotalRequests")
        totalPromptTokens = defaults.integer(forKey: "usageTotalPromptTokens")
        totalCompletionTokens = defaults.integer(forKey: "usageTotalCompletionTokens")
    }

    private func resetUsage() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "usageTotalRequests")
        defaults.removeObject(forKey: "usageTotalPromptTokens")
        defaults.removeObject(forKey: "usageTotalCompletionTokens")
        totalRequests = 0
        totalPromptTokens = 0
        totalCompletionTokens = 0
    }
}
