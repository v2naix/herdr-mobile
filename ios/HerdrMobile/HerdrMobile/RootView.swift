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
                ConsoleHeader(
                    model: model,
                    isDiagnosticsPresented: $isDiagnosticsPresented
                )

                HStack(spacing: 8) {
                    ForEach(PaneStatus.primaryOrder, id: \.self) { status in
                        PaneStatusBox(model: model, status: status)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
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
}

private struct ConsoleHeader: View {
    @ObservedObject var model: AppModel
    @Binding var isDiagnosticsPresented: Bool

    var body: some View {
        HStack {
            if !model.state.panes(in: .unknown).isEmpty {
                Menu("未知 pane", systemImage: "questionmark.circle") {
                    ForEach(model.state.panes(in: .unknown)) { pane in
                        Button(pane.title) {
                            Task { await model.openPane(pane) }
                        }
                    }
                }
                .labelStyle(.iconOnly)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("HERDR")
                    .font(.caption.weight(.black))
                    .tracking(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(connectionLabel, systemImage: connectionSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(connectionColor)
                if canRetryConnection {
                    Button("立即重试") { model.retryNow() }
                        .font(.caption)
                }
            }
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
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 9)
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
        model.state.connection == .online ? "dot.radiowaves.left.and.right" : "network.slash"
    }

    private var connectionColor: Color {
        model.state.connection == .online ? .green : .secondary
    }
}

private struct PaneStatusBox: View {
    @ObservedObject var model: AppModel
    let status: PaneStatus
    @State private var isPickerPresented = false

    private var panes: [AgentPane] { model.state.panes(in: status) }

    var body: some View {
        selector
            .accessibilityLabel("\(statusName)，\(panes.count) 个 pane")
            .accessibilityHint(panes.count == 1 ? "轻点打开唯一的 pane" : "轻点选择 pane")
            .accessibilityIdentifier("pane-status-\(status.rawValue)")
            .popover(isPresented: $isPickerPresented, arrowEdge: .top) {
                PaneSelectionPopover(panes: panes) { pane in
                    isPickerPresented = false
                    Task { await model.openPane(pane) }
                }
                .presentationCompactAdaptation(.popover)
            }
    }

    @ViewBuilder
    private var selector: some View {
        if panes.count == 1, let pane = panes.first {
            Button {
                Task { await model.openPane(pane) }
            } label: {
                statusBox
            }
            .buttonStyle(.plain)
        } else {
            Button {
                isPickerPresented = true
            } label: {
                statusBox
            }
            .buttonStyle(.plain)
            .disabled(panes.isEmpty)
        }
    }

    private var statusBox: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.title3)
            Text(String(panes.count))
                .font(.headline.monospacedDigit().weight(.bold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            isSelected ? tint.opacity(0.19) : Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(isSelected ? 0.9 : 0.35), lineWidth: isSelected ? 2 : 1)
        }
    }

    private var isSelected: Bool {
        model.state.selectedPane.map { PaneStatus(agentStatus: $0.status) == status } ?? false
    }

    private var symbolName: String {
        switch status {
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath.circle.fill"
        case .idle: "pause.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var statusName: String {
        switch status {
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    private var tint: Color {
        switch status {
        case .blocked: Color(red: 1, green: 0.33, blue: 0.40)
        case .done: Color(red: 0.22, green: 0.84, blue: 0.54)
        case .working: Color(red: 0.96, green: 0.72, blue: 0.25)
        case .idle: Color(red: 0.38, green: 0.72, blue: 0.53)
        case .unknown: .gray
        }
    }
}

private func abbreviatedHomePath(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2,
          components[0].lowercased() == "users"
    else { return path }
    let remainder = components.dropFirst(2).joined(separator: "/")
    return remainder.isEmpty ? "~" : "~/\(remainder)"
}

private struct PaneSelectionPopover: View {
    let panes: [AgentPane]
    let select: (AgentPane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(panes) { pane in
                    Button {
                        select(pane)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pane.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.white)
                            if !pane.cwd.isEmpty {
                                Text(abbreviatedHomePath(pane.cwd))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if pane.id != panes.last?.id {
                        Divider().overlay(.white.opacity(0.12))
                    }
                }
            }
        }
        .frame(width: 280)
        .background(.black.opacity(0.94))
        .preferredColorScheme(.dark)
    }
}
