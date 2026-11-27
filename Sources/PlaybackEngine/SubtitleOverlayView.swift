import SwiftUI
import SubtitleKit

/// SwiftUI 实时文本字幕渲染层：
/// - 贴合 1080p 真实底边（默认距底 8px），不被 tvOS Safe Area 误顶高；
/// - 支持设置面板开启时将 `virtualBottomFloor` 设为设置栏顶部高度，使字幕实时落在“设置栏上沿 + bottomInset”位置；
/// - 支持 7 款真实中文字体、10 种配色、字号、位置、描边、底框透明度、对齐与时间轴偏移实时生效。
public struct SubtitleOverlayView: View {
    public let cues: [SubtitleCue]
    public let currentTime: TimeInterval
    public let style: SubtitleStyleConfig
    public let virtualBottomFloor: CGFloat
    public let previewFallbackText: String?

    public init(
        cues: [SubtitleCue],
        currentTime: TimeInterval,
        style: SubtitleStyleConfig,
        virtualBottomFloor: CGFloat = 0,
        previewFallbackText: String? = nil
    ) {
        self.cues = cues
        self.currentTime = currentTime
        self.style = style
        self.virtualBottomFloor = virtualBottomFloor
        self.previewFallbackText = previewFallbackText
    }

    private var activeCueText: String? {
        guard !cues.isEmpty else { return nil }
        let adjusted = currentTime - style.offsetSeconds
        return cues.first(where: { $0.start <= adjusted && adjusted <= $0.end })?.text
    }

    private var displayedText: String? {
        if let active = activeCueText, !active.isEmpty {
            return active
        }
        if let fallback = previewFallbackText, !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private var effectiveBottomPadding: CGFloat {
        max(0, virtualBottomFloor) + CGFloat(max(0, style.bottomInset))
    }

    private var styleRenderID: String {
        "\(style.fontFamily.rawValue)-\(Int(style.fontSize))-\(style.foregroundHex)-\(Int(style.outlineWidth * 10))-\(Int(style.backgroundOpacity * 100))-\(style.alignment.rawValue)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let text = displayedText {
                styledSubtitleText(text)
                    .id(styleRenderID)
                    .multilineTextAlignment(textAlignment)
                    .padding(.horizontal, style.backgroundOpacity > 0.02 ? 30 : 12)
                    .padding(.vertical, style.backgroundOpacity > 0.02 ? 12 : 4)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(min(0.85, max(0, style.backgroundOpacity))))
                    )
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .padding(.horizontal, 96)
                    .padding(.bottom, effectiveBottomPadding)
                    .animation(.easeOut(duration: 0.16), value: effectiveBottomPadding)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func styledSubtitleText(_ text: String) -> some View {
        let fg = Color(hex: style.foregroundHex) ?? .white
        let outline = Color(hex: style.outlineHex) ?? .black
        let stroke = CGFloat(min(6, max(0, style.outlineWidth)))
        let font = SubtitleFontRegistry.shared.resolveSwiftUIFont(for: style.fontFamily, size: CGFloat(style.fontSize))

        let base = Text(text)
            .font(font)
            .foregroundStyle(fg)

        if stroke > 0.1 {
            base
                .shadow(color: outline.opacity(0.96), radius: stroke * 0.55, x: stroke * 0.45, y: stroke * 0.45)
                .shadow(color: outline.opacity(0.96), radius: stroke * 0.55, x: -stroke * 0.45, y: -stroke * 0.45)
                .shadow(color: outline.opacity(0.90), radius: stroke * 0.9, x: 0, y: stroke * 0.7)
        } else {
            base
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
        }
    }

    private var textAlignment: TextAlignment {
        switch style.alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch style.alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
