import SwiftUI

// THROWAWAY UI PROTOTYPE — three pane-list, reader, and command-control architectures.
// Switch with the floating control below. This branch never sends commands or reads credentials.
struct MobileUIPrototypeRootView: View {
    @State private var variant = 0

    private let variants = ["A · 控制台", "B · 收件箱", "C · 指挥台"]

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch variant {
                case 0: TerminalFirstPrototype()
                case 1: InboxPrototype()
                default: CommandBoardPrototype()
                }
            }

            HStack(spacing: 16) {
                Button {
                    variant = (variant + variants.count - 1) % variants.count
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("上一个方案")

                Text(variants[variant])
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 112)

                Button {
                    variant = (variant + 1) % variants.count
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("下一个方案")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.88), in: Capsule())
            .foregroundStyle(.white)
            .shadow(radius: 14, y: 6)
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
    }
}

private enum PaneStatus: String, CaseIterable, Hashable {
    case blocked, done, working, idle

    var title: String {
        switch self {
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    // Tuned for the black console: high contrast without neon glare.
    var color: Color {
        switch self {
        case .blocked: Color(red: 1, green: 0.33, blue: 0.40) // warm red
        case .done: Color(red: 0.22, green: 0.84, blue: 0.54) // vivid green
        case .working: Color(red: 0.96, green: 0.72, blue: 0.25) // warm yellow
        case .idle: Color(red: 0.38, green: 0.72, blue: 0.53) // quieter green
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath.circle.fill"
        case .idle: "pause.circle.fill"
        }
    }
}

private struct DemoPane: Identifiable, Hashable {
    let title: String
    let detail: String
    let status: PaneStatus
    var id: String { title }
    var color: Color { status.color }

    static let all = [
        DemoPane(title: "release-check", detail: "等待验收结果", status: .blocked),
        DemoPane(title: "changelog", detail: "已整理完变更", status: .done),
        DemoPane(title: "herdr-mobile", detail: "实现 reader 交互", status: .working),
        DemoPane(title: "docs", detail: "等待下一项工作", status: .idle),
        DemoPane(title: "connection", detail: "正在恢复订阅", status: .working),
        DemoPane(title: "test-suite", detail: "等待执行", status: .idle),
    ]
}

private let demoOutput = """
› Reviewing the reader interaction model

  The draft is retained when a command fails.
  I have kept the scroll position frozen while
  you read prior output.

› What would you like to change next?

  • Add an explicit retry affordance
  • Keep controls close to the latest output

Waiting for your reply…
"""

private struct PrototypeNotice: View {
    var body: some View {
        Label("仅供比较的只读界面原型", systemImage: "flask")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// A: terminal is the product. Four visible status inboxes select its context; commands hug its output.
private struct TerminalFirstPrototype: View {
    @State private var selected = DemoPane.all[2]
    @State private var commandNote: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HERDR")
                        .font(.caption.weight(.black))
                        .tracking(2)
                    Text("长按暂存箱切换任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("在线", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 9)

            HStack(spacing: 8) {
                ForEach(PaneStatus.allCases, id: \.self) { status in
                    statusInbox(status)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: selected.status.symbol)
                        .foregroundStyle(selected.color)
                    Text(selected.title)
                        .font(.headline.monospaced())
                        .lineLimit(1)
                    Text("· \(selected.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                Divider().overlay(.white.opacity(0.15))
                ScrollView {
                    Text(selectedOutput)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Color(red: 0.76, green: 0.94, blue: 0.84))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .background(Color(red: 0.04, green: 0.07, blue: 0.06), in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 12)

            VStack(spacing: 8) {
                if let commandNote {
                    Text(commandNote).font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button {
                        commandNote = "原型不会发送回复"
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.16, green: 0.41, blue: 0.74))

                    Button("批准") { commandNote = "“批准”仅为演示" }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("拒绝") { commandNote = "“拒绝”仅为演示" }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        commandKey("Enter", tint: .blue)
                        commandKey("Esc", tint: .orange)
                        commandKey("y", tint: .green)
                        commandKey("n", tint: .red)
                        Menu {
                            Button("Tab") { commandNote = "原型不会发送按键" }
                            Button("↑") { commandNote = "原型不会发送按键" }
                            Button("Ctrl+C") { commandNote = "原型不会发送按键" }
                        } label: {
                            Label("更多", systemImage: "keyboard")
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    }
                    .padding(.horizontal, 12)
                }
                PrototypeNotice()
            }
            .padding(.top, 10)
            .padding(.bottom, 64)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func commandKey(_ title: String, tint: Color) -> some View {
        Button(title) { commandNote = "“\(title)”仅为演示" }
            .buttonStyle(.bordered)
            .tint(tint)
    }

    private var selectedOutput: String {
        """
        › \(selected.title)

          状态: \(selected.status.title)
          \(selected.detail)

        › Agent 最新输出

        \(demoOutput)
        """
    }

    @ViewBuilder
    private func statusInbox(_ status: PaneStatus) -> some View {
        let panes = DemoPane.all.filter { $0.status == status }
        Button {
            if let first = panes.first { selected = first }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: status.symbol)
                    .font(.title3)
                Text("\(panes.count)")
                    .font(.headline.monospacedDigit().weight(.bold))
            }
            .foregroundStyle(status.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected.status == status ? status.color.opacity(0.19) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(status.color.opacity(selected.status == status ? 0.9 : 0.35), lineWidth: selected.status == status ? 2 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if panes.isEmpty {
                Text("没有任务")
            } else {
                ForEach(panes) { pane in
                    Button {
                        selected = pane
                    } label: {
                        Label(pane.title, systemImage: pane == selected ? "checkmark" : status.symbol)
                    }
                }
            }
        }
        .accessibilityLabel("\(status.title)，\(panes.count) 个任务")
        .accessibilityHint("轻点选择该状态的最新任务；长按选择其他任务")
    }
}

// B: panes are an inbox. The selected pane opens as a calm reading artifact with a composer-like action.
private struct InboxPrototype: View {
    @State private var selected = DemoPane.all[0]
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你的 Agent")
                            .font(.largeTitle.bold())
                        Text("从需要回应的工作开始")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "person.crop.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(DemoPane.all) { pane in
                        Button {
                            selected = pane
                        } label: {
                            HStack(spacing: 13) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(pane.color)
                                    .frame(width: 5, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pane.title).font(.headline)
                                    Text(pane.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if pane == selected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(pane.color)
                                }
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        if pane != DemoPane.all.last { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(selected.title).font(.headline)
                        Spacer()
                        Text("刚刚").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(demoOutput)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)

                    Divider()
                    TextField("给 Agent 留下回复…", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    HStack {
                        Button("稍后处理") { note = "" }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("发送回复") { note = "此原型不会发送内容" }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))

                PrototypeNotice()
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .padding(.bottom, 70)
        }
    }
}

// C: a command board. Pane selection lives in a persistent bottom dock; the primary decision dominates.
private struct CommandBoardPrototype: View {
    @State private var selected = DemoPane.all[0]
    @State private var action = "等待你的决定"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("指挥台").font(.title2.bold())
                Spacer()
                Label("同步", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 10) {
                Text("当前需要你决定").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("是否继续 reader 的原型方案？")
                    .font(.title3.bold())
                Text("\(selected.title) · Agent 正在等待输入")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("继续") { action = "已选择：继续（仅演示）" }
                        .buttonStyle(.borderedProminent)
                    Button("暂停") { action = "已选择：暂停（仅演示）" }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                Text(action).font(.caption).foregroundStyle(.orange)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 16)

            HStack {
                Text("活动记录").font(.headline)
                Spacer()
                Button("查看全部") {}.font(.caption)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(demoOutput.split(separator: "\n").filter { !$0.isEmpty }.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(index.isMultiple(of: 3) ? selected.color : .secondary.opacity(0.35)).frame(width: 8, height: 8).padding(.top, 5)
                            Text(String(line)).font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        if index < 5 { Divider().padding(.leading, 20) }
                    }
                }
                .padding(.horizontal, 20)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(DemoPane.all) { pane in
                        Button {
                            selected = pane
                            action = "等待你的决定"
                        } label: {
                            VStack(spacing: 4) {
                                Circle().fill(pane.color).frame(width: 9, height: 9)
                                Text(pane.title).lineLimit(1)
                            }
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(selected == pane ? pane.color.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                PrototypeNotice()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 68)
            .background(.bar)
        }
    }
}
