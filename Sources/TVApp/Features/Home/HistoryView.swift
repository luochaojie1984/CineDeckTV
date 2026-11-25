import SwiftUI
import NetworkVFS
import AppPreferences

/// 观看历史与续播管理页面：液态玻璃时间线卡片 + 渐变续播进度。
public struct HistoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    public var onResumeRecord: (PlaybackRecord) -> Void
    public var onOpenSource: (MediaSourceConfig) -> Void

    @State private var confirmClear = false

    public init(
        onResumeRecord: @escaping (PlaybackRecord) -> Void,
        onOpenSource: @escaping (MediaSourceConfig) -> Void
    ) {
        self.onResumeRecord = onResumeRecord
        self.onOpenSource = onOpenSource
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("观看历史")
                            .font(TVTokens.Typography.pageTitle)
                        Text("精准记录断点时刻，一键续播局域网高码率影片")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    Spacer()
                    if !env.history.isEmpty {
                        AdaptiveGlassContainer(spacing: 12) {
                            Button(role: .destructive) {
                                confirmClear = true
                            } label: {
                                Label("清空历史", systemImage: "trash")
                                    .font(TVTokens.Typography.button)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                            }
                            .tvAdaptiveGlassButtonStyle()
                        }
                    }
                }
                .focusSection()

                if env.history.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 56))
                            .foregroundStyle(TVTokens.Color.accent)
                        Text("还没有观看记录")
                            .font(TVTokens.Typography.sectionTitle)
                        Text("从「共享盘」任意打开一段影片后，播放进度会自动保存在本地。")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(60)
                    .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(env.history) { record in
                            let theme = TVMediaTheme.palette(forTitle: record.title)
                            let entry = VFSEntry(path: record.path, name: record.title, isDirectory: false, size: 0, modifiedAt: nil)
                            Button {
                                onResumeRecord(record)
                            } label: {
                                HStack(spacing: 22) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(LinearGradient(colors: [theme.primary.opacity(0.45), theme.secondary.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 68, height: 68)
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 28, weight: .bold))
                                            .foregroundStyle(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(TVTitleFormatter.cleanDisplayTitle(record.title))
                                            .font(TVTokens.Typography.listPrimary)
                                            .lineLimit(1)

                                        HStack(spacing: 14) {
                                            Text("进度 \(Int(record.progress * 100))%")
                                                .font(.system(size: 18, weight: .bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 3)
                                                .background(theme.primary.opacity(0.24), in: Capsule())
                                                .foregroundStyle(theme.primary)
                                            Text("\(formatClock(record.position)) / \(formatClock(record.duration))")
                                            Text("·")
                                            Text("剩余 \(Int(max(1, record.remaining / 60))) 分钟")
                                        }
                                        .font(TVTokens.Typography.secondary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)

                                        TVProgressBar(progress: record.progress, tint: theme.primary, secondaryTint: theme.secondary, height: 6)
                                    }

                                    Spacer(minLength: 16)

                                    VideoBadgeRow(entry.badges, maxCount: 4)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                            }
                            .buttonStyle(TVListRowButtonStyle(accentTint: theme.primary))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .focusSection()
                }
            }
            .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
            .padding(.vertical, 32)
        }
        .confirmationDialog("确定清空全部观看历史吗？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空全部历史", role: .destructive) {
                env.clearHistory()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
