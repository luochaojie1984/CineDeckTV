import SwiftUI
import SubtitleKit

/// SwiftUI 文本字幕叠加层：供 AVPlayer 回退路径或自定义纯文本外挂字幕渲染，严格避让安全区并支持字号/颜色/描边/底距与偏移秒。
public struct SubtitleOverlayView: View {
    public let cues: [SubtitleCue]
    public let currentTime: TimeInterval
    public let style: SubtitleStyleConfig

    public init(cues: [SubtitleCue], currentTime: TimeInterval, style: SubtitleStyleConfig) {
        self.cues = cues
        self.currentTime = currentTime
        self.style = style
    }

    private var activeCueText: String? {
        guard !cues.isEmpty else { return nil }
        let adjusted = currentTime - style.offsetSeconds
        return cues.first(where: { $0.start <= adjusted && adjusted <= $0.end })?.text
    }

    public var body: some View {
        VStack {
            Spacer()
            if let text = activeCueText, !text.isEmpty {
                Text(text)
                    .font(.system(size: CGFloat(style.fontSize), weight: .semibold))
                    .multilineTextAlignment(textAlignment)
                    .foregroundStyle(Color(hex: style.foregroundHex) ?? .white)
                    .shadow(color: (Color(hex: style.outlineHex) ?? .black).opacity(0.95), radius: CGFloat(max(1, style.outlineWidth)), x: 0, y: 1)
                    .shadow(color: .black.opacity(0.75), radius: CGFloat(max(1, style.outlineWidth * 1.4)), x: 0, y: 2)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .padding(.horizontal, 120)
                    .padding(.bottom, CGFloat(max(24, style.bottomInset)))
            }
        }
        .allowsHitTesting(false)
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
