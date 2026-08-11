//
//  ContentView.swift
//  CameraCoach
//
//  Wires the two layers together:
//    CameraSessionManager (frames) -> VisionAnalyzer (Layer 1, numbers)
//    -> OverlayView (grid/level/dot, every analyzed frame)
//    -> CoachingEngine (Layer 2, words, throttled separately)
//
//  Deployment target: iOS 26.0+ (required by Foundation Models). Set this
//  in the target's General tab in Xcode. CoachingEngine additionally
//  checks device eligibility (A17 Pro+) at runtime via
//  SystemLanguageModel.default.availability — that's a hardware check, not
//  an OS-version check, so it can't be caught at compile time.
//

import SwiftUI
import AVFoundation
import AVKit

struct ContentView: View {
    @StateObject private var cameraSession = CameraSessionManager()
    @State private var coachingEngine: any TipEngine
    private let visionAnalyzer = VisionAnalyzer()

    init(backend: CoachingBackend = .appleIntelligence,
         personalConfig: PersonalModelConfig = PersonalModelConfig(baseURL: "", modelName: "", apiKey: "")) {
        switch backend {
        case .appleIntelligence:
            _coachingEngine = State(initialValue: CoachingEngine())
        case .personalModel:
            _coachingEngine = State(initialValue: RemoteCoachingEngine(config: personalConfig))
        }
    }

    @State private var signals: FrameSignals = .placeholder
    @State private var isAnalyzing = false
    @State private var flashOpacity: Double = 0
    @State private var coachingEnabled = false
    @State private var showSettings = false
    @State private var pinchBaseZoom: CGFloat = 1.0
    @State private var focusPoint: CGPoint?
    @State private var exposureBias: Float = 0
    @State private var focusUIGeneration = 0
    @State private var showLastPhoto = false
    @State private var aiControlsExpanded = false
    @State private var showFrameShareAlert = false
    @State private var recordingCoachTimerGeneration = 0
    @AppStorage("confirmedFrameSharing") private var confirmedFrameSharing = false

    var body: some View {
        ZStack {
            if cameraSession.permissionDenied {
                permissionDeniedView
            } else {
                CameraPreviewView(session: cameraSession)
                    .ignoresSafeArea()
                    .onTapGesture(coordinateSpace: .local) { location in
                        cameraSession.focus(atLayerPoint: location)
                        exposureBias = 0
                        withAnimation(.easeIn(duration: 0.15)) { focusPoint = location }
                        scheduleFocusDismiss()
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                cameraSession.setZoom(pinchBaseZoom * scale)
                            }
                            .onEnded { _ in
                                pinchBaseZoom = cameraSession.zoomFactor
                            }
                    )

                // Tap-to-focus indicator + exposure slider (Apple-style:
                // drag the sun beside the square to brighten/darken).
                if let focusPoint {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 80, height: 80)
                        .position(focusPoint)
                        .transition(.opacity)
                        .allowsHitTesting(false)

                    VerticalExposureSlider(value: $exposureBias) { newValue in
                        cameraSession.setExposureBias(newValue)
                        scheduleFocusDismiss()
                    }
                    .frame(width: 36, height: 170)
                    .position(
                        x: focusPoint.x < UIScreen.main.bounds.width - 110
                            ? focusPoint.x + 72
                            : focusPoint.x - 72,
                        y: focusPoint.y
                    )
                    .transition(.opacity)
                }

                OverlayView(
                    signals: signals,
                    tip: coachingEngine.unavailableReason ?? coachingEngine.currentTip,
                    readyToShoot: coachingEngine.readyToShoot,
                    coachingAvailable: coachingEngine.isModelAvailable,
                    coachingEnabled: coachingEnabled,
                    coachingBusy: coachingEngine.isBusy
                )
                .ignoresSafeArea()

                // Top controls. The labeled "AI Coach" button expands a
                // vertical stack of AI controls, one per row; flash and
                // settings stay always visible on the right.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // AI cluster expander — labeled so its purpose is
                        // obvious on first launch.
                        Button {
                            withAnimation(.snappy) { aiControlsExpanded.toggle() }
                        } label: {
                            Label("AI Coach", systemImage: coachingEnabled ? "sparkles" : "sparkles.slash")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(coachingEnabled ? .yellow : .white)
                        }

                        // Upload indicator: lit whenever a coaching request
                        // is actually on the wire — sending is never invisible.
                        if coachingEngine.isBusy {
                            HStack(spacing: 4) {
                                Circle().fill(.orange).frame(width: 7, height: 7)
                                Text("AI").font(.caption2.bold())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.orange)
                        }

                        Spacer()

                        // Live Photo toggle (photo mode only).
                        if cameraSession.captureMode == .photo {
                            Button {
                                cameraSession.livePhotoEnabled.toggle()
                            } label: {
                                Image(systemName: cameraSession.livePhotoEnabled ? "livephoto" : "livephoto.slash")
                                    .font(.body)
                                    .padding(9)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .foregroundStyle(cameraSession.livePhotoEnabled ? .yellow : .white)
                            }
                        }

                        // Flash: auto → on → off.
                        Button {
                            switch cameraSession.flashMode {
                            case .auto: cameraSession.flashMode = .on
                            case .on: cameraSession.flashMode = .off
                            default: cameraSession.flashMode = .auto
                            }
                        } label: {
                            Image(systemName: flashIconName)
                                .font(.body)
                                .padding(9)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(cameraSession.flashMode == .off ? .white : .yellow)
                        }

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.body)
                                .padding(9)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }

                    // Expanded AI controls: one per row so nothing crowds.
                    if aiControlsExpanded {
                        Button {
                            coachingEnabled.toggle()
                        } label: {
                            Label(coachingEnabled ? "Coach On" : "Coach Off",
                                  systemImage: coachingEnabled ? "sparkles" : "sparkles.slash")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(coachingEnabled ? .yellow : .white)
                        }

                        if coachingEnabled, let remote = coachingEngine as? RemoteCoachingEngine {
                            Button {
                                remote.sendsImage.toggle()
                                UserDefaults.standard.set(remote.sendsImage, forKey: "personalModelSendsImage")
                            } label: {
                                Label(remote.sendsImage ? "AI sees photo" : "AI sees data only",
                                      systemImage: remote.sendsImage ? "eye.fill" : "eye.slash.fill")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .foregroundStyle(remote.sendsImage ? .yellow : .white)
                            }
                        }

                        if coachingEnabled, let usage = coachingEngine.usageSummary {
                            Text(usage)
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding()

                // Brief white flash as capture feedback.
                Color.white
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Bottom controls: flash · zoom readout + shutter · camera flip.
                VStack {
                    Spacer()

                    // Zoom presets + live readout.
                    HStack(spacing: 14) {
                        ForEach([1.0, 2.0, 5.0], id: \.self) { preset in
                            Button(String(format: "%.0f×", preset)) {
                                cameraSession.setZoom(preset)
                                pinchBaseZoom = preset
                            }
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(abs(cameraSession.zoomFactor - preset) < 0.05 ? .yellow : .white)
                        }
                        if cameraSession.zoomFactor > 1.01,
                           ![1.0, 2.0, 5.0].contains(where: { abs($0 - cameraSession.zoomFactor) < 0.05 }) {
                            Text(String(format: "%.1f×", cameraSession.zoomFactor))
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.yellow)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)

                    // PHOTO | VIDEO mode switcher.
                    HStack(spacing: 24) {
                        Button("PHOTO") { cameraSession.setCaptureMode(.photo) }
                            .font(.caption.bold())
                            .foregroundStyle(cameraSession.captureMode == .photo ? .yellow : .white)
                        Button("VIDEO") { cameraSession.setCaptureMode(.video) }
                            .font(.caption.bold())
                            .foregroundStyle(cameraSession.captureMode == .video ? .yellow : .white)
                    }
                    .disabled(cameraSession.isRecording)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)

                    HStack {
                        // Last-capture thumbnail; tap to view the gallery.
                        Button {
                            if !cameraSession.capturedMedia.isEmpty { showLastPhoto = true }
                        } label: {
                            if let thumb = cameraSession.capturedMedia.last?.thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 1))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 48, height: 48)
                            }
                        }

                        Spacer()

                        // Shutter: photo capture, or start/stop recording in
                        // video mode. Green ring = AI says the shot is ready.
                        Button {
                            if cameraSession.captureMode == .video {
                                cameraSession.toggleRecording()
                            } else {
                                cameraSession.capturePhoto()
                                flashOpacity = 0.7
                                withAnimation(.easeOut(duration: 0.35)) {
                                    flashOpacity = 0
                                }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(coachingEnabled && coachingEngine.readyToShoot ? Color.green : Color.white, lineWidth: 4)
                                    .frame(width: 74, height: 74)
                                if cameraSession.captureMode == .video {
                                    if cameraSession.isRecording {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.red)
                                            .frame(width: 32, height: 32)
                                    } else {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 60, height: 60)
                                    }
                                } else {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 60, height: 60)
                                }
                            }
                        }

                        Spacer()

                        // Front/back camera flip.
                        Button {
                            cameraSession.switchCamera()
                            pinchBaseZoom = 1.0
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.title3)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(.white)
                        }
                        .disabled(cameraSession.isRecording)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear { cameraSession.start() }
        .onDisappear { cameraSession.stop() }
        .sheet(isPresented: $showSettings) {
            BackendPickerView(buttonTitle: "Apply Settings") { backend, config in
                switch backend {
                case .appleIntelligence:
                    coachingEngine = CoachingEngine()
                case .personalModel:
                    coachingEngine = RemoteCoachingEngine(config: config)
                }
                showSettings = false
            }
        }
        .onReceive(cameraSession.framePublisher) { pixelBuffer, exposureBias in
            handleFrame(pixelBuffer: pixelBuffer, exposureBiasEV: exposureBias)
        }
        // Haptic tap when the AI declares the shot ready — eyes stay on the scene.
        .onChange(of: coachingEngine.readyToShoot) { _, ready in
            if ready {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        // Auto-disable AI coaching after 5 minutes of continuous recording —
        // long takes shouldn't quietly rack up model costs.
        .onChange(of: cameraSession.isRecording) { _, recording in
            recordingCoachTimerGeneration += 1
            guard recording else { return }
            let generation = recordingCoachTimerGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                if generation == recordingCoachTimerGeneration,
                   cameraSession.isRecording, coachingEnabled {
                    coachingEnabled = false
                }
            }
        }
        // One-time consent the first time a frame is about to leave the phone.
        .alert("Share camera frames with AI?", isPresented: $showFrameShareAlert) {
            Button("Share frames") {
                confirmedFrameSharing = true
            }
            Button("Data only") {
                confirmedFrameSharing = true
                if let remote = coachingEngine as? RemoteCoachingEngine {
                    remote.sendsImage = false
                    UserDefaults.standard.set(false, forKey: "personalModelSendsImage")
                }
            }
        } message: {
            Text("With frame sharing on, a small copy of what your camera sees is sent to your AI model provider with each coaching request. Faces are automatically blurred before sending. Choose \"Data only\" to send just numeric measurements — you can change this anytime with the eye button.")
        }
        .sheet(isPresented: $showLastPhoto) {
            MediaGalleryView(session: cameraSession)
        }
    }

    /// Keeps the focus square + exposure slider on screen for a few seconds,
    /// extending the timer whenever the user interacts with the slider.
    private func scheduleFocusDismiss() {
        focusUIGeneration += 1
        let generation = focusUIGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if generation == focusUIGeneration {
                withAnimation { focusPoint = nil }
            }
        }
    }

    private var flashIconName: String {
        switch cameraSession.flashMode {
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        default: return "bolt.slash.fill"
        }
    }

    // MARK: - Frame handling

    private func handleFrame(pixelBuffer: CVPixelBuffer, exposureBiasEV: Float) {
        // Skip if a previous analysis is still in flight — don't let
        // Vision requests pile up faster than they can complete.
        guard !isAnalyzing else { return }
        isAnalyzing = true

        Task {
            let result = await visionAnalyzer.analyze(pixelBuffer: pixelBuffer, exposureBiasEV: exposureBiasEV)

            await MainActor.run {
                self.signals = result
                self.isAnalyzing = false
            }

            // Layer 2 only runs while the user has AI coaching switched on
            // and is actually looking at the viewfinder (paused while the
            // photo viewer or settings are open — no requests, no cost).
            if coachingEnabled, !showLastPhoto, !showSettings,
               let image = UIImage(pixelBuffer: pixelBuffer, maxLongEdge: 1024) {
                await MainActor.run {
                    // First time a frame would leave the phone: ask instead of send.
                    if let remote = coachingEngine as? RemoteCoachingEngine,
                       remote.sendsImage, !confirmedFrameSharing {
                        showFrameShareAlert = true
                    } else {
                        coachingEngine.maybeRequestTip(image: image, signals: result)
                    }
                }
            }
        }
    }

    // MARK: - Permission denied state


    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("Camera access is off")
                .font(.headline)
            Text("Enable camera access in Settings to use the live coach.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding()
    }
}

// MARK: - Media gallery

/// Full-screen swipeable gallery of this session's photos and videos, with
/// per-item delete (removes from the photo library too, after the system's
/// own confirmation dialog).
struct MediaGalleryView: View {
    @ObservedObject var session: CameraSessionManager
    @State private var selection: UUID?
    @State private var activePlayer: AVPlayer?

    /// Builds (or tears down) the single player when the visible page
    /// changes. Creating an AVPlayer inside `body` would spawn a new decoder
    /// on every redraw and mutate state mid-update.
    private func updatePlayer(for id: UUID?) {
        activePlayer?.pause()
        activePlayer = nil
        guard let id,
              let media = session.capturedMedia.first(where: { $0.id == id }),
              case .video(let url) = media.kind
        else { return }
        activePlayer = AVPlayer(url: url)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.capturedMedia.isEmpty {
                Text("No captures yet")
                    .foregroundStyle(.white)
            } else {
                // Only the visible page is decoded / given a player. Rendering
                // every page at once is what used to exhaust memory once a
                // session had a lot of captures.
                TabView(selection: $selection) {
                    ForEach(session.capturedMedia.reversed()) { media in
                        Group {
                            if media.id == selection {
                                switch media.kind {
                                case .photo(let data):
                                    if let image = UIImage(data: data) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                case .video:
                                    if let activePlayer {
                                        VideoPlayer(player: activePlayer)
                                    } else {
                                        Image(uiImage: media.thumbnail)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                }
                            } else {
                                Image(uiImage: media.thumbnail)
                                    .resizable()
                                    .scaledToFit()
                                    .opacity(0.9)
                            }
                        }
                        .tag(Optional(media.id))
                    }
                }
                .tabViewStyle(.page)
                .onChange(of: selection) { _, newValue in
                    updatePlayer(for: newValue)
                }

                VStack {
                    HStack {
                        Text("This session · saved in Photos")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button {
                            let currentID = selection ?? session.capturedMedia.last?.id
                            if let currentID,
                               let media = session.capturedMedia.first(where: { $0.id == currentID }) {
                                session.delete(media)
                                selection = session.capturedMedia.last?.id
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding()
                    Spacer()
                }
            }
        }
        .onAppear {
            selection = session.capturedMedia.last?.id
            updatePlayer(for: selection)
        }
        .onDisappear {
            activePlayer?.pause()
            activePlayer = nil
        }
    }
}

// MARK: - Exposure slider

/// Vertical drag control shown beside the focus square, Apple Camera style:
/// drag up to brighten, down to darken (±2 EV).
struct VerticalExposureSlider: View {
    @Binding var value: Float // -2...+2 EV
    let onChanged: (Float) -> Void

    @State private var dragStartValue: Float?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.yellow)

            ZStack {
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 3)
                Circle()
                    .fill(.yellow)
                    .frame(width: 16, height: 16)
                    .offset(y: CGFloat(-value / 2.0) * 55)
            }
            .frame(height: 120)

            Image(systemName: "sun.min")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    if dragStartValue == nil { dragStartValue = value }
                    let delta = Float(-gesture.translation.height / 55.0) * 2.0
                    let newValue = max(-2, min(2, (dragStartValue ?? 0) + delta))
                    value = newValue
                    onChanged(newValue)
                }
                .onEnded { _ in dragStartValue = nil }
        )
    }
}
