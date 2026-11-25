import SwiftUI
import NetworkVFS

/// 源管理器：2 栏液态玻璃服务器矩阵卡片（每卡内置焦点区操作坞，无孤立悬空按钮，支持 20 MB 测速与编辑）。
public struct SourceManagerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding public var prefillHost: String?
    @Binding public var prefillKind: MediaSourceKind
    @Binding public var isModalPresented: Bool
    public var onOpenSource: (MediaSourceConfig) -> Void

    @State private var editingConfig: MediaSourceConfig?
    @State private var isCreatingNew = false
    @State private var speedTestSource: MediaSourceConfig?

    public init(
        prefillHost: Binding<String?> = .constant(nil),
        prefillKind: Binding<MediaSourceKind> = .constant(.smb),
        isModalPresented: Binding<Bool> = .constant(false),
        onOpenSource: @escaping (MediaSourceConfig) -> Void = { _ in }
    ) {
        self._prefillHost = prefillHost
        self._prefillKind = prefillKind
        self._isModalPresented = isModalPresented
        self.onOpenSource = onOpenSource
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("服务器与共享源")
                            .font(TVTokens.Typography.pageTitle)
                        Text("直连局域网 SMB2/3 与 WebDAV · 常驻预读与 20 MB 真实吞吐测速")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    Spacer()
                    AdaptiveGlassContainer(spacing: 14) {
                        Button {
                            editingConfig = nil
                            isCreatingNew = true
                        } label: {
                            Label("添加 SMB / WebDAV", systemImage: "plus.circle.fill")
                                .font(TVTokens.Typography.button)
                                .padding(.horizontal, 26)
                                .padding(.vertical, 14)
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: true)
                        .tint(TVTokens.Color.accent)
                    }
                }
                .focusSection()

                if env.sources.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 56))
                            .foregroundStyle(TVTokens.Color.emerald)
                        Text("尚未配置任何局域网服务器")
                            .font(TVTokens.Typography.sectionTitle)
                        Text("点击右上角「添加 SMB / WebDAV」，支持 Windows / Synology / 威联通 / Alist 与 WebDAV。")
                            .font(TVTokens.Typography.secondary)
                            .foregroundStyle(TVTokens.Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(56)
                    .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
                    .focusSection()
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 26), count: 2),
                        spacing: 26
                    ) {
                        ForEach(env.sources) { src in
                            sourceCard(src)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .focusSection()
                }
            }
            .padding(.horizontal, TVTokens.Spacing.pageHorizontal)
            .padding(.vertical, 32)
        }
        .onAppear { applyPrefillIfNeeded() }
        .onChange(of: prefillHost) { _, _ in applyPrefillIfNeeded() }
        .onChange(of: isCreatingNew) { _, _ in syncModalFlag() }
        .onChange(of: editingConfig?.id) { _, _ in syncModalFlag() }
        .onChange(of: speedTestSource?.id) { _, _ in syncModalFlag() }
        .sheet(isPresented: $isCreatingNew) {
            SourceEditorSheet(
                existing: nil,
                initialHost: prefillHost,
                initialKind: prefillKind,
                onSavedAndOpen: { saved in
                    isCreatingNew = false
                    onOpenSource(saved)
                }
            )
            .environmentObject(env)
        }
        .sheet(item: $editingConfig) { src in
            SourceEditorSheet(
                existing: src,
                initialHost: nil,
                initialKind: src.kind,
                onSavedAndOpen: { saved in
                    editingConfig = nil
                    onOpenSource(saved)
                }
            )
            .environmentObject(env)
        }
        .sheet(item: $speedTestSource) { src in
            LanSpeedTestSheet(source: src)
                .environmentObject(env)
        }
    }

    private func sourceCard(_ src: MediaSourceConfig) -> some View {
        let tint = src.kind == .smb ? TVTokens.Color.accent : TVTokens.Color.violet
        let hasCred = env.hasSavedPassword(for: src.id) && !src.enableAnonymous

        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: src.kind == .smb ? "externaldrive.fill.badge.wifi" : "globe")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(
                        LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                    )
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 6) {
                    Text(src.name)
                        .font(TVTokens.Typography.sectionTitle)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text(src.kind.displayName)
                            .font(.system(size: 16, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(tint.opacity(0.24), in: Capsule())
                            .foregroundStyle(tint)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(hasCred ? TVTokens.Color.emerald : TVTokens.Color.amber)
                                .frame(width: 8, height: 8)
                            Text(hasCred ? "已保存凭据" : (src.enableAnonymous ? "匿名访客" : "未存密码"))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(TVTokens.Color.secondaryText)
                        }
                    }
                }
                Spacer()
            }

            HStack(spacing: 16) {
                Label("\(src.host):\(String(src.port))", systemImage: "network")
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(TVTokens.Color.tertiaryText)
                Label(src.sharePath.isEmpty ? "/" : src.sharePath, systemImage: "folder")
                    .lineLimit(1)
                Spacer()
            }
            .font(.system(size: 19, weight: .medium, design: .monospaced))
            .foregroundStyle(TVTokens.Color.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )

            AdaptiveGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        onOpenSource(src)
                    } label: {
                        Label("进入片库", systemImage: "folder.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: true)
                    .tint(tint)

                    Button {
                        speedTestSource = src
                    } label: {
                        Label("测速", systemImage: "speedometer")
                            .font(.system(size: 19, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                    }
                    .tvAdaptiveGlassButtonStyle()

                    Button {
                        editingConfig = src
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .font(.system(size: 19, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                    }
                    .tvAdaptiveGlassButtonStyle()

                    Spacer(minLength: 4)

                    Button(role: .destructive) {
                        env.remove(source: src)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 19, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                    }
                    .tvAdaptiveGlassButtonStyle()
                }
            }
            .focusSection()
        }
        .padding(26)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel, clear: false, tint: tint.opacity(0.08))
        .focusSection()
    }

    private func syncModalFlag() {
        isModalPresented = isCreatingNew || editingConfig != nil || speedTestSource != nil
    }

    private func applyPrefillIfNeeded() {
        if let h = prefillHost, !h.isEmpty {
            isCreatingNew = true
        }
    }
}

/// 弹窗式服务器配置编辑器（单列垂直焦点流，按遥控器返回自动关闭弹窗）。
private struct SourceEditorSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let existing: MediaSourceConfig?
    let initialHost: String?
    let initialKind: MediaSourceKind
    let onSavedAndOpen: (MediaSourceConfig) -> Void

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
    @State private var didInit = false

    private var hasExistingPassword: Bool {
        guard let existing else { return false }
        return env.hasSavedPassword(for: existing.id)
    }

    var body: some View {
        ZStack {
            CinemaAmbientBackdrop(palette: .sources)
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(existing == nil ? "添加共享服务器" : "编辑「\(existing?.name ?? "")」")
                    .font(TVTokens.Typography.pageTitle)

                HStack(spacing: 14) {
                    Text("协议类型")
                        .font(TVTokens.Typography.secondary)
                        .frame(width: 220, alignment: .leading)
                    Button("SMB (局域网共享)") {
                        kind = .smb
                        if existing == nil { port = "445"; useTLS = false }
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: kind == .smb)

                    Button("WebDAV") {
                        kind = .webdav
                        if existing == nil { port = useTLS ? "443" : "80" }
                    }
                    .tvAdaptiveGlassButtonStyle(prominent: kind == .webdav)
                }
                .focusSection()

                labeledField("显示名称", placeholder: "留空自动使用主机名（如：客厅 NAS）", text: $name)
                labeledField("主机 / IP", placeholder: "输入 IP 或主机名（如 nas.local）", text: $host)
                labeledField("端口", placeholder: "默认 \(kind.defaultPort)", text: $port)
                labeledField(kind == .smb ? "共享名 / 路径" : "WebDAV 路径", placeholder: kind == .smb ? "留空 / 列出全部共享目录，或填 /Movies" : "/dav", text: $sharePath)

                Toggle("匿名访客连接", isOn: $enableAnonymous)
                    .font(TVTokens.Typography.secondary)

                if !enableAnonymous {
                    labeledField("用户名", placeholder: "Windows 可填 DOMAIN\\用户名", text: $username)
                    HStack(spacing: 16) {
                        Text("密码")
                            .font(TVTokens.Typography.secondary)
                            .frame(width: 220, alignment: .leading)
                        SecureField(hasExistingPassword ? "已保存密码（留空保留原密码）" : "输入密码", text: $password)
                    }
                }

                if kind == .webdav {
                    Toggle("启用 HTTPS (TLS)", isOn: $useTLS)
                        .font(TVTokens.Typography.secondary)
                }

                if let statusBanner {
                    Text(statusBanner)
                        .font(TVTokens.Typography.secondary)
                        .foregroundStyle(statusBanner.contains("成功") || statusBanner.contains("已保存") ? .green : .yellow)
                }

                AdaptiveGlassContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack(spacing: 8) {
                                if isTesting { ProgressView() }
                                Text("测试连接")
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .tvAdaptiveGlassButtonStyle()

                        Button("保存") {
                            if saveValidated() != nil { dismiss() }
                        }
                        .tvAdaptiveGlassButtonStyle()

                        Button("保存并打开") {
                            if let saved = saveValidated() {
                                dismiss()
                                onSavedAndOpen(saved)
                            }
                        }
                        .tvAdaptiveGlassButtonStyle(prominent: true)

                        Spacer()

                        Button("取消") { dismiss() }
                            .tvAdaptiveGlassButtonStyle()
                    }
                }
                .focusSection()
                .padding(.top, 8)
            }
            .padding(44)
            .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
            .padding(36)
        }
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            if let existing {
                name = existing.name
                kind = existing.kind
                host = existing.host
                port = String(existing.port)
                username = existing.username
                sharePath = existing.sharePath
                useTLS = existing.useTLS
                enableAnonymous = existing.enableAnonymous
            } else {
                kind = initialKind
                port = String(initialKind.defaultPort)
                if let initialHost, !initialHost.isEmpty {
                    host = initialHost
                    name = initialHost.replacingOccurrences(of: ".local", with: "")
                }
            }
        }
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(TVTokens.Typography.secondary)
                .frame(width: 220, alignment: .leading)
            TextField(placeholder, text: text)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
        }
    }

    private func buildCandidate() -> MediaSourceConfig? {
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
        let cleanShare = sharePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaSourceConfig(
            id: existing?.id ?? UUID(),
            name: displayName.isEmpty ? cleanHost : displayName,
            kind: kind,
            host: cleanHost,
            port: parsedPort ?? kind.defaultPort,
            username: enableAnonymous ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines),
            sharePath: cleanShare.isEmpty ? "/" : cleanShare,
            useTLS: detectedTLS,
            enableAnonymous: enableAnonymous
        )
    }

    private func saveValidated() -> MediaSourceConfig? {
        guard let candidate = buildCandidate() else {
            statusBanner = "请输入有效的服务器主机地址或 IP"
            UISoundPlayer.error()
            return nil
        }
        env.upsert(source: candidate, password: password.isEmpty ? nil : password)
        statusBanner = "已保存「\(candidate.name)」"
        UISoundPlayer.select()
        return candidate
    }

    private func testConnection() async {
        guard let candidate = buildCandidate() else {
            statusBanner = "请输入有效的主机地址"
            return
        }
        isTesting = true
        statusBanner = "正在握手检测 \(candidate.host):\(candidate.port)…"
        let existingPwd = password.isEmpty ? (existing.flatMap { KeychainCredentialStore.password(accountID: $0.id.uuidString) }) : password
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
    let source: MediaSourceConfig

    @State private var isRunning = false
    @State private var detailText = "将选取首个大于 1 MB 的视频文件连续读取 20 MB，评估当前网线/Wi-Fi 对高码率 4K 蓝光原盘的承载余量。"

    var body: some View {
        VStack(spacing: 24) {
            Text("局域网 20 MB 吞吐测速")
                .font(TVTokens.Typography.pageTitle)
            Text("目标源：\(source.name) (\(source.host))")
                .font(TVTokens.Typography.secondary)
                .foregroundStyle(TVTokens.Color.secondaryText)
            Text(detailText)
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
                    .disabled(isRunning)

                    Button("关闭") { dismiss() }
                        .tvAdaptiveGlassButtonStyle()
                }
            }
            .focusSection()
        }
        .padding(48)
        .tvGlassSurface(cornerRadius: TVTokens.Radius.panel)
    }

    private func runBenchmark() async {
        isRunning = true
        do {
            let provider = try await env.provider(for: source)
            let items = try await provider.list(path: "/")
            guard let sample = items.first(where: { !$0.isDirectory && $0.size > 1_048_576 }) else {
                detailText = "当前源根目录未找到大于 1 MB 的测试文件，请确认共享路径后重试。"
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
