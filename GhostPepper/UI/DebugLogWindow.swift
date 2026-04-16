import SwiftUI
import AppKit

final class DebugLogWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private weak var debugLogStore: DebugLogStore?
    private var isLiveViewing = false

    func show(debugLogStore: DebugLogStore) {
        if let window = window {
            self.debugLogStore = debugLogStore
            beginLiveViewingIfNeeded()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Debug Log"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentViewController = NSHostingController(
            rootView: DebugLogWindowView(debugLogStore: debugLogStore)
        )
        self.debugLogStore = debugLogStore
        beginLiveViewingIfNeeded()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endLiveViewingIfNeeded()
        sender.orderOut(nil)
        return false
    }

    private func beginLiveViewingIfNeeded() {
        guard !isLiveViewing else {
            return
        }

        debugLogStore?.beginLiveViewing()
        isLiveViewing = true
    }

    private func endLiveViewingIfNeeded() {
        guard isLiveViewing else {
            return
        }

        debugLogStore?.endLiveViewing()
        isLiveViewing = false
    }

    func shutdown() {
        endLiveViewingIfNeeded()
        guard let window else { return }

        window.delegate = nil
        window.contentViewController = nil
        window.orderOut(nil)
        self.window = nil
        debugLogStore = nil
    }
}

private struct DebugLogWindowView: View {
    @ObservedObject var debugLogStore: DebugLogStore
    @State private var shouldFollowTail = true

    private let bottomAnchorID = "debug-log-bottom"
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Copy Log") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(debugLogStore.formattedText, forType: .string)
                }
                .disabled(debugLogStore.entries.isEmpty)

                Button("Clear") {
                    debugLogStore.clear()
                }
                .disabled(debugLogStore.entries.isEmpty)

                Spacer()
            }

            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if debugLogStore.entries.isEmpty {
                                Text("No debug events yet.")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                ForEach(debugLogStore.entries) { entry in
                                    Text(formattedText(for: entry))
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(entry.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: DebugLogBottomOffsetPreferenceKey.self,
                                            value: geometry.frame(in: .named("debug-log-scroll")).maxY
                                        )
                                    }
                                )
                        }
                    }
                    .coordinateSpace(name: "debug-log-scroll")
                    .onAppear {
                        scrollToBottom(with: proxy)
                    }
                    .onChange(of: debugLogStore.entries.count) { _, _ in
                        guard shouldFollowTail else {
                            return
                        }
                        scrollToBottom(with: proxy)
                    }
                    .onPreferenceChange(DebugLogBottomOffsetPreferenceKey.self) { bottomOffset in
                        shouldFollowTail = bottomOffset - outer.size.height <= 32
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }

    private func formattedText(for entry: DebugLogEntry) -> String {
        "[\(formattedTime(for: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
    }

    private func formattedTime(for timestamp: Date) -> String {
        Self.timeFormatter.string(from: timestamp)
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct DebugLogBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
