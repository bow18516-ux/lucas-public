import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct MCPServerDraft: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var enabled: Bool
    var url: String?
    var oauthClientID: String
    var oauthToken: String
    var oauthAuthURL: String
    var trustReadOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, enabled, url
        case oauthClientID, oauthToken, oauthAuthURL, trustReadOnly
    }

    init(
        id: String,
        name: String,
        command: String,
        args: [String],
        enabled: Bool,
        url: String?,
        oauthClientID: String = "",
        oauthToken: String = "",
        oauthAuthURL: String = "",
        trustReadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.enabled = enabled
        self.url = url
        self.oauthClientID = oauthClientID
        self.oauthToken = oauthToken
        self.oauthAuthURL = oauthAuthURL
        self.trustReadOnly = trustReadOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try container.decodeIfPresent(String.self, forKey: .url)
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        oauthToken = try container.decodeIfPresent(String.self, forKey: .oauthToken) ?? ""
        oauthAuthURL = try container.decodeIfPresent(String.self, forKey: .oauthAuthURL) ?? ""
        trustReadOnly = try container.decodeIfPresent(Bool.self, forKey: .trustReadOnly) ?? false
    }

    var isHTTP: Bool {
        if let url, !url.isEmpty { return true }
        return false
    }
}

struct MCPSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var servers: [MCPServerDraft] = []
    @State private var statuses: [String: (state: String, tools: Int)] = [:]
    @State private var name = ""
    @State private var url = ""
    @State private var command = "python3"
    @State private var arguments = ""
    @State private var oauthClientID = ""
    @State private var oauthToken = ""
    @State private var oauthAuthURL = ""
    @State private var busy = false
    @State private var message: String?
    @State private var expandedServerID: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "MCP 服务", subtitle: "stdio / HTTP MCP；预设可一键加入，刷新后并进对话工具", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    addCard
                    listCard
                    eventsCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 20)
            }
        }
        .task {
            await reload()
            await model.loadMCPEvents()
        }
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近事件")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("只读")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await model.loadMCPEvents() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.textSecondary)
            }

            if model.mcpEvents.isEmpty {
                Text("暂无 mcp.events 记录")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.mcpEvents.prefix(10))) { event in
                        HStack(spacing: 8) {
                            Text(event.serverID.isEmpty ? "—" : event.serverID)
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.accent.opacity(0.9))
                                .frame(width: 100, alignment: .leading)
                                .lineLimit(1)
                            Text(event.event)
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.shortTime(event.createdAt))
                                .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加服务")
                .font(.system(size: SettingsMetrics.bodySize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                Text("预设")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Button("Echo (stdio)") {
                    applyPresetEcho()
                }
                .buttonStyle(.pressable)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
                Button("HTTP 示例") {
                    applyPresetHTTP()
                }
                .buttonStyle(.pressable)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 10) {
                TextField("名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 110)
                TextField("HTTP URL（可选，填了就忽略命令）", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 260)
                TextField("参数（空格分隔）", text: $arguments)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                Button {
                    Task { await addServer() }
                } label: {
                    Text("添加")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.pressable)
                .disabled(busy || name.isEmpty || (url.isEmpty && command.isEmpty))
            }

            HStack(spacing: 10) {
                TextField("stdio 命令（HTTP 模式留空）", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 240)
                Spacer()
            }

            if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HTTP OAuth（可选）")
                        .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 10) {
                        TextField("Client ID", text: $oauthClientID)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .padding(7)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            .frame(width: 160)
                        TextField("授权页 URL", text: $oauthAuthURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                            .padding(7)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        Button("打开授权页") {
                            openAuthURL(oauthAuthURL)
                        }
                        .buttonStyle(.pressable)
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.accent)
                        .disabled(oauthAuthURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    SecureField("Access Token", text: $oauthToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                        .padding(7)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已配置服务")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(servers.count)")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.textSecondary)
            }

            if servers.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "globe.asia.australia")
                                .font(.system(size: SettingsMetrics.metricSize, weight: .light))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            Text("还没有配置 MCP 服务")
                                .font(.system(size: SettingsMetrics.labelSize))
                                .foregroundStyle(Theme.textPrimary)
                            Text("填入命令和参数，例如 python3 /path/to/server.py")
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(statusColor(server.id))
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(serverSubtitle(server))
                                        .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: bindingEnabled(for: server))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .tint(Theme.accent)
                                    .controlSize(.mini)
                                Toggle("信任只读", isOn: bindingTrustReadOnly(for: server))
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .toggleStyle(.checkbox)
                                    .help("仅当该服务的工具声明 readOnlyHint 时才免审批。默认仍要审批。")
                                Text(statusLabel(server.id))
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .foregroundStyle(Theme.textSecondary)
                                if server.isHTTP {
                                    Button {
                                        withAnimation {
                                            expandedServerID = expandedServerID == server.id ? nil : server.id
                                        }
                                    } label: {
                                        Image(systemName: "key")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .buttonStyle(.pressable)
                                    .help("OAuth")
                                }
                                Button {
                                    Task { await reconnect(server) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.pressable)
                                .help("重新连接")
                                Button {
                                    Task { await removeServer(server) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.pressable)
                            }

                            if server.isHTTP, expandedServerID == server.id {
                                oauthEditor(for: server)
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private func statusColor(_ id: String) -> Color {
        switch statuses[id]?.state {
        case "ready": return Theme.success
        case "error": return Color.red.opacity(0.85)
        default: return Theme.textSecondary.opacity(0.5)
        }
    }

    private func statusLabel(_ id: String) -> String {
        guard let status = statuses[id] else { return "未启动" }
        if status.state == "ready" { return "\(status.tools) 个工具" }
        return "连接失败"
    }

    private func serverSubtitle(_ server: MCPServerDraft) -> String {
        if let url = server.url, !url.isEmpty {
            return "HTTP · \(url)"
        }
        return ([server.command] + server.args).joined(separator: " ")
    }

    private func applyPresetEcho() {
        let candidates = [
            "/Users/w/Desktop/japlosv2/clone/scripts/mcp_echo_server.py",
            FileManager.default.currentDirectoryPath + "/scripts/mcp_echo_server.py",
        ]
        let script = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        name = "echo"
        url = ""
        command = "python3"
        arguments = script
        message = "已填入 Echo 预设，点添加后生效"
    }

    private func applyPresetHTTP() {
        name = "http-echo"
        url = "http://127.0.0.1:8765/mcp"
        command = ""
        arguments = ""
        message = "已填入 HTTP 示例；请先本地跑起 mcp_http_server.py 再添加"
    }

    private func openAuthURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func oauthEditor(for server: MCPServerDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OAuth")
                .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                TextField("Client ID", text: bindingOAuth(server.id, keyPath: \.oauthClientID))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                TextField("授权页 URL", text: bindingOAuth(server.id, keyPath: \.oauthAuthURL))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                Button("打开授权页") {
                    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                        openAuthURL(servers[idx].oauthAuthURL)
                    }
                }
                .buttonStyle(.pressable)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
            }
            SecureField("Access Token", text: bindingOAuth(server.id, keyPath: \.oauthToken))
                .textFieldStyle(.plain)
                .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                .padding(6)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            Button("保存 OAuth") {
                Task { await persist() }
            }
            .buttonStyle(.pressable)
            .font(.system(size: SettingsMetrics.captionSize))
            .foregroundStyle(Theme.accent)
        }
        .padding(.top, 2)
    }

    private func bindingOAuth(_ id: String, keyPath: WritableKeyPath<MCPServerDraft, String>) -> Binding<String> {
        Binding(
            get: { servers.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == id }) {
                    servers[idx][keyPath: keyPath] = value
                }
            }
        )
    }

    private func bindingTrustReadOnly(for server: MCPServerDraft) -> Binding<Bool> {
        Binding(
            get: { servers.first(where: { $0.id == server.id })?.trustReadOnly ?? false },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].trustReadOnly = value
                    Task { await persist() }
                }
            }
        )
    }

    private func bindingEnabled(for server: MCPServerDraft) -> Binding<Bool> {
        Binding(
            get: { servers.first(where: { $0.id == server.id })?.enabled ?? true },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].enabled = value
                    Task { await persist() }
                }
            }
        )
    }

    private func reconnect(_ server: MCPServerDraft) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client.callAsync(.mcpRefresh, arguments: .object([:]), timeout: 60)
            await reload()
            message = "已刷新 \(server.name)"
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    private func reload() async {
        do {
            let list = try await model.client.callAsync(.configurationList, arguments: .object([:]))
            if let entry = list.arrayValue?.first(where: { $0["path"]?.stringValue == "mcp.servers" }),
               let value = entry["value"],
               let data = try? ProtocolCoding.encode(value) {
                servers = (try? ProtocolCoding.decode([MCPServerDraft].self, from: data)) ?? []
            }
            let status = try await model.client.callAsync(.mcpStatus, arguments: .object([:]))
            var map: [String: (String, Int)] = [:]
            for item in status["servers"]?.arrayValue ?? [] {
                guard let id = item["id"]?.stringValue else { continue }
                map[id] = (
                    item["state"]?.stringValue ?? "unknown",
                    item["toolCount"]?.intValue ?? 0
                )
            }
            statuses = map
            await model.loadMCPEvents()
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    private func addServer() async {
        busy = true
        defer { busy = false }
        let isHTTP = !url.trimmingCharacters(in: .whitespaces).isEmpty
        let draft = MCPServerDraft(
            id: "srv-\(UUID().uuidString.prefix(8).lowercased())",
            name: name.isEmpty ? (isHTTP ? url : command) : name,
            command: isHTTP ? "" : command,
            args: isHTTP ? [] : arguments.split(separator: " ").map(String.init),
            enabled: true,
            url: isHTTP ? url.trimmingCharacters(in: .whitespaces) : nil,
            oauthClientID: isHTTP ? oauthClientID : "",
            oauthToken: isHTTP ? oauthToken : "",
            oauthAuthURL: isHTTP ? oauthAuthURL : ""
        )
        servers.append(draft)
        await persist()
        name = ""
        arguments = ""
        url = ""
        oauthClientID = ""
        oauthToken = ""
        oauthAuthURL = ""
    }

    private func removeServer(_ server: MCPServerDraft) async {
        servers.removeAll { $0.id == server.id }
        await persist()
    }

    private func persist() async {
        do {
            let value = try ProtocolCoding.decode(
                JSONValue.self,
                from: ProtocolCoding.encode(servers)
            )
            _ = try await model.client.callAsync(.configurationSet, arguments: .object([
                "path": .string("mcp.servers"),
                "value": value,
            ]))
            _ = try await model.client.callAsync(.mcpRefresh, arguments: .object([:]), timeout: 60)
            await reload()
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }
}
