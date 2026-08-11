//
//  CameraPreviewView.swift
//  CameraCoach
//
//  Thin UIViewRepresentable bridge so SwiftUI can host the
//  AVCaptureVideoPreviewLayer. Nothing fancy — the interesting logic
//  lives in CameraSessionManager.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: CameraSessionManager

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        let layer = session.makePreviewLayer()
        view.previewLayer = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer?.frame = uiView.bounds
    }
}

final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
