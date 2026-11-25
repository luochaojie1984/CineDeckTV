import SwiftUI
import NetworkVFS

/// 源管理器：支持 SMB / WebDAV 添加编辑、地址/端口自动清洗、匿名模式、Keychain 已存密码提示、连接测试及 20 MB 局域网吞吐测速。
public struct SourceManagerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding public var prefillHost: String?
    @Binding public var prefillKind: MediaSourceKind
    public var onOpenSource: (MediaSourceConfig) -> Void

    @State private var editingID: UUID?
    @State private var name = ""
    @State private var kind: MediaSourceKind = .smb
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var sharePath = "/"
    @State private var useTLS = false
    @State private var enableAnonymous = false
    @State private var statusBanner: String?
    @State private var isTesting = false
    @State private var speedTestSheetOpen = false
    @State private var speedTestResult: String?

    public init(
        prefillHost: Binding<String?> = .constant(nil),
        prefillKind: Binding<MediaSourceKind> = .constant(.smb),
        onOpenSource: @escaping (MediaSourceConfig) -> Void = { _ in }
    ) {
        self._prefillHost = prefillHost
        self._prefillKind = prefillKind
        self.onOpenSource = onOpenSource
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("已配置片源")
                        .font(TVTokens.Typography.sectionTitle)

                    if env.sources.isEmpty {
                        Text("尚未配置任何片源。请在右侧填写 NAS IP 或主机名并保存。")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
                    } else {
                        ForEach(env.sources) { src in
                            HStack(spacing: 14) {
                                Button {
                                    loadForEdit(src)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: src.kind == .smb ? "externaldrive.fill.badge.wifi" : "globe")
                                            .font(.system(size: 30))
                                            .foregroundStyle(TVTokens.Color.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(src.name)
                                                .font(TVTokens.Typography.gridPrimary)
                                                .lineLimit(1)
                                            Text("\(src.kind.displayName) · \(src.host):\(src.port) \(src.sharePath)")
                                                .font(TVTokens.Typography.tertiary)
                                                .foregroundStyle(TVTokens.Color.secondaryText)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(18)
                                }
                                .buttonStyle(TVCardButtonStyle())

                                Button {
                                    onOpenSource(src)
                                } label: {
                                    Label("打开", systemImage: "folder.fill")
                                        .font(TVTokens.Typography.button)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 16)
                                }
                                .tvAdaptiveGlassButtonStyle(prominent: true)

                                Button(role: .destructive) {
                                    env.remove(source: src)
                                    if editingID == src.id { resetForm() }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 22))
                                        .padding(16)
                                }
                                .tvAdaptiveGlassButtonStyle()
                            }
                        }
                    }

                    AdaptiveGlassContainer(spacing: 14) {
                        HStack(spacing: 14) {
                            Button("新建服务器", action: resetForm)
                                .tvAdaptiveGlassButtonStyle()
                            Button("20 MB 局域网测速") {
                                speedTestSheetOpen = true
                            }
                            .tvAdaptiveGlassButtonStyle()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(editingID == nil ? "添加共享服务器" : "编辑共享服务器")
                        .font(TVTokens.Typography.sectionTitle)

                    Picker("协议", selection: $kind) {
                        ForEach(MediaSourceKind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, newKind in
                        if editingID == nil {
                            port = String(newKind.defaultPort)
                            if newKind == .smb { useTLS = false }
                        }
                    }

                    TextField("显示名称（如：客厅 Synology NAS）", text: $name)
                    TextField("主机地址或 IP（可含端口，如 nas.local）", text: $host)
                    HStack(spacing: 12) {
                        TextField("端口（默认 \(kind.defaultPort)）", text: $port)
                        TextField(kind == .smb ? "共享名/路径（留空列全盘）" : "WebDAV 路径（如 /dav）", text: $sharePath)
                    }

                    Toggle("匿名访客连接", isOn: $enableAnonymous)
                    if !enableAnonymous {
                        TextField("用户名（Windows 可填 DOMAIN\\用户名）", text: $username)
                        SecureField(
                            hasExistingPassword ? "已保存密码（留空保留原密码）" : "密码",
                            text: $password
                        )
                    }
                    if kind == .webdav {
                        Toggle("启用 HTTPS (TLS)", isOn: $useTLS)
                    }

                    if let statusBanner {
                        Text(statusBanner)
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(statusBanner.contains("成功") || statusBanner.contains("已") ? .green : .yellow)
                    }

                    AdaptiveGlassContainer(spacing: 12) {
                        HStack(spacing: 14) {
                            Button {
                                Task { await testConnection() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isTesting { ProgressView() }
                                    Text("测试连接")
                                }
                            }
                            .tvAdaptiveGlassButtonStyle()

                            Button("保存") {
                                _ = saveValidatedSource()
                            }
                            .tvAdaptiveGlassButtonStyle()

                            Button("保存并打开") {
                                if let saved = saveValidatedSource() {
                                    onOpenSource(saved)
                                }
                            }
                            .tvAdaptiveGlassButtonStyle(prominent: true)
                        }
                    }
                }
                .padding(28)
                .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
        .padding(.vertical, 24)
        .onAppear {
            applyPrefillIfNeeded()
            if env.previewScenario == .sources, editingID == nil, let first = env.sources.first {
                loadForEdit(first)
                statusBanner = "SMB2/3 连接就绪 · 延迟 1.8 ms"
            }
        }
        .onChange(of: prefillHost) { _, _ in
            applyPrefillIfNeeded()
        }
        .sheet(isPresented: $speedTestSheetOpen) {
            LanSpeedTestSheet(
                source: buildConfigCandidate() ?? env.sources.first,
                resultText: $speedTestResult
            )
            .environmentObject(env)
        }
    }

    private var hasExistingPassword: Bool {
        guard let editingID else { return false }
        return env.hasSavedPassword(for: editingID)
    }

    private func applyPrefillIfNeeded() {
        if let prefillHost, !prefillHost.isEmpty {
            resetForm()
            kind = prefillKind
            port = String(prefillKind.defaultPort)
            host = prefillHost
            name = prefillHost.replacingOccurrences(of: ".local", with: "")
            self.prefillHost = nil
        }
    }

    private func loadForEdit(_ src: MediaSourceConfig) {
        editingID = src.id
        name = src.name
        kind = src.kind
        host = src.host
        port = String(src.port)
        username = src.username
        password = ""
        sharePath = src.sharePath
        useTLS = src.useTLS
        enableAnonymous = src.enableAnonymous
        statusBanner = nil
    }

    private func resetForm() {
        editingID = nil
        name = ""
        host = ""
        port = String(kind.defaultPort)
        username = ""
        password = ""
        sharePath = "/"
        useTLS = false
        enableAnonymous = false
        statusBanner = nil
    }

    private func buildConfigCandidate() -> MediaSourceConfig? {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedTLS = useTLS
        for scheme in ["smb://", "https://", "http://"] {
            if cleanHost.lowercased().hasPrefix(scheme) {
                if scheme == "https://" { detectedTLS = true }
                cleanHost = String(cleanHost.dropFirst(scheme.count))
                break
            }
        }
        while cleanHost.hasSuffix("/") { cleanHost.removeLast() }

        var parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        if let colonIdx = cleanHost.lastIndex(of: ":"), !cleanHost.contains("]") {
            let suffix = String(cleanHost[cleanHost.index(after: colonIdx)...])
            if let inlineP = Int(suffix), (1...65535).contains(inlineP) {
                cleanHost = String(cleanHost[..<colonIdx])
                parsedPort = parsedPort ?? inlineP
            }
        }
        guard !cleanHost.isEmpty else { return nil }

        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = displayName.isEmpty ? cleanHost : displayName
        let effectivePort = parsedPort ?? kind.defaultPort
        let cleanShare = sharePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaSourceConfig(
            id: editingID ?? UUID(),
            name: finalName,
            kind: kind,
            host: cleanHost,
            port: effectivePort,
            username: enableAnonymous ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines),
            sharePath: cleanShare.isEmpty ? "/" : cleanShare,
            useTLS: detectedTLS,
            enableAnonymous: enableAnonymous
        )
    }

    @discardableResult
    private func saveValidatedSource() -> MediaSourceConfig? {
        guard let config = buildConfigCandidate() else {
            statusBanner = "请输入有效的服务器主机地址或 IP"
            UISoundPlayer.error()
            return nil
        }
        env.upsert(source: config, password: password.isEmpty ? nil : password)
        editingID = config.id
        statusBanner = "已保存「\(config.name)」"
        UISoundPlayer.select()
        return config
    }

    private func testConnection() async {
        guard let candidate = buildConfigCandidate() else {
            statusBanner = "请输入有效的主机地址"
            return
        }
        isTesting = true
        statusBanner = "正在握手检测 \(candidate.host):\(candidate.port)…"
        let existingPwd = password.isEmpty ? (editingID.flatMap { KeychainCredentialStore.password(accountID: $0.uuidString) }) : password
        let provider: any VFSProvider = candidate.kind == .smb
            ? AMSMB2Provider(config: candidate, password: existingPwd)
            : WebDAVProvider(config: candidate, password: existingPwd)
        do {
            try await provider.connect()
            let list = try await provider.list(path: "/")
            await provider.disconnect()
            statusBanner = "连接成功！根目录发现 \(list.count) 项"
            UISoundPlayer.select()
        } catch {
            await provider.disconnect()
            statusBanner = "连接失败：\(error.localizedDescription)"
            UISoundPlayer.error()
        }
        isTesting = false
    }
}

/// 20 MB 局域网吞吐测速独立弹窗。
private struct LanSpeedTestSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let source: MediaSourceConfig?
    @Binding var resultText: String?

    @State private var isRunning = false
    @State private var detailText = "将选取首个大于 1 MB 的视频文件连续读取 20 MB，评估当前网线/Wi-Fi 对高码率 4K 蓝光原盘的承载余量。"

    var body: some View {
        VStack(spacing: 24) {
            Text("局域网 20 MB 吞吐测速")
                .font(TVTokens.Typography.pageTitle)
            if let source {
                Text("目标源：\(source.name) (\(source.host))")
                    .font(TVTokens.Typography.secondary)
                    .foregroundStyle(TVTokens.Color.secondaryText)
            }
            Text(resultText ?? detailText)
                .font(TVTokens.Typography.sectionTitle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            AdaptiveGlassContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button {
                        Task { await runBenchmark() }
                    } label: {
                        HStack(spacing: 10) {
                            if isRunning { ProgressView() }
                            Text(isRunning ? "测速中…" : "开始测速")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: true)
                    .disabled(isRunning || source == nil)

                    Button("关闭") { dismiss() }
                        .tvAdaptiveGlassButtonStyle()
                }
            }
        }
        .padding(48)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    private func runBenchmark() async {
        guard let source else { return }
        isRunning = true
        resultText = nil
        do {
            let provider = try await env.provider(for: source)
            let items = try await provider.list(path: "/")
            guard let sample = items.first(where: { !$0.isDirectory && $0.size > 1_048_576 }) else {
                detailText = "当前源根目录未找到大于 1 MB 的测试文件，请浏览进视频目录后重试。"
                isRunning = false
                return
            }
            if let smb = provider as? AMSMB2Provider {
                let stats = try await smb.benchmarkThroughput(at: sample.path)
                let mbpsNet = stats.megabytesPerSec * 8
                detailText = String(format: "读取 %.1f MB 用时 %.2f 秒\n实测吞吐：%.1f MB/s（%.0f Mbps）\n%@",
                                    Double(stats.bytesRead) / (1024 * 1024),
                                    stats.seconds,
                                    stats.megabytesPerSec,
                                    mbpsNet,
                                    stats.megabytesPerSec > 18 ? "✅ 充裕支持 4K 蓝光高码率直放" : "⚠️ 建议改接千兆有线网线以获得更佳拖拽响应")
            } else {
                let start = CFAbsoluteTimeGetCurrent()
                let data = try await provider.read(path: sample.path, offset: 0, length: min(20 * 1024 * 1024, Int(sample.size)))
                let sec = max(0.01, CFAbsoluteTimeGetCurrent() - start)
                let speed = Double(data.count) / (1024 * 1024) / sec
                detailText = String(format: "实测吞吐：%.1f MB/s（%.0f Mbps）", speed, speed * 8)
            }
        } catch {
            detailText = "测速失败：\(error.localizedDescription)"
        }
        isRunning = false
    }
}
