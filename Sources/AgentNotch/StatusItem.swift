import AgentNotchCore
import AppKit
import SwiftUI

/// D20: icon + two stacked counts (working over waiting), orange when waiting > 0.
struct StatusItemView: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 3) {
            BotGlyph(waiting: store.waitingCount > 0)
                .frame(width: 17, height: 17)
                .foregroundStyle(store.waitingCount > 0 ? Color.orange : Color.primary)
            VStack(spacing: -1) {
                Text("\(store.workingCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                Text("\(store.waitingCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(store.waitingCount > 0 ? Color.orange : Color.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }
}

/// Transient dropdown state. A class, not `@State`: the CLT has no SwiftUI macro plugin (V1).
@MainActor
@Observable
final class PopoverState {
    var message: String?
}

/// D21: the dropdown shows the same rows plus the controls.
struct PopoverView: View {
    let store: SessionStore
    let settings: Settings
    let popoverState: PopoverState

    private var hideDetails: Binding<Bool> {
        Binding(get: { settings.hideDetails }, set: { settings.hideDetails = $0 })
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionListView(store: store, settings: settings) { popoverState.message = $0 }
            if let message = popoverState.message {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            Toggle("Hide details", isOn: hideDetails)
            Toggle("Launch at login", isOn: launchAtLogin)
            if let error = settings.loginItemError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            Text(store.versionNote ?? "Tested with Claude Code \(SessionStore.defaultTestedVersion)")
                .font(.system(size: 10))
                .foregroundStyle(store.versionNote == nil ? Color.secondary : Color.orange)
            Button("Quit AgentNotch") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
        .frame(width: 400)
    }
}

/// Lets clicks fall through to the status bar button underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverState = PopoverState()

    init(store: SessionStore, settings: Settings) {
        super.init()
        let hosting = PassthroughHostingView(rootView: StatusItemView(store: store))
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
        popover.animates = false
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            popoverState.message = nil
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
