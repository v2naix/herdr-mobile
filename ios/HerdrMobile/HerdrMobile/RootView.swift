import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            switch model.state.screen {
            case .setup:
                SetupView(model: model)
            case .configured:
                ConfiguredView(model: model)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelDestructiveAction() } }
            ),
            titleVisibility: .visible
        ) {
            if let presentedAction = model.pendingConfirmation {
                Button(confirmationButtonTitle, role: .destructive) {
                    Task { await model.confirmDestructiveAction(presentedAction) }
                }
            }
            Button("取消", role: .cancel) {
                model.cancelDestructiveAction()
            }
        } message: {
            Text("将撤销当前会话，并从此设备删除服务器地址和令牌。即使服务器不可达，本地数据也会清除。")
        }
    }

    private var confirmationTitle: String {
        model.pendingConfirmation == .replaceServer ? "更换服务器？" : "退出登录？"
    }

    private var confirmationButtonTitle: String {
        model.pendingConfirmation == .replaceServer ? "清除并更换" : "退出并清除"
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField(
                    "https://mac.example.ts.net",
                    text: Binding(
                        get: { model.state.origin },
                        set: { model.updateOrigin($0) }
                    )
                )

                SecureField(
                    "Bootstrap token",
                    text: Binding(
                        get: { model.state.token },
                        set: { model.updateToken($0) }
                    )
                )
            } header: {
                Text("受信任的 Mac")
            } footer: {
                Text("仅接受通过系统证书验证的 HTTPS 地址。令牌会绑定到本机设备密码，不会同步到其他设备。")
            }

            if let error = model.state.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("setup-error")
                }
            }

            Section {
                Button {
                    let origin = model.state.origin
                    let token = model.state.token
                    Task { await model.submitSetup(origin: origin, token: token) }
                } label: {
                    if model.state.isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("验证并保存")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.state.isWorking)
            }
        }
        .navigationTitle("设置 Herdr Mobile")
    }
}

private struct ConfiguredView: View {
    @ObservedObject var model: AppModel
    @State private var isDiagnosticsPresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(PaneStatus.primaryOrder, id: \.self) { status in
                        PaneStatusBox(model: model, status: status)
                    }
                }
                .padding()

                HStack(spacing: 8) {
                    Label(connectionLabel, systemImage: connectionSymbol)
                        .font(.footnote)
                        .foregroundStyle(connectionColor)
                    if let error = model.state.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if canRetryConnection {
                        Button("立即重试") { model.retryNow() }
                            .font(.footnote)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                if let pane = model.state.selectedPane {
                    PaneSupervisionView(model: model, pane: pane)
                } else {
                    ContentUnavailableView(
                        model.state.panes.isEmpty && model.state.connection == .online
                            ? "没有 Agent pane"
                            : "选择一个任务",
                        systemImage: "rectangle.stack"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Herdr Mobile")
        .toolbar {
            if !model.state.panes(in: .unknown).isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("未知 pane", systemImage: "questionmark.circle") {
                        ForEach(model.state.panes(in: .unknown)) { pane in
                            Button(pane.title) {
                                Task { await model.openPane(pane) }
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("诊断信息", systemImage: "stethoscope") {
                        isDiagnosticsPresented = true
                    }
                    Button("更换服务器", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        model.requestServerReplacement()
                    }
                    Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.requestLogout()
                    }
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $isDiagnosticsPresented) {
            NavigationStack {
                List {
                    LabeledContent("服务器", value: model.diagnostics.origin)
                    LabeledContent("状态", value: connectionLabel)
                    LabeledContent("重试次数", value: String(model.diagnostics.retryCount))
                    if let date = model.diagnostics.lastSynchronization {
                        LabeledContent("上次同步", value: date.formatted())
                    }
                    if let epoch = model.diagnostics.serverEpoch {
                        LabeledContent("服务端 epoch", value: epoch)
                    }
                    if let version = model.diagnostics.protocolVersion {
                        LabeledContent("协议版本", value: String(version))
                    }
                    if let error = model.diagnostics.sanitizedError {
                        LabeledContent("最近错误", value: error)
                    }
                }
                .navigationTitle("诊断信息")
            }
        }
    }

    private var canRetryConnection: Bool {
        model.state.connection == .offline
            || model.state.connection == .reconnecting
            || model.state.connection == .backendUnavailable
    }

    private var connectionLabel: String {
        switch model.state.connection {
        case .connecting: "正在连接"
        case .online: "在线"
        case .reconnecting: "正在重新连接"
        case .offline: "离线"
        case .suspended: "已暂停（仅前台连接）"
        case .authenticationRequired: "需要重新认证"
        case .tlsFailure: "TLS 验证失败"
        case .incompatibleProtocol: "协议不兼容"
        case .backendUnavailable: "后端不可用"
        }
    }

    private var connectionSymbol: String {
        model.state.connection == .online ? "checkmark.circle.fill" : "network.slash"
    }

    private var connectionColor: Color {
        model.state.connection == .online ? .green : .secondary
    }
}

private struct PaneStatusBox: View {
    @ObservedObject var model: AppModel
    let status: PaneStatus

    private var panes: [AgentPane] { model.state.panes(in: status) }

    var body: some View {
        Button {
            Task { await model.openFirstPane(in: status) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                Text(String(panes.count))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(panes.isEmpty)
        .contextMenu {
            ForEach(panes) { pane in
                Button(pane.title) {
                    Task { await model.openPane(pane) }
                }
            }
        }
    }

    private var symbolName: String {
        switch status {
        case .blocked: "xmark.octagon"
        case .done: "checkmark.circle"
        case .working: "clock"
        case .idle: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }
}
