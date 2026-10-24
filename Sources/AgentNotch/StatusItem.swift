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
        popover.animates = true
        popover.delegate = self
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
