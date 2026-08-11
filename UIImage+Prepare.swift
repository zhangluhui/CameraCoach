//
//  UIImage+Prepare.swift
//  CameraCoach
//
//  Foundation Models charges token cost for image attachments based on
//  size, and larger images add latency. A live-coaching feature needs to
//  stay fast, so we downsize aggressively before ever handing a frame to
//  the language model. 768px on the long edge is plenty for "is this
//  framed/lit okay", which is a coarser judgment than reading fine print.
//

import UIKit
import CoreVideo
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// One shared context — creating a CIContext per conversion leaks GPU
/// caches and is expensive.
private let sharedCIContext = CIContext()

extension UIImage {

    func preparedForModel(maxLongEdge: CGFloat) -> UIImage {
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxLongEdge else { return self }

        let scale = maxLongEdge / longestEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Returns a copy with every detected face pixellated — bystander
    /// privacy before a frame is uploaded to a model provider. If no faces
    /// are found (or detection fails), returns the image unchanged.
    func withFacesBlurred() async -> UIImage {
        guard let cgImage else { return self }
        let request = DetectFaceRectanglesRequest()
        guard let faces = try? await request.perform(on: cgImage), !faces.isEmpty else {
            return self
        }

        let ciImage = CIImage(cgImage: cgImage)
        let width = ciImage.extent.width
        let height = ciImage.extent.height

        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = ciImage
        pixellate.scale = Float(max(width, height) / 40)
        guard let pixellated = pixellate.outputImage else { return self }

        var output = ciImage
        for face in faces {
            let normalized = face.boundingBox.cgRect // 0...1, origin bottom-left
            var rect = CGRect(
                x: normalized.minX * width,
                y: normalized.minY * height,
                width: normalized.width * width,
                height: normalized.height * height
            )
            // Expand a little so hairline/chin edges are covered too.
            rect = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
            output = pixellated.cropped(to: rect).composited(over: output)
        }

        guard let result = sharedCIContext.createCGImage(output, from: ciImage.extent) else {
            return self
        }
        return UIImage(cgImage: result)
    }

    /// Converts a camera pixel buffer to a UIImage, optionally downscaling
    /// during conversion so we never materialize a full-resolution CGImage
    /// (a 12–48MP frame decodes to 50–190MB) just to feed the coach.
    convenience init?(pixelBuffer: CVPixelBuffer, maxLongEdge: CGFloat? = nil) {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let maxLongEdge {
            let longest = max(ciImage.extent.width, ciImage.extent.height)
            if longest > maxLongEdge {
                let scale = maxLongEdge / longest
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        guard let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        self.init(cgImage: cgImage)
    }
}
