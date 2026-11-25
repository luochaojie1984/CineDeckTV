import Foundation
import UIKit
import SwiftUI

/// 预览帧呈现层：直接写 CALayer.contents，零 SwiftUI 视图树 diff（设计规划 6.3 #16）。
public final class ScrubFrameLayerView: UIView {
    private let imageLayer = CALayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(imageLayer)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    public func present(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    public func clear() {
        present(nil)
    }
}

public struct ScrubFramePresenter: UIViewRepresentable {
    public final class Coordinator {
        public let view = ScrubFrameLayerView()
    }

    public let image: CGImage?

    public init(image: CGImage?) {
        self.image = image
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> ScrubFrameLayerView {
        context.coordinator.view.present(image)
        return context.coordinator.view
    }

    public func updateUIView(_ uiView: ScrubFrameLayerView, context: Context) {
        uiView.present(image)
    }
}
