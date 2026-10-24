import AgentNotchCore
import AppKit
import SwiftUI

/// D14: geometry from public NSScreen APIs only.
enum NotchGeometry {
    static let sideWidth: CGFloat = 56
    static let pillSize = CGSize(width: 224, height: 38)
    static let expandedWidth: CGFloat = 440

    /// The physical notch, or nil on a screen without one.
    static func notchRect(on screen: NSScreen) -> CGRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let frame = screen.frame
        return CGRect(x: left.maxX, y: frame.maxY - inset, width: right.minX - left.maxX, height: inset)
    }

    static func pillRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.midX - pillSize.width / 2, y: frame.maxY - pillSize.height, width: pillSize.width, height: pillSize.height)
    }

    /// Collapsed overlay: the notch plus a side zone on each side (click-through), or the pill.
    static func collapsedFrame(on screen: NSScreen) -> CGRect {
        if let notch = notchRect(on: screen) { return notch.insetBy(dx: -sideWidth, dy: 0) }
        return pillRect(on: screen)
    }

    static let messageLineHeight: CGFloat = 16

    static func expandedFrame(on screen: NSScreen, rows: Int) -> CGRect {
        let top = notchRect(on: screen)?.height ?? 0
        let height = top + 12 + SessionListView.listHeight(rows: rows) + 6 + messageLineHeight + 12
        let centerX = notchRect(on: screen)?.midX ?? screen.frame.midX
        return CGRect(x: centerX - expandedWidth / 2, y: screen.frame.maxY - height, width: expandedWidth, height: height)
    }
}

@MainActor
@Observable
final class NotchState {
    enum Mode: Equatable { case collapsed, expanded, pulse(String) }
    var mode: Mode = .collapsed
    /// Row to outline while already expanded (a pulse that arrives mid-hover).
    var highlightId: String?
    var hasNotch = true
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var message: String?
}

struct NotchRootView: View {
    let state: NotchState
    let store: SessionStore
    let settings: Settings

    var body: some View {
        switch state.mode {
        case .collapsed:
            CollapsedNotchView(state: state, store: store)
        case .expanded:
            ExpandedNotchView(state: state, store: store, settings: settings, only: nil)
        case .pulse(let id):
            ExpandedNotchView(state: state, store: store, settings: settings, only: id)
        }
    }
}

/// Collapsed: working count left of the notch, orange dot right of it (D13, "Behaviour").
struct CollapsedNotchView: View {
    let state: NotchState
    let store: SessionStore

    var body: some View {
        if state.hasNotch {
            HStack(spacing: 0) {
                sideZone(alignment: .trailing) {
                    if store.workingCount > 0 {
                        Text("\(store.workingCount)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                Color.black.frame(width: state.notchWidth)
                sideZone(alignment: .leading) {
                    if store.waitingCount > 0 {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                    }
                }
            }
            .frame(height: state.notchHeight)
        } else {
            HStack(spacing: 8) {
                Text("\(store.workingCount) working").foregroundStyle(.white)
                Text("·").foregroundStyle(.gray)
                Text("\(store.waitingCount) waiting").foregroundStyle(store.waitingCount > 0 ? Color.orange : .gray)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .frame(width: NotchGeometry.pillSize.width, height: NotchGeometry.pillSize.height)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(Color.black))
        }
    }

    @ViewBuilder
    private func sideZone<Content: View>(alignment: Alignment, @ViewBuilder content: () -> Content) -> some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: alignment == .trailing ? 12 : 0,
            bottomTrailingRadius: alignment == .leading ? 12 : 0
        )
        ZStack(alignment: alignment) {
            Color.clear
            content()
                .padding(.horizontal, 8)
                .frame(height: state.notchHeight)
                .background(shape.fill(Color.black))
        }
        .frame(width: NotchGeometry.sideWidth, height: state.notchHeight)
    }
}

struct ExpandedNotchView: View {
    let state: NotchState
    let store: SessionStore
    let settings: Settings
    let only: String?

    var body: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: state.hasNotch ? state.notchHeight : 0)
            VStack(spacing: 6) {
                SessionListView(store: store, settings: settings, onlySessionId: only, highlightId: only ?? state.highlightId) { state.message = $0 }
                Text(state.message ?? (only == nil ? "hover away or press Esc to close" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: NotchGeometry.messageLineHeight)
            }
            .padding(12)
        }
        .frame(width: NotchGeometry.expandedWidth)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(Color.black))
        .environment(\.colorScheme, .dark)
    }
}

/// The notch overlay: an NSPanel that never takes key focus (D1, D13, D14).
@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private let state = NotchState()
    private let store: SessionStore
    private var monitors: [Any] = []
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?

    static let hoverDelay: Duration = .milliseconds(150)
    static let collapseDelay: Duration = .milliseconds(300)
    static let pulseDuration: Duration = .milliseconds(2500)

    init(store: SessionStore, settings: Settings) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchRootView(state: state, store: store, settings: settings))

        reposition()
        panel.orderFrontRegardless()
        observeRowCount()

        // NSEvent monitor handlers and `.main`-queue observers always run on the main thread, which
        // the SDK does not express in the closure types; `assumeIsolated` states that fact.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(m) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// Keep the expanded panel sized to the row count as sessions come and go.
    private func observeRowCount() {
        withObservationTracking {
            _ = store.sessions.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.mode == .expanded { self.applyFrame() }
                self.observeRowCount()
            }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first }   // the menu-bar screen (D14)

    /// The area that reacts to hover/click while collapsed: the notch itself, or the pill.
    private var hotRect: CGRect {
        guard let screen else { return .zero }
        return NotchGeometry.notchRect(on: screen) ?? NotchGeometry.pillRect(on: screen)
    }

    func reposition() {
        guard let screen else { return }
        let notch = NotchGeometry.notchRect(on: screen)
        state.hasNotch = notch != nil
        state.notchWidth = notch?.width ?? 0
        state.notchHeight = notch?.height ?? 0
        applyFrame()
    }

    private func applyFrame() {
        guard let screen else { return }
        let frame: CGRect
        switch state.mode {
        case .collapsed:
            frame = NotchGeometry.collapsedFrame(on: screen)
            panel.ignoresMouseEvents = true
        case .expanded:
            frame = NotchGeometry.expandedFrame(on: screen, rows: store.sessions.count)
            panel.ignoresMouseEvents = false
        case .pulse:
            frame = NotchGeometry.expandedFrame(on: screen, rows: 1)
            panel.ignoresMouseEvents = false
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Events

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53, state.mode != .collapsed { collapse() }   // Esc
            return
        }
        let location = NSEvent.mouseLocation
        switch state.mode {
        case .collapsed:
            let inside = hotRect.contains(location)
            if inside, event.type == .leftMouseDown { expand(); return }
            if inside { scheduleExpand() } else { cancelExpand() }
        case .expanded, .pulse:
            if panel.frame.contains(location) { cancelCollapse() } else { scheduleCollapse() }
        }
    }

    private func scheduleExpand() {
        guard expandTask == nil else { return }
        expandTask = Task { [weak self] in
            try? await Task.sleep(for: NotchPanelController.hoverDelay)
            guard !Task.isCancelled, let self else { return }
            self.expandTask = nil
            if self.hotRect.contains(NSEvent.mouseLocation) { self.expand() }
        }
    }

    private func cancelExpand() { expandTask?.cancel(); expandTask = nil }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: NotchPanelController.collapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            if case .pulse = self.state.mode { return }       // the pulse timer decides
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.collapse() }
        }
    }

    private func cancelCollapse() { collapseTask?.cancel(); collapseTask = nil }

    func expand() {
        cancelExpand()
        state.mode = .expanded
        applyFrame()
    }

    func collapse() {
        cancelExpand(); cancelCollapse()
        state.message = nil
        state.highlightId = nil
        state.mode = .collapsed
        applyFrame()
    }

    /// D13: show only this row with an orange outline for 2.5 s, then collapse unless hovering.
    /// While already expanded, the row is outlined in place for 2.5 s instead.
    func pulse(_ session: Session) {
        pulseTask?.cancel()
        if state.mode == .expanded {
            state.highlightId = session.id
            pulseTask = Task { [weak self] in
                try? await Task.sleep(for: NotchPanelController.pulseDuration)
                guard !Task.isCancelled, let self, self.state.highlightId == session.id else { return }
                self.state.highlightId = nil
            }
            return
        }
        state.mode = .pulse(session.id)
        applyFrame()
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: NotchPanelController.pulseDuration)
            guard !Task.isCancelled, let self else { return }
            guard case .pulse = self.state.mode else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { self.expand() } else { self.collapse() }
        }
    }
}
