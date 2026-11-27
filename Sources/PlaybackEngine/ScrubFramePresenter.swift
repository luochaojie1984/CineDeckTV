import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import CoreMedia
import AVFoundation
import SwiftUI
import UIKit
import QuartzCore

/// Wraps a VideoToolbox `CVPixelBuffer` for zero-copy cross-actor transport to the GPU display layer.
public final class SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

public enum ScrubFrameContent: Sendable {
    case pixelBuffer(SendablePixelBuffer, rotation: UInt16)
    case cgImage(CGImage)
}

/// A decoded video preview frame returned by `LiveKeyframeScrubEngine`.
public struct ScrubPreviewFrame: Sendable {
    public let content: ScrubFrameContent
    public let actualTime: TimeInterval

    public var cgImage: CGImage? {
        if case .cgImage(let img) = content { return img }
        return nil
    }

    public init(cgImage: CGImage, actualTime: TimeInterval) {
        self.content = .cgImage(cgImage)
        self.actualTime = actualTime
    }

    public init(pixelBuffer: CVPixelBuffer, rotation: UInt16 = 0, actualTime: TimeInterval) {
        self.content = .pixelBuffer(SendablePixelBuffer(pixelBuffer), rotation: rotation)
        self.actualTime = actualTime
    }
}

/// Result of a preview decode request: distinguishes a freshly rendered frame from an unchanged GOP frame.
public enum ScrubDecodeOutcome: Sendable {
    case frame(ScrubPreviewFrame)
    case unchanged(actualTime: TimeInterval)
    case unavailable
}

/// 零拷贝 CoreAnimation / AVSampleBufferDisplayLayer 快进预览帧呈现器：
/// 直接将 VideoToolbox `CVPixelBuffer` 推入 GPU 显示层（~0.2ms），零 SwiftUI 视图树 diff。
@MainActor
public final class ScrubFramePresenter {
    fileprivate weak var canvasView: ScrubCanvasView?
    private var pendingContent: ScrubFrameContent?
    public private(set) var isVisible: Bool = false

    public init() {}

    fileprivate func attach(_ view: ScrubCanvasView) {
        canvasView = view
        if let pendingContent, isVisible {
            view.present(pendingContent)
        } else {
            view.clear()
        }
    }

    public func present(_ frame: ScrubPreviewFrame) {
        present(frame.content)
    }

    public func present(_ content: ScrubFrameContent) {
        pendingContent = content
        isVisible = true
        canvasView?.present(content)
    }

    public func present(_ cgImage: CGImage) {
        present(.cgImage(cgImage))
    }

    public func clear() {
        pendingContent = nil
        isVisible = false
        canvasView?.clear()
    }
}

final class ScrubCanvasView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var currentRotation: UInt16 = 0
    private lazy var fallbackCIContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        isHidden = true

        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear

        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.isHidden = true
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyDisplayLayout(for: currentRotation)
    }

    func present(_ content: ScrubFrameContent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch content {
        case .pixelBuffer(let box, let rotation):
            if let sampleBuffer = Self.makeSampleBuffer(from: box.buffer) {
                layer.contents = nil
                if currentRotation != rotation || displayLayer.bounds.isEmpty {
                    currentRotation = rotation
                    applyDisplayLayout(for: rotation)
                }
                displayLayer.isHidden = false
                isHidden = false
                CATransaction.commit()

                let renderer = displayLayer.sampleBufferRenderer
                if renderer.status == .failed {
                    renderer.flush()
                }
                renderer.enqueue(sampleBuffer)
                return
            }

            var ciImage = CIImage(cvPixelBuffer: box.buffer)
            if rotation == 90 { ciImage = ciImage.oriented(.right) }
            else if rotation == 180 { ciImage = ciImage.oriented(.down) }
            else if rotation == 270 { ciImage = ciImage.oriented(.left) }
            displayLayer.isHidden = true
            layer.contents = fallbackCIContext.createCGImage(ciImage, from: ciImage.extent.integral)
            isHidden = false

        case .cgImage(let image):
            displayLayer.isHidden = true
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            layer.contents = image
            isHidden = false
        }

        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.isHidden = true
        isHidden = true
        CATransaction.commit()
    }

    private func applyDisplayLayout(for rotation: UInt16) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.position = CGPoint(x: b.midX, y: b.midY)
        switch rotation {
        case 90:
            displayLayer.bounds = CGRect(x: 0, y: 0, width: b.height, height: b.width)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2))
        case 180:
            displayLayer.bounds = b
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi))
        case 270:
            displayLayer.bounds = CGRect(x: 0, y: 0, width: b.height, height: b.width)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
        default:
            displayLayer.bounds = b
            displayLayer.setAffineTransform(.identity)
        }
        CATransaction.commit()
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let bufStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

/// SwiftUI 宿主包装层：仅挂载一次，后续帧更新由 `ScrubFramePresenter` 直接驱动 GPU。
public struct ScrubFrameDisplayView: UIViewRepresentable {
    public let presenter: ScrubFramePresenter

    public init(presenter: ScrubFramePresenter) {
        self.presenter = presenter
    }

    public func makeUIView(context: Context) -> UIView {
        let view = ScrubCanvasView()
        presenter.attach(view)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if let canvas = uiView as? ScrubCanvasView {
            presenter.attach(canvas)
        }
    }
}
