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
            Button(confirmationButtonTitle, role: .destructive) {
                Task { await model.confirmDestructiveAction() }
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
                        set: model.updateOrigin
                    )
                )

                SecureField(
                    "Bootstrap token",
                    text: Binding(
                        get: { model.state.token },
                        set: model.updateToken
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
        List {
            Section {
                Label(connectionLabel, systemImage: connectionSymbol)
                    .foregroundStyle(connectionColor)
                if let error = model.state.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if canRetryConnection {
                    Button("立即重试") { model.retryNow() }
                }
            }

            Section("Agent panes") {
                ForEach(model.state.panes) { pane in
                    NavigationLink(value: pane) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(pane.title)
                                    .font(.headline)
                                Spacer()
                                Text(pane.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !pane.cwd.isEmpty {
                                Text(pane.cwd)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !pane.workspaceID.isEmpty {
                                Text("Workspace \(pane.workspaceID)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.state.panes.isEmpty && model.state.connection == .online {
                ContentUnavailableView("没有 Agent pane", systemImage: "rectangle.stack")
            }
        }
        .navigationTitle("Herdr Mobile")
        .navigationDestination(for: AgentPane.self) { pane in
            PaneDetailView(model: model, pane: pane)
        }
        .toolbar {
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

private struct PaneDetailView: View {
    @ObservedObject var model: AppModel
    let pane: AgentPane

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var isUserScrolling = false

    var body: some View {
        ScrollView(.vertical) {
            output
                .padding()
            Color.clear
                .frame(height: 1)
                .id("output-bottom")
        }
        .scrollPosition($scrollPosition)
        .background(Color.black.opacity(0.92))
        .foregroundStyle(.white)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
            return contentBottom - visibleBottom < 28
        } action: { _, nearBottom in
            isNearBottom = nearBottom
            if isUserScrolling && !nearBottom {
                model.userScrolledAwayFromBottom()
            }
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .interacting || phase == .decelerating
            if phase == .interacting && !isNearBottom {
                model.userScrolledAwayFromBottom()
            } else if phase == .idle,
                      isNearBottom,
                      model.state.readerMode == .readingHistory {
                returnToBottom()
            }
        }
        .onChange(of: model.state.outputText) {
            if model.state.readerMode == .following {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.state.readerMode == .readingHistory {
                Button(action: returnToBottom) {
                    Label(
                        model.state.hasPendingOutput ? "有新输出 · 返回底部" : "返回底部",
                        systemImage: "arrow.down.to.line"
                    )
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityIdentifier("return-to-bottom")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.state.selectedPaneIsStale || model.state.connection != .online {
                Label(
                    model.state.selectedPaneIsStale
                        ? "此 pane 信息尚未重新验证，内容为旧快照，操作已禁用。"
                        : "控制连接尚未同步，Agent 可能仍在运行。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commandDeck
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.setReaderWidth(model.state.readerWidth == .wrapped ? .original : .wrapped)
                } label: {
                    Label(
                        model.state.readerWidth == .wrapped ? "原始宽度" : "自动换行",
                        systemImage: model.state.readerWidth == .wrapped ? "arrow.left.and.right" : "text.word.spacing"
                    )
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.state.successFeedbackCount)
        .sensoryFeedback(.warning, trigger: model.state.warningFeedbackCount)
        .sheet(
            isPresented: Binding(
                get: { model.state.isReplyEditorPresented },
                set: { if !$0 { model.dismissReplyEditor() } }
            )
        ) {
            ReplyEditor(model: model, paneTitle: pane.title)
                .presentationDetents([.large])
        }
        .task(id: pane.id) {
            await model.openPane(pane)
        }
        .onDisappear {
            model.closePane()
        }
        .navigationTitle(pane.title)
#if os(iOS)
        .navigationBarBackButtonHidden(model.state.command?.status == .pending)
#endif
    }

    @ViewBuilder
    private var output: some View {
        let text = model.state.outputText.isEmpty ? "正在等待输出…" : model.state.outputText
        if model.state.readerWidth == .wrapped {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var commandDeck: some View {
        VStack(spacing: 8) {
            Group {
                if let command = model.state.command {
                    commandStatus(command)
                } else {
                    Color.clear
                }
            }
            .frame(height: 40)
            .padding(.horizontal)

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Reply") { model.presentReplyEditor() }
                            .buttonStyle(.borderedProminent)
                        commandButton("Enter", command: .enter)
                        commandButton("Esc", command: .escape)
                        commandButton("y", command: .yes)
                        commandButton("n", command: .no)
                        commandButton("Allow once", command: .allowOnce)
                        commandButton("Deny", command: .deny, role: .destructive)
                    }
                    .padding(.horizontal)
                }

                Menu {
                    commandButton("Tab", command: .tab)
                    commandButton("↑", command: .up)
                    commandButton("↓", command: .down)
                    commandButton("←", command: .left)
                    commandButton("→", command: .right)
                    Divider()
                    commandButton("Ctrl+C", command: .controlC)
                    commandButton("Ctrl+L", command: .controlL)
                    commandButton("Ctrl+P", command: .controlP)
                    commandButton("Ctrl+O", command: .controlO)
                } label: {
                    Label("更多按键", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canSendCommand)
                .padding(.trailing)
            }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func commandStatus(_ command: CommandViewState) -> some View {
        HStack(spacing: 8) {
            switch command.status {
            case .pending:
                ProgressView()
                Text(command.message ?? "等待服务器确认…")
            case .acknowledged:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(command.message ?? "已确认")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(command.message ?? "命令失败")
            case .outcomeUnknown:
                Image(systemName: "questionmark.diamond.fill")
                    .foregroundStyle(.orange)
                Text(command.message ?? "结果未知：命令可能已经执行。")
                Spacer()
                if command.canRetry {
                    Button("明确重试") {
                        Task { await model.retryCommand() }
                    }
                    .disabled(model.state.connection != .online || model.state.selectedPaneIsStale)
                }
            }
        }
        .font(.footnote)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("command-status")
    }

    private func commandButton(
        _ title: String,
        command: QuickCommand,
        role: ButtonRole? = nil
    ) -> some View {
        Button(title, role: role) {
            Task { await model.sendQuickCommand(command) }
        }
        .disabled(!canSendCommand)
    }

    private var canSendCommand: Bool {
        model.state.connection == .online
            && !model.state.selectedPaneIsStale
            && model.state.command?.status != .pending
            && model.state.command?.status != .outcomeUnknown
    }

    private func returnToBottom() {
        model.returnToBottom()
        scrollPosition.scrollTo(edge: .bottom)
    }
}

private struct ReplyEditor: View {
    @ObservedObject var model: AppModel
    let paneTitle: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(
                    get: { model.state.replyDraft },
                    set: model.updateReplyDraft
                ))
                .font(.body)
                .disabled(replyIsLocked)

                if let error = model.state.replyError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let command = model.state.command {
                    switch command.status {
                    case .pending:
                        HStack {
                            ProgressView()
                            Text(command.message ?? "等待服务器确认…")
                        }
                        .font(.footnote)
                    case .failed:
                        Text(command.message ?? "命令失败，草稿已保留。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    case .outcomeUnknown:
                        HStack {
                            Text(command.message ?? "结果未知，草稿已保留。")
                            Spacer()
                            Button("明确重试") {
                                Task { await model.retryCommand() }
                            }
                            .disabled(model.state.connection != .online || model.state.selectedPaneIsStale)
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    case .acknowledged:
                        EmptyView()
                    }
                }
            }
            .padding()
            .navigationTitle("回复 \(paneTitle)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { model.dismissReplyEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        Task { await model.sendReply() }
                    }
                    .disabled(
                        model.state.connection != .online
                        || model.state.selectedPaneIsStale
                        || model.state.command?.status == .pending
                        || model.state.command?.status == .outcomeUnknown
                    )
                }
            }
        }
    }

    private var replyIsLocked: Bool {
        model.state.command?.status == .pending
            || model.state.command?.status == .outcomeUnknown
    }
}
