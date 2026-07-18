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
    }

    private var connectionLabel: String {
        switch model.state.connection {
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .online: "在线"
        case .offline: "连接已断开"
        case .incompatibleProtocol: "协议不兼容"
        case .failed: "连接失败"
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
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Reply") { model.presentReplyEditor() }
                        .buttonStyle(.borderedProminent)
                    commandButton("Enter")
                    commandButton("Esc")
                    commandButton("y")
                    commandButton("n")
                    commandButton("Allow once")
                    commandButton("Deny", role: .destructive)
                }
                .padding(.horizontal)
            }

            Menu {
                commandButton("Tab")
                commandButton("↑")
                commandButton("↓")
                commandButton("←")
                commandButton("→")
                Divider()
                commandButton("Ctrl+C")
                commandButton("Ctrl+L")
                commandButton("Ctrl+P")
                commandButton("Ctrl+O")
            } label: {
                Label("更多按键", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .padding(.trailing)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func commandButton(_ title: String, role: ButtonRole? = nil) -> some View {
        Button(title, role: role) {}
            .disabled(true)
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
            TextEditor(text: Binding(
                get: { model.state.replyDraft },
                set: model.updateReplyDraft
            ))
            .font(.body)
            .padding()
            .navigationTitle("回复 \(paneTitle)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { model.dismissReplyEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {}
                        .disabled(true)
                }
            }
        }
    }
}
