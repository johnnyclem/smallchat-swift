import SwiftUI
import UniformTypeIdentifiers
import SmallChat

struct ServerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Text("MCP Server")
                        .font(.largeTitle.bold())
                    Spacer()
                    StatusBadge(running: state.serverRunning)
                }

                Text("Start and manage an MCP 2024-11-05 compliant tool server.")
                    .foregroundStyle(.secondary)

                Divider()

                // Server Configuration
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Source artifact path", text: $state.serverSourcePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                chooseServerSource()
                            }
                        }

                        HStack(spacing: 16) {
                            HStack {
                                Text("Host:")
                                TextField("127.0.0.1", text: $state.serverHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                            }
                            HStack {
                                Text("Port:")
                                TextField("3001", value: $state.serverPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                        }

                        HStack {
                            Text("Database:")
                            TextField("smallchat.db", text: $state.serverDbPath)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Session TTL:")
                            TextField("24", value: $state.serverSessionTTLHours, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("hours")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                // Security Options
                GroupBox("Security & Observability") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable OAuth 2.1 Authentication", isOn: $state.serverEnableAuth)
                        Toggle("Enable Rate Limiting", isOn: $state.serverEnableRateLimit)
                        if state.serverEnableRateLimit {
                            HStack {
                                Text("  Max RPM:")
                                TextField("600", value: $state.serverRateLimitRPM, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                        }
                        Toggle("Enable Audit Logging", isOn: $state.serverEnableAudit)
                    }
                    .padding(4)
                }

                // Start/Stop
                HStack(spacing: 12) {
                    if state.serverRunning {
                        Button(action: { Task { await stopServer() } }) {
                            Label("Stop Server", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(action: { Task { await startServer() } }) {
                            Label("Start Server", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.serverSourcePath.isEmpty)
                    }

                    if state.serverRunning {
                        Button(action: { Task { await refreshMetrics() } }) {
                            Label("Refresh Metrics", systemImage: "arrow.clockwise")
                        }
                    }
                }

                // Endpoints
                if state.serverRunning {
                    GroupBox("Endpoints") {
                        VStack(alignment: .leading, spacing: 4) {
                            EndpointRow(label: "Discovery", path: "/.well-known/mcp.json", host: state.serverHost, port: state.serverPort)
                            EndpointRow(label: "JSON-RPC", path: "/", host: state.serverHost, port: state.serverPort)
                            EndpointRow(label: "SSE", path: "/sse", host: state.serverHost, port: state.serverPort)
                            EndpointRow(label: "Health", path: "/health", host: state.serverHost, port: state.serverPort)
                            EndpointRow(label: "Metrics", path: "/metrics", host: state.serverHost, port: state.serverPort)
                        }
                        .padding(4)
                    }
                }

                // Metrics
                if !state.serverMetrics.isEmpty {
                    GroupBox("Server Metrics") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            ForEach(state.serverMetrics.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                GridRow {
                                    Text(key.replacingOccurrences(of: "_", with: " ").capitalized + ":")
                                        .fontWeight(.medium)
                                    Text(value)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                // Log
                if !state.serverLog.isEmpty {
                    LogView(state.serverLog, title: "Server Log")
                        .frame(minHeight: 150, maxHeight: 300)
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func chooseServerSource() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select toolkit artifact or source directory"
        if panel.runModal() == .OK, let url = panel.url {
            appState.serverSourcePath = url.path
        }
        #endif
    }

    @MainActor
    private func startServer() async {
        appState.serverLog.append("Starting MCP server on \(appState.serverHost):\(appState.serverPort)...")
        appState.serverLog.append("  Source: \(appState.serverSourcePath)")
        appState.serverLog.append("  Auth: \(appState.serverEnableAuth ? "enabled" : "disabled")")
        appState.serverLog.append("  Rate limiting: \(appState.serverEnableRateLimit ? "enabled (\(appState.serverRateLimitRPM) rpm)" : "disabled")")
        appState.serverLog.append("  Audit: \(appState.serverEnableAudit ? "enabled" : "disabled")")

        do {
            let sessionTTLMs = Int(appState.serverSessionTTLHours * 3_600_000)
            let config = MCPServerConfig(
                port: appState.serverPort,
                host: appState.serverHost,
                sourcePath: appState.serverSourcePath,
                dbPath: appState.serverDbPath,
                enableAuth: appState.serverEnableAuth,
                enableRateLimit: appState.serverEnableRateLimit,
                rateLimitRPM: appState.serverRateLimitRPM,
                enableAudit: appState.serverEnableAudit,
                sessionTTLMs: sessionTTLMs
            )

            let server = try MCPServer(config: config)
            try await server.start()

            appState.mcpServer = server
            appState.serverRunning = true
            appState.serverLog.append("Server running on http://\(appState.serverHost):\(appState.serverPort)")

            await refreshMetrics()
        } catch {
            appState.serverLog.append("ERROR: Failed to start server: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func stopServer() async {
        appState.serverLog.append("Shutting down server...")
        do {
            try await appState.mcpServer?.stop()
            appState.mcpServer = nil
            appState.serverRunning = false
            appState.serverMetrics = [:]
            appState.serverLog.append("Server stopped.")
        } catch {
            appState.serverLog.append("ERROR: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func refreshMetrics() async {
        guard let server = appState.mcpServer else { return }
        let snapshot = await server.serverMetrics.snapshot()
        var metrics: [String: String] = [:]
        for (key, value) in snapshot {
            switch value {
            case .int(let i): metrics[key] = "\(i)"
            case .double(let d): metrics[key] = String(format: "%.4f", d)
            case .string(let s): metrics[key] = s
            default: metrics[key] = "\(value)"
            }
        }
        appState.serverMetrics = metrics
    }
}

// MARK: - Supporting Views

struct StatusBadge: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? .green : .red)
                .frame(width: 10, height: 10)
            Text(running ? "Running" : "Stopped")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: Capsule())
    }
}

struct EndpointRow: View {
    let label: String
    let path: String
    let host: String
    let port: Int

    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
                .frame(width: 100, alignment: .leading)
            Text("http://\(host):\(port)\(path)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
