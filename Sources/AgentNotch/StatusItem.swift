import AgentNotchCore
import AppKit
import SwiftUI

/// Time-driven state of the bar item: the finish check expires with time, not with a store change.
@MainActor
@Observable
final class StatusItemState {
    var finishFlash = false
}

/// D20: the bot, then the notch's collapsed sides stacked beside it, showing only what is live:
/// working dots and count, then the needs-you count or a check for a turn that just finished. One
/// live row sits centred next to the bot; idle shows the bot alone. The bot turns orange on waiting.
struct StatusItemView: View {
    let store: SessionStore
    let state: StatusItemState
    /// The view's natural width. A hosted subview does not size its status bar button, so the
    /// controller sets the item's length from this; without it the counts were clipped away.
    var onWidth: @MainActor (CGFloat) -> Void = { _ in }

    var body: some View {
        let working = store.workingCount
        let waiting = store.waitingCount
        HStack(spacing: 4) {
            BotGlyph(waiting: waiting > 0)
                .frame(width: 17, height: 17)
                .foregroundStyle(waiting > 0 ? Palette.needsYou : Color.primary)
            if working > 0 || waiting > 0 || state.finishFlash {
                VStack(alignment: .leading, spacing: 0) {
                    if working > 0 {
                        row(WorkingDots(size: 2.6), count(working, color: .primary))
                    }
                    if waiting > 0 {
                        row(Circle().fill(Palette.needsYou).frame(width: 5, height: 5), count(waiting, color: Palette.needsYou))
                    } else if state.finishFlash {
                        row(Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.finished), EmptyView())
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { ceil($0.size.width) } action: { onWidth($0) }
    }

    /// The mark sits in a fixed column so the counts line up across both rows.
    private func row(_ mark: some View, _ value: some View) -> some View {
        HStack(spacing: 3) {
            mark.frame(width: 11)
            value
        }
    }

    private func count(_ n: Int, color: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
    }
}

/// Transient dropdown state. A class, not `@State`: the CLT has no SwiftUI macro plugin (V1).
@MainActor
@Observable
final class PopoverState {
    var message: String?
    /// The rows render only while the dropdown is open: a closed popover keeps its view tree, and
    /// its timelines would otherwise keep ticking.
    var isShown = false
    let list = ListUIState()
}

/// D21: the dropdown shows the same rows plus the controls, on the system popover material.
struct PopoverView: View {
    let store: SessionStore
    let settings: Settings
    let popoverState: PopoverState

    private func binding(_ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandHeader(store: store)
            if popoverState.isShown {
                SessionListView(store: store, settings: settings, ui: popoverState.list) { popoverState.message = $0 }
            }
            if let message = popoverState.message {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            VStack(spacing: 0) {
                settingRow("eye.slash", "Hide details", isOn: binding(\.hideDetails))
                Divider().padding(.leading, 36)
                settingRow("rectangle.topthird.inset.filled", "Pop open automatically", isOn: binding(\.autoOpen))
                Divider().padding(.leading, 36)
                settingRow("arrow.triangle.branch", "Show subagents in live view", isOn: binding(\.showSubagentsLive))
                Divider().padding(.leading, 36)
                settingRow("power", "Launch at login", isOn: binding(\.launchAtLogin))
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            if let error = settings.loginItemError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            HStack {
                Text(store.versionNote ?? "Tested with Claude Code \(SessionStore.defaultTestedVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(store.versionNote == nil ? Color.secondary : Color.orange)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "xmark.circle").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 440)
    }

    private func settingRow(_ symbol: String, _ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
    }
}

/// Lets clicks fall through to the status bar button underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let popoverState = PopoverState()
    private let store: SessionStore
    private let state: StatusItemState
    private var ticker: Task<Void, Never>?
    /// The view in the bar; `--demo menubar` renders it for captures.
    let view: StatusItemView

    init(store: SessionStore, settings: Settings) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let state = StatusItemState()
        self.item = item
        self.store = store
        self.state = state
        view = StatusItemView(store: store, state: state) { width in
            if item.length != width { item.length = width }
        }
        super.init()
        // The finish check expires with time, not with a store change; same cadence as the notch.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFlash()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let hosting = PassthroughHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let button = item.button {
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: button.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "AgentNotch"
        }
        let controller = NSHostingController(rootView: PopoverView(store: store, settings: settings, popoverState: popoverState))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    /// The item's button, for `--demo menubar` captures.
    var button: NSStatusBarButton? { item.button }

    /// Write only on change: every @Observable write re-renders, and this runs twice a second.
    private func refreshFlash() {
        let flash = store.anyJustFinished(now: Date())
        if state.finishFlash != flash { state.finishFlash = flash }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverState.isShown = true
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverState.isShown = false
        popoverState.message = nil
        popoverState.list.reset()
    }
}
