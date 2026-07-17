// PROTOTYPE — throw this away after resolving the terminal-reading interaction.
// Three variants of the iPhone pane-detail reader, switchable from a floating bar.

import SwiftUI

@main
struct TerminalReaderPrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            PrototypeRoot()
                .preferredColorScheme(.dark)
        }
    }
}

private struct OutputLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

private enum ReaderVariant: Int, CaseIterable {
    case immersive, console, focus

    var name: String {
        switch self {
        case .immersive: "A — Immersive reader"
        case .console: "B — Console deck"
        case .focus: "C — Focus mode"
        }
    }
}

private struct PrototypeRoot: View {
    @AppStorage("prototypeVariant") private var variantRaw = 0
    @State private var lines = Self.seed
    @State private var feedRunning = true
    @State private var wraps = true
    @State private var draft = ""

    private var variant: ReaderVariant {
        ReaderVariant(rawValue: variantRaw) ?? .immersive
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch variant {
                case .immersive:
                    ImmersiveReader(lines: lines, wraps: $wraps, draft: $draft)
                case .console:
                    ConsoleDeck(lines: lines, wraps: $wraps, draft: $draft)
                case .focus:
                    FocusReader(lines: lines, wraps: $wraps, draft: $draft)
                }
            }
            .safeAreaInset(edge: .top) {
                PrototypeFeedBar(feedRunning: $feedRunning) {
                    appendBurst()
                }
            }

            VariantSwitcher(variantRaw: $variantRaw)
                .padding(.bottom, 8)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                if feedRunning { appendLine() }
            }
        }
    }

    private func appendLine() {
        let id = (lines.last?.id ?? 0) + 1
        let messages = [
            "Thinking through the next dependency…",
            "Read server/protocol.py and compared the command boundaries.",
            "The pane is still working; no response is required yet.",
            "A deliberately long line follows: /Users/example/repos/herdr-mobile/server/adapter/with/a/very/long/path/that/tests/the-original-line-width-reading-mode.swift",
            "✓ Check completed without changing production files.",
            "Waiting for approval before continuing."
        ]
        lines.append(OutputLine(id: id, text: "\(time())  \(messages[id % messages.count])"))
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }

    private func appendBurst() {
        for _ in 0..<12 { appendLine() }
    }

    private func time() -> String {
        Date.now.formatted(date: .omitted, time: .standard)
    }

    private static let seed: [OutputLine] = (1...80).map { index in
        OutputLine(
            id: index,
            text: String(format: "%03d", index) + "  " + (index.isMultiple(of: 9)
                ? "A long command output line with columns: pane=research status=working cwd=/Users/example/repos/a/deep/project/path tokens=48210 elapsed=00:18:42"
                : "Agent output line \(index): inspecting the current decision and its constraints.")
        )
    }
}

private struct TerminalViewport: View {
    let lines: [OutputLine]
    let wraps: Bool
    let chrome: Color

    @State private var position = ScrollPosition(idType: Int.self)
    @State private var following = true
    @State private var nearBottom = true
    @State private var userInteracting = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(wraps ? .vertical : [.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: !wraps, vertical: true)
                            .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                userInteracting = phase == .interacting
                if phase == .idle && nearBottom { following = true }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                    + geometry.contentInsets.bottom
                return distance < 36
            } action: { _, isNearBottom in
                nearBottom = isNearBottom
                if userInteracting && !isNearBottom { following = false }
            }
            .onAppear { scrollToBottom() }
            .onChange(of: lines.last?.id) {
                if following { scrollToBottom() }
            }
            .background(chrome)

            if !following {
                Button {
                    following = true
                    scrollToBottom()
                } label: {
                    Label("回到底部", systemImage: "arrow.down")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .padding(12)
            }
        }
        .accessibilityLabel("模拟 pane 输出")
    }

    private func scrollToBottom() {
        guard let last = lines.last else { return }
        Task { @MainActor in
            await Task.yield()
            position.scrollTo(id: last.id, anchor: .bottom)
        }
    }
}

// Variant A: reading owns the screen; input is a compact bottom inset.
private struct ImmersiveReader: View {
    let lines: [OutputLine]
    @Binding var wraps: Bool
    @Binding var draft: String

    var body: some View {
        NavigationStack {
            TerminalViewport(lines: lines, wraps: wraps, chrome: Color.black)
                .navigationTitle("Migration map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(wraps ? "换行" : "原宽") { wraps.toggle() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    CompactComposer(draft: $draft)
                }
        }
    }
}

// Variant B: output and a persistent command deck are equal citizens.
private struct ConsoleDeck: View {
    let lines: [OutputLine]
    @Binding var wraps: Bool
    @Binding var draft: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Migration map").font(.headline)
                    Text("WORKING · ~/repos/herdr-mobile").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("换行", isOn: $wraps).labelsHidden()
            }
            .padding()

            TerminalViewport(lines: lines, wraps: wraps, chrome: Color(red: 0.02, green: 0.03, blue: 0.04))
                .clipShape(.rect(cornerRadius: 14))
                .padding(.horizontal, 10)

            VStack(spacing: 10) {
                HStack {
                    Button("Approve once") { }
                    Button("Deny", role: .destructive) { }
                    Spacer()
                    Button("Esc") { }
                    Button("↵") { }
                }
                HStack {
                    TextField("回复 agent", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") { draft = "" }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}

// Variant C: uninterrupted reading; commands appear only when requested.
private struct FocusReader: View {
    let lines: [OutputLine]
    @Binding var wraps: Bool
    @Binding var draft: String
    @State private var composing = false

    var body: some View {
        TerminalViewport(lines: lines, wraps: wraps, chrome: Color.black)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                HStack {
                    Label("Migration map", systemImage: "terminal")
                    Spacer()
                    Button(wraps ? "Wrap" : "Width") { wraps.toggle() }
                    Button("Reply") { composing = true }
                }
                .font(.caption.bold())
                .padding(10)
                .background(.ultraThinMaterial, in: .capsule)
                .padding()
            }
            .sheet(isPresented: $composing) {
                NavigationStack {
                    VStack {
                        TextField("回复 agent", text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Esc") { }
                            Button("Approve once") { }
                            Spacer()
                            Button("发送") { draft = ""; composing = false }
                                .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Reply")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(220), .medium])
            }
    }
}

private struct CompactComposer: View {
    @Binding var draft: String

    var body: some View {
        HStack {
            TextField("回复 agent", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button("发送") { draft = "" }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .padding(.bottom, 46) // Space for the prototype-only variant switcher.
        .background(.regularMaterial)
    }
}

private struct PrototypeFeedBar: View {
    @Binding var feedRunning: Bool
    let burst: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("PROTOTYPE").font(.caption2.bold()).foregroundStyle(.yellow)
            Button(feedRunning ? "暂停输出" : "继续输出") { feedRunning.toggle() }
            Button("+12 行", action: burst)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.88))
    }
}

private struct VariantSwitcher: View {
    @Binding var variantRaw: Int

    private var variant: ReaderVariant {
        ReaderVariant(rawValue: variantRaw) ?? .immersive
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
            Text(variant.name).font(.caption.bold()).frame(minWidth: 150)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().stroke(.yellow.opacity(0.7)))
        .shadow(radius: 8)
    }

    private func move(_ delta: Int) {
        let count = ReaderVariant.allCases.count
        variantRaw = (variant.rawValue + delta + count) % count
    }
}
