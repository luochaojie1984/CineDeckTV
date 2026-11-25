import SwiftUI
import NetworkVFS

/// 服务器管理：列表 + 新增/编辑表单（密码走 Keychain，不回显）。
public struct SourceManagerView: View {
    @EnvironmentObject private var env: AppEnvironment
    public var onSelect: (MediaSourceConfig) -> Void

    @State private var editing: MediaSourceConfig?
    @State private var draft = Draft()
    @State private var password = ""

    struct Draft {
        var name = ""
        var kind: MediaSourceKind = .smb
        var host = ""
        var port = "445"
        var username = ""
        var sharePath = ""
        var useTLS = false
        var anonymous = false
    }

    public init(onSelect: @escaping (MediaSourceConfig) -> Void) {
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack {
            TVTokens.backgroundGradient.ignoresSafeArea()
            HStack(spacing: 32) {
                listPanel
                editorPanel
            }
            .padding(32)
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("服务器").font(TVTokens.Typography.pageTitle)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(env.sources) { source in
                        Button { beginEdit(source) } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).font(TVTokens.Typography.listPrimary).lineLimit(1)
                                    Text("\(source.kind.displayName) · \(source.host):\(source.port)\(source.sharePath)")
                                        .font(TVTokens.Typography.secondary)
                                        .foregroundStyle(TVTokens.Color.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 16).fill(TVTokens.Color.cardSurface))
                        }
                        .buttonStyle(TVCardButtonStyle())
                    }
                }
            }
            Button("新增服务器") { beginNew() }
                .tvAdaptiveGlassButtonStyle(prominent: true)
        }
        .frame(width: 760, alignment: .leading)
        .focusSection()
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "新增连接" : "编辑连接").font(TVTokens.Typography.sectionTitle)
            field("显示名称", text: $draft.name)
            HStack(spacing: 12) {
                Button("SMB") { draft.kind = .smb; draft.port = "445" }
                    .tvAdaptiveGlassButtonStyle(prominent: draft.kind == .smb)
                Button("WebDAV") { draft.kind = .webdav; draft.port = "80" }
                    .tvAdaptiveGlassButtonStyle(prominent: draft.kind == .webdav)
            }
            field("主机地址", text: $draft.host)
            field("端口", text: $draft.port)
            field("用户名", text: $draft.username)
            field("密码（留空保留原密码）", text: $password, secure: true)
            field(draft.kind == .smb ? "共享名 / 子路径（可留空）" : "WebDAV 路径", text: $draft.sharePath)
            AdaptiveGlassContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("保存") { save() }.tvAdaptiveGlassButtonStyle(prominent: true)
                    if let editing {
                        Button("删除") { env.remove(source: editing); self.editing = nil }.tvAdaptiveGlassButtonStyle()
                        Button("打开") { onSelect(editing) }.tvAdaptiveGlassButtonStyle()
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .tvGlassSurface()
        .focusSection()
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(TVTokens.Typography.tertiary).foregroundStyle(TVTokens.Color.secondaryText)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        }
    }

    private func beginNew() {
        editing = nil
        draft = Draft()
        password = ""
    }

    private func beginEdit(_ source: MediaSourceConfig) {
        editing = source
        draft = Draft(name: source.name, kind: source.kind, host: source.host, port: String(source.port),
                      username: source.username, sharePath: source.sharePath, useTLS: source.useTLS, anonymous: source.enableAnonymous)
        password = ""
    }

    private func save() {
        let config = MediaSourceConfig(
            id: editing?.id ?? UUID(),
            name: draft.name.isEmpty ? draft.host : draft.name,
            kind: draft.kind,
            host: draft.host,
            port: Int(draft.port) ?? draft.kind.defaultPort,
            username: draft.username,
            sharePath: draft.sharePath,
            useTLS: draft.useTLS,
            enableAnonymous: draft.anonymous
        )
        env.upsert(source: config, password: password.isEmpty ? nil : password)
        editing = config
    }
}
