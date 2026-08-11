//
//  CameraSessionManager.swift
//  CameraCoach
//
//  Owns the AVCaptureSession, streams frames out for analysis, and exposes
//  the live preview layer for SwiftUI to display. Runs entirely on a
//  background queue except for the tiny bits SwiftUI needs on the main actor.
//
//  Capture features: native-resolution photos, Live Photos, video recording
//  (Photo/Video modes — Live Photo capture and movie output can't coexist on
//  one session, which is why Apple's Camera has modes too), front/back
//  switching, flash, tap-to-focus/expose with exposure bias, pinch zoom, and
//  correct rotation for the physical device orientation at capture time.
//

import AVFoundation
import UIKit
import Combine
import Photos

/// One photo or video captured this session. Copies also land in the system
/// photo library; assetIdentifier links the two so in-app delete can remove
/// the library copy (with the system's own confirmation dialog).
struct CapturedMedia: Identifiable {
    enum Kind {
        /// JPEG bytes rather than a decoded UIImage: a decoded 2048px image
        /// costs ~12MB of RAM, so a few dozen captures would blow the app's
        /// memory budget. The gallery decodes one at a time, on demand.
        case photo(Data)
        case video(URL)
    }
    let id = UUID()
    let kind: Kind
    let thumbnail: UIImage
    var assetIdentifier: String?
}

@MainActor
final class CameraSessionManager: NSObject, ObservableObject {

    enum CaptureMode {
        case photo, video
    }

    let session = AVCaptureSession()

    /// Fires on the main actor with a fresh frame + the device's current
    /// exposure bias. ContentView throttles/analyzes these.
    let framePublisher = PassthroughSubject<(CVPixelBuffer, Float), Never>()

    @Published var permissionDenied = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var zoomFactor: CGFloat = 1.0
    /// All photos and videos captured this session, oldest first.
    @Published var capturedMedia: [CapturedMedia] = []
    private var pendingSaveMediaID: UUID?
    @Published var livePhotoEnabled = false
    @Published var captureMode: CaptureMode = .photo
    @Published var isRecording = false

    private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var captureDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // In-flight photo capture state (Live Photo pairs arrive in pieces).
    private var pendingPhotoData: Data?
    private var pendingLivePhotoMovieURL: URL?

    // Only forward every Nth frame to Vision (~3/sec at 30fps).
    private let frameStride = 10
    /// Only ever touched on the capture delegate queue — nonisolated so the
    /// stride check can happen there without a main-actor hop.
    nonisolated(unsafe) private var frameCounter = 0

    override init() {
        super.init()
    }

    /// Runs once per app launch — `start()` fires again whenever the camera
    /// view reappears, and re-running cleanup then would delete recordings
    /// this session's gallery is still playing back.
    private static var hasCleanedTemporaryVideos = false

    /// Removes leftover recording files from previous runs (kept during a
    /// session for in-app playback; a crash could otherwise strand them).
    private static func cleanTemporaryVideosOnce() {
        guard !hasCleanedTemporaryVideos else { return }
        hasCleanedTemporaryVideos = true
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "mov" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func start() {
        Self.cleanTemporaryVideosOnce()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    func stop() {
        // Finish any recording first, otherwise tearing down the session
        // mid-write loses the clip.
        sessionQueue.async { [movieOutput] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
        }
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            self.attachDevice(position: .back)

            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            if self.photoOutput.isLivePhotoCaptureSupported {
                self.photoOutput.isLivePhotoCaptureEnabled = true
            }
            self.applyMaxPhotoDimensions()

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    /// Removes the current input (if any) and attaches the camera at the
    /// given position. Call on sessionQueue inside begin/commitConfiguration.
    private func attachDevice(position: AVCaptureDevice.Position) {
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }

        session.addInput(input)
        currentInput = input
        captureDevice = device

        Task { @MainActor in
            self.cameraPosition = position
            self.zoomFactor = 1.0
        }
    }

    /// Opt in to the sensor's largest photo output (48MP on newer iPhones).
    private func applyMaxPhotoDimensions() {
        if let dims = captureDevice?.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dims
        }
    }

    // MARK: - Photo / Video mode

    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, !isRecording else { return }
        captureMode = mode
        if mode == .video {
            // Ask for the microphone up front so recordings have sound.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.sessionQueue.async { self?.reconfigure(for: .video) }
            }
        } else {
            sessionQueue.async { [weak self] in self?.reconfigure(for: .photo) }
        }
    }

    /// Call on sessionQueue.
    private func reconfigure(for mode: CaptureMode) {
        session.beginConfiguration()
        switch mode {
        case .photo:
            if session.outputs.contains(movieOutput) {
                session.removeOutput(movieOutput)
            }
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            session.sessionPreset = .photo
            // Removing the movie output re-enables Live Photo capture.
            if photoOutput.isLivePhotoCaptureSupported {
                photoOutput.isLivePhotoCaptureEnabled = true
            }
            applyMaxPhotoDimensions()
        case .video:
            session.sessionPreset = .high
            if audioInput == nil,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
        }
        session.commitConfiguration()
    }

    // MARK: - Camera switching

    func switchCamera() {
        guard !isRecording else { return }
        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachDevice(position: newPosition)
            self.applyMaxPhotoDimensions()
            self.session.commitConfiguration()
        }
    }

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let upperLimit = min(10, device.activeFormat.videoMaxZoomFactor)
            let clamped = max(1, min(factor, upperLimit))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                Task { @MainActor in self.zoomFactor = clamped }
            } catch {}
        }
    }

    // MARK: - Tap to focus / expose

    /// point is in preview-layer (view) coordinates.
    func focus(atLayerPoint point: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.setExposureTargetBias(0)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Exposure compensation from the on-screen slider, in EV.
    func setExposureBias(_ ev: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let clamped = max(device.minExposureTargetBias, min(ev, device.maxExposureTargetBias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Photo capture

    func capturePhoto() {
        let angle = Self.captureRotationAngle()
        let flash = flashMode
        let live = livePhotoEnabled
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            if live, self.photoOutput.isLivePhotoCaptureEnabled {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            Task { @MainActor in
                self.pendingPhotoData = nil
                self.pendingLivePhotoMovieURL = nil
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Video recording

    func toggleRecording() {
        guard captureMode == .video else { return }
        if isRecording {
            sessionQueue.async { [movieOutput] in
                if movieOutput.isRecording { movieOutput.stopRecording() }
            }
        } else {
            isRecording = true
            let angle = Self.captureRotationAngle()
            sessionQueue.async { [weak self] in
                guard let self, !self.movieOutput.isRecording else { return }
                if let connection = self.movieOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    /// Maps physical device orientation to a capture rotation angle
    /// (iOS 17+ videoRotationAngle convention; 90° = portrait).
    private static func captureRotationAngle() -> CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        return layer
    }

    // MARK: - Saving

    /// Saves the completed capture (photo, optionally with its Live Photo
    /// movie) to the photo library.
    private func savePendingCapture() {
        guard let data = pendingPhotoData else { return }
        let movieURL = pendingLivePhotoMovieURL
        let mediaID = pendingSaveMediaID
        pendingPhotoData = nil
        pendingLivePhotoMovieURL = nil
        pendingSaveMediaID = nil

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if let movieURL {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: movieURL, options: options)
                }
                placeholderID = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { [weak self] success, _ in
                guard success, let placeholderID, let mediaID else { return }
                Task { @MainActor in
                    guard let self,
                          let index = self.capturedMedia.firstIndex(where: { $0.id == mediaID })
                    else { return }
                    self.capturedMedia[index].assetIdentifier = placeholderID
                }
            })
        }
    }

    /// Removes a capture from the session gallery and (after the system's
    /// confirmation dialog) from the photo library.
    func delete(_ media: CapturedMedia) {
        capturedMedia.removeAll { $0.id == media.id }
        if case .video(let url) = media.kind {
            try? FileManager.default.removeItem(at: url)
        }
        guard let identifier = media.assetIdentifier else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard assets.count > 0 else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }, completionHandler: nil)
        }
    }
}

// MARK: - Photo delegate

extension CameraSessionManager: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in
            self.pendingPhotoData = data
            if let image = UIImage(data: data) {
                // Memory: keep a screen-sized JPEG (a couple hundred KB) plus
                // a small decoded thumbnail. The full-resolution original
                // goes to the photo library, not into RAM.
                let display = image.preparedForModel(maxLongEdge: 1600)
                if let jpeg = display.jpegData(compressionQuality: 0.85) {
                    let media = CapturedMedia(
                        kind: .photo(jpeg),
                        thumbnail: image.preparedForModel(maxLongEdge: 200)
                    )
                    self.capturedMedia.append(media)
                    self.pendingSaveMediaID = media.id
                }
            }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error == nil else { return }
        Task { @MainActor in
            self.pendingLivePhotoMovieURL = outputFileURL
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        Task { @MainActor in
            self.savePendingCapture()
        }
    }
}

// MARK: - Movie delegate

extension CameraSessionManager: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isRecording = false
            guard error == nil else { return }

            // Thumbnail from the first frame; keep the temp file so the
            // in-app gallery can play the clip back.
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputFileURL))
            generator.appliesPreferredTrackTransform = true
            let thumbnail: UIImage
            if let cgImage = try? await generator.image(at: .zero).image {
                thumbnail = UIImage(cgImage: cgImage).preparedForModel(maxLongEdge: 200)
            } else {
                thumbnail = UIImage()
            }

            let media = CapturedMedia(kind: .video(outputFileURL), thumbnail: thumbnail)
            self.capturedMedia.append(media)
            let mediaID = media.id

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                var placeholderID: String?
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
                    placeholderID = request?.placeholderForCreatedAsset?.localIdentifier
                }, completionHandler: { [weak self] success, _ in
                    guard success, let placeholderID else { return }
                    Task { @MainActor in
                        guard let self,
                              let index = self.capturedMedia.firstIndex(where: { $0.id == mediaID })
                        else { return }
                        self.capturedMedia[index].assetIdentifier = placeholderID
                    }
                })
            }
        }
    }
}

// MARK: - Video frame delegate

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Stride check HERE, on the capture queue. Spawning a main-actor
        // Task for every frame retained each frame's large pixel buffer
        // until the main thread got around to it — under load those queued
        // buffers piled up and iOS killed the app for memory. Now dropped
        // frames are released immediately and only ~3 frames/sec cross over.
        frameCounter += 1
        guard frameCounter % frameStride == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        Task { @MainActor in
            let exposureBias = self.captureDevice?.exposureTargetBias ?? 0
            self.framePublisher.send((pixelBuffer, exposureBias))
        }
    }
}
