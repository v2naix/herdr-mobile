import SwiftUI

struct PaneSupervisionView: View {
    @ObservedObject var model: AppModel
    let pane: AgentPane

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var isUserScrolling = false

    var body: some View {
        readerCard
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
            .sensoryFeedback(.impact(weight: .light), trigger: model.state.successFeedbackCount)
            .sensoryFeedback(.warning, trigger: model.state.warningFeedbackCount)
            .sheet(
                isPresented: Binding(
                    get: { model.state.isReplyEditorPresented },
                    set: { if !$0 { model.dismissReplyEditor() } }
                )
            ) {
                ReplyEditor(model: model)
                    .presentationDetents([.height(260)])
                    .presentationDragIndicator(.visible)
            }
            .task(id: pane.id) {
                await model.openPane(pane)
            }
            .onDisappear {
                model.closePane()
            }
#if os(iOS)
            .navigationBarBackButtonHidden(model.state.command?.status == .pending)
#endif
    }

    private var readerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            Divider().overlay(.white.opacity(0.15))
            ScrollView(.vertical) {
                output
                    .padding(16)
                Color.clear
                    .frame(height: 1)
                    .id("output-bottom")
            }
            .scrollPosition($scrollPosition)
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
            .onChange(of: model.state.readerMode) {
                if model.state.readerMode == .following {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .background(Color(red: 0.04, green: 0.07, blue: 0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottomTrailing) {
            if model.state.readerMode == .readingHistory {
                Button(action: returnToBottom) {
                    Image(systemName: "arrow.down.to.line")
                        .frame(minWidth: 54, minHeight: 44)
                        .overlay(alignment: .topTrailing) {
                            if model.state.hasPendingOutput {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 9, height: 9)
                                    .offset(x: -7, y: 7)
                            }
                        }
                }
                .buttonStyle(.bordered)
                .tint(model.state.hasPendingOutput ? .blue : .white.opacity(0.45))
                .padding()
                .accessibilityLabel(
                    model.state.hasPendingOutput ? "有新输出，返回底部" : "返回底部"
                )
                .accessibilityIdentifier("return-to-bottom")
            }
        }
        .padding(.horizontal, 12)
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(pane.title)
                .font(.headline.monospaced())
                .lineLimit(1)
            Spacer()
            Button {
                model.setReaderWidth(model.state.readerWidth == .wrapped ? .original : .wrapped)
            } label: {
                Image(systemName: model.state.readerWidth == .wrapped
                    ? "arrow.left.and.right"
                    : "text.word.spacing")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(model.state.readerWidth == .wrapped ? "原始宽度" : "自动换行")
        }
        .accessibilityLabel("当前 pane：\(pane.status)，\(pane.title)\(pane.cwd.isEmpty ? "" : "，\(pane.cwd)")")
        .accessibilityIdentifier("current-pane-title")
    }

    private var statusSymbol: String {
        switch PaneStatus(agentStatus: pane.status) {
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath.circle.fill"
        case .idle: "pause.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch PaneStatus(agentStatus: pane.status) {
        case .blocked: Color(red: 1, green: 0.33, blue: 0.40)
        case .done: Color(red: 0.22, green: 0.84, blue: 0.54)
        case .working: Color(red: 0.96, green: 0.72, blue: 0.25)
        case .idle: Color(red: 0.38, green: 0.72, blue: 0.53)
        case .unknown: .gray
        }
    }

    @ViewBuilder
    private var output: some View {
        let text = model.state.outputText.isEmpty ? "正在等待输出…" : model.state.outputText
        if model.state.readerWidth == .wrapped {
            Text(text)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Color(red: 0.76, green: 0.94, blue: 0.84))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color(red: 0.76, green: 0.94, blue: 0.84))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var commandDeck: some View {
        VStack(spacing: 8) {
            if let command = model.state.command {
                commandStatus(command)
                    .padding(.horizontal, 12)
            }

            HStack(spacing: 7) {
                commandKey("Ctrl+C", command: .controlC, tint: .red)
                commandKey("↑", command: .up, tint: .gray)
                commandKey("↓", command: .down, tint: .gray)
                commandKey("y", command: .yes, tint: .green)
                commandKey("n", command: .no, tint: .red)
                commandKey("Tab", command: .tab, tint: .gray)
                Spacer(minLength: 0)
                Button("回复") { model.presentReplyEditor() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.16, green: 0.41, blue: 0.74))
                    .disabled(!canSendCommand)
                    .accessibilityIdentifier("reply")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)

            HStack(spacing: 7) {
                commandKey("Esc", command: .escape, tint: .orange)
                commandButton("批准", command: .allowOnce)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .accessibilityIdentifier("approve")
                commandButton("拒绝", command: .deny, role: .destructive)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("deny")
                Menu {
                    commandButton("←", command: .left)
                    commandButton("→", command: .right)
                    Divider()
                    commandButton("Ctrl+L", command: .controlL)
                    commandButton("Ctrl+P", command: .controlP)
                    commandButton("Ctrl+O", command: .controlO)
                } label: {
                    Label("更多", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .disabled(!canSendCommand)
                .accessibilityIdentifier("more-commands")
                commandKey("/", command: .slash, tint: .gray)
                commandKey("Enter", command: .enter, tint: .blue)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
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

    private func commandKey(_ title: String, command: QuickCommand, tint: Color) -> some View {
        commandButton(title, command: command)
            .buttonStyle(.bordered)
            .tint(tint)
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
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(
                get: { model.state.replyDraft },
                set: { model.updateReplyDraft($0) }
            ))
            .font(.body)
            .focused($isEditorFocused)
            .disabled(replyIsLocked)
            .frame(minHeight: 118)
            .padding(10)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            commandFeedback

            HStack {
                Button("关闭") { model.dismissReplyEditor() }
                Spacer()
                Button("发送") {
                    Task { await model.sendReply() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendReply)
            }
        }
        .padding(16)
        .task {
            isEditorFocused = true
        }
    }

    @ViewBuilder
    private var commandFeedback: some View {
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
                Text("命令失败，草稿已保留。")
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

    private var canSendReply: Bool {
        model.state.connection == .online
            && !model.state.selectedPaneIsStale
            && !replyIsLocked
    }

    private var replyIsLocked: Bool {
        model.state.command?.status == .pending
            || model.state.command?.status == .outcomeUnknown
    }
}
