import AgentNotchCore
import AppKit
import SwiftUI

/// D14: geometry from public NSScreen APIs only. The black shape hangs from the top centre of the
/// notch (or of the screen); the panel is that shape plus room for its shadow.
enum NotchGeometry {
    /// Width of each side of the collapsed notch while something is live (Q14).
    static let wing: CGFloat = 80
    static let shadowPad: CGFloat = 26
    static let stripWidth: CGFloat = 420
    static let expandedWidth: CGFloat = 480
    /// No-notch screens: the live pill, and the small idle pill that stays hoverable.
    static let pillSize = CGSize(width: 230, height: 32)
    static let idlePill = CGSize(width: 96, height: 22)
    static let headerHeight: CGFloat = 20
    static let messageLineHeight: CGFloat = 16

    /// The physical notch, or nil on a screen without one.
    static func notchRect(on screen: NSScreen) -> CGRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let frame = screen.frame
        return CGRect(x: left.maxX, y: frame.maxY - inset, width: right.minX - left.maxX, height: inset)
    }

    /// The visible shape of the given size, in screen coordinates.
    static func shapeRect(size: CGSize, on screen: NSScreen) -> CGRect {
        let centerX = notchRect(on: screen)?.midX ?? screen.frame.midX
        return CGRect(x: centerX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    static func panelFrame(size: CGSize, on screen: NSScreen) -> CGRect {
        let shape = shapeRect(size: size, on: screen)
        return CGRect(x: shape.minX - shadowPad, y: shape.minY - shadowPad, width: shape.width + 2 * shadowPad, height: shape.height + shadowPad)
    }
}

@MainActor
@Observable
final class NotchState {
    /// Collapsed → live strip (opened by an event, Q11) → expanded (hover; acknowledges the strip).
    enum Mode: Equatable { case collapsed, live, expanded }
    var mode: Mode = .collapsed
    /// Size of the black shape; the view springs to it (Q7).
    var shapeSize: CGSize = .zero
    /// Collapsed sides: shown while any session works or needs you, or a turn just finished (Q14).
    var sidesLive = false
    var finishFlash = false
    /// Row to outline while already expanded (an event that arrives mid-hover).
    var highlightId: String?
    var hasNotch = true
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var message: String?
    let list = ListUIState()

    var bottomRadius: CGFloat {
        switch mode {
        case .collapsed: hasNotch ? 10 : 12
        case .live: 20
        case .expanded: 24
        }
    }
}

struct NotchRootView: View {
    let state: NotchState
    let store: SessionStore
    let settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: state.bottomRadius, bottomTrailingRadius: state.bottomRadius, style: .continuous
        )
        ZStack(alignment: .top) {
            switch state.mode {
            case .collapsed:
                CollapsedNotchView(state: state, store: store).transition(.opacity)
            case .live:
                LiveStripView(store: store, settings: settings)
                    .padding(.horizontal, 14)
                    .padding(.top, state.notchHeight + 8)
                    .transition(.opacity)
            case .expanded:
                ExpandedNotchView(state: state, store: store, settings: settings).transition(.opacity)
            }
        }
        .frame(width: state.shapeSize.width, height: state.shapeSize.height, alignment: .top)
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(Color.white.opacity(state.mode == .collapsed ? 0 : 0.08), lineWidth: 0.5))
        .clipShape(shape)
        .shadow(color: .black.opacity(state.mode == .collapsed ? 0 : 0.45), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8), value: state.shapeSize)
        .animation(.easeOut(duration: 0.18), value: state.mode)
        .environment(\.colorScheme, .dark)
    }
}

/// Collapsed: the notch grows a side on each edge while something is live (Q14). Left: working
/// dots and the working count. Right: the needs-you count, or a check when a turn just finished.
struct CollapsedNotchView: View {
    let state: NotchState
    let store: SessionStore

    var body: some View {
        if state.hasNotch {
            let side = max(0, (state.shapeSize.width - state.notchWidth) / 2)
            HStack(spacing: 0) {
                sideZone(width: side) {
                    if store.workingCount > 0 {
                        HStack(spacing: 7) {
                            WorkingDots(size: 4.5)
                            count(store.workingCount, color: .white)
                        }
                    }
                }
                Color.clear.frame(width: state.notchWidth)
                sideZone(width: side) { rightContent }
            }
            .frame(height: state.notchHeight)
        } else {
            HStack(spacing: 8) {
                if state.sidesLive {
                    if store.workingCount > 0 {
                        WorkingDots(size: 4)
                        count(store.workingCount, color: .white)
                    }
                    rightContent
                } else {
                    BotGlyph().frame(width: 13, height: 13).foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: state.shapeSize.width, height: state.shapeSize.height)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        if store.waitingCount > 0 {
            HStack(spacing: 6) {
                Circle().fill(Palette.needsYou).frame(width: 7, height: 7).breathingGlow(Palette.needsYou, radius: 5)
                count(store.waitingCount, color: Palette.needsYou)
            }
        } else if state.finishFlash {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.finished)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func count(_ n: Int, color: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(.numericText())
    }

    /// Content is centred in its side, so it keeps clear of the notch edge. The clear base keeps the
    /// side its full width when it has nothing to show: an empty side would collapse to zero and
    /// shift the other side's count under the notch.
    private func sideZone<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .frame(width: width, height: state.notchHeight)
            .overlay { content() }
            .clipped()
    }
}

struct ExpandedNotchView: View {
    let state: NotchState
    let store: SessionStore
    let settings: Settings

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: state.hasNotch ? state.notchHeight : 0)
            BrandHeader(store: store).frame(height: NotchGeometry.headerHeight)
            SessionListView(store: store, settings: settings, ui: state.list, highlightId: state.highlightId) { state.message = $0 }
            Text(state.message ?? "Click a row to open it · move away to close")
                .font(.system(size: 10, design: state.message == nil ? .default : .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(height: NotchGeometry.messageLineHeight)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// The bot glyph and name on the left, the live summary on the right: the notch's hover view and
/// the dropdown open with the same header (Q3).
struct BrandHeader: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 7) {
            BotGlyph(waiting: store.waitingCount > 0)
                .frame(width: 16, height: 16)
                .foregroundStyle(store.waitingCount > 0 ? Palette.needsYou : Color.primary)
            Text("AgentNotch").font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 8)
            SummaryHeader(store: store)
        }
        .padding(.horizontal, 4)
    }
}

/// `● 2 working  ● 1 needs you`.
struct SummaryHeader: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            if store.workingCount > 0 { chip(store.workingCount, "working", Palette.working) }
            if store.waitingCount > 0 { chip(store.waitingCount, "need\(store.waitingCount == 1 ? "s" : "") you", Palette.needsYou) }
            if store.workingCount == 0, store.waitingCount == 0 {
                Text("All quiet").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private func chip(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(n) \(label)").font(.system(size: 11, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        }
    }
}

/// The notch overlay: an NSPanel that never takes key focus (D1, D13, D14).
@MainActor
final class NotchPanelController {
    private let panel: NSPanel
    private let state = NotchState()
    private let store: SessionStore
    private let settings: Settings
    private var monitors: [Any] = []
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?

    static let hoverDelay: Duration = .milliseconds(150)
    static let collapseDelay: Duration = .milliseconds(300)
    static let highlightDuration: Duration = .milliseconds(2500)
    /// Longer than the spring, so the panel shrinks only after the shape has.
    static let shrinkDelay: Duration = .milliseconds(480)
    /// Extra height below the collapsed shape that still counts as "on the notch" (Q13).
    static let hoverSlop: CGFloat = 4

    init(store: SessionStore, settings: Settings) {
        self.store = store
        self.settings = settings
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(rootView: NotchRootView(state: state, store: store, settings: settings))
        hosting.sizingOptions = []          // the controller owns the panel size
        panel.contentView = hosting

        reposition()
        panel.orderFrontRegardless()
        observeStore()
        // Finish flashes and the live strip expire with time, not with a store change.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.relayout()
            }
        }

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

    /// Re-lay out on every store change: counts, rows and subagents all move the shape.
    private func observeStore() {
        withObservationTracking {
            _ = store.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.relayout()
                self.observeStore()
            }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first }   // the menu-bar screen (D14)

    private var shapeRect: CGRect {
        guard let screen else { return .zero }
        return NotchGeometry.shapeRect(size: state.shapeSize, on: screen)
    }

    /// The area that reacts to hover and click: the whole visible shape, a little taller (Q13).
    private var hotRect: CGRect {
        var rect = shapeRect
        if state.mode == .collapsed, state.hasNotch, !state.sidesLive, let screen, let notch = NotchGeometry.notchRect(on: screen) {
            rect = notch
        }
        rect.origin.y -= Self.hoverSlop
        rect.size.height += Self.hoverSlop
        return rect
    }

    func reposition() {
        guard let screen else { return }
        let notch = NotchGeometry.notchRect(on: screen)
        state.hasNotch = notch != nil
        state.notchWidth = notch?.width ?? 0
        state.notchHeight = notch?.height ?? 0
        relayout(force: true)
    }

    private func targetSize(now: Date) -> CGSize {
        let top = state.hasNotch ? state.notchHeight : 0
        switch state.mode {
        case .collapsed:
            if state.hasNotch {
                return CGSize(width: state.notchWidth + (state.sidesLive ? 2 * NotchGeometry.wing : 0), height: state.notchHeight)
            }
            return state.sidesLive ? NotchGeometry.pillSize : NotchGeometry.idlePill
        case .live:
            let items = LiveStripView.items(store: store, settings: settings, now: now)
            let width = max(NotchGeometry.stripWidth, state.notchWidth + 2 * NotchGeometry.wing)
            return CGSize(width: width, height: top + 8 + ListMetrics.stripHeight(items) + 12)
        case .expanded:
            let list = ListMetrics.listHeight(SessionListView.items(store: store, ui: state.list))
            return CGSize(width: NotchGeometry.expandedWidth,
                          height: top + 6 + NotchGeometry.headerHeight + 6 + list + 6 + NotchGeometry.messageLineHeight + 10)
        }
    }

    /// Recompute the collapsed flags and the shape size. Growing sets the panel frame first so the
    /// spring has room; shrinking springs first and trims the panel afterwards.
    func relayout(force: Bool = false) {
        guard let screen else { return }
        let now = Date()
        // Write only on change: every @Observable write re-renders, and this runs twice a second.
        let flash = store.anyJustFinished(now: now)
        if state.finishFlash != flash { state.finishFlash = flash }
        let sidesLive = store.workingCount > 0 || store.waitingCount > 0 || flash
        if state.sidesLive != sidesLive { state.sidesLive = sidesLive }
        if state.mode == .live, store.liveSessions(now: now).isEmpty { state.mode = .collapsed }

        let target = targetSize(now: now)
        if panel.ignoresMouseEvents != (state.mode != .expanded) { panel.ignoresMouseEvents = state.mode != .expanded }
        guard force || target != state.shapeSize else { return }
        let current = state.shapeSize
        let room = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        shrinkTask?.cancel()
        panel.setFrame(NotchGeometry.panelFrame(size: room, on: screen), display: true)
        state.shapeSize = target
        guard room != target else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: NotchPanelController.shrinkDelay)
            guard !Task.isCancelled, let self, let screen = self.screen else { return }
            self.panel.setFrame(NotchGeometry.panelFrame(size: self.state.shapeSize, on: screen), display: true)
        }
    }

    // MARK: - Events

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53, state.mode != .collapsed { collapse() }   // Esc
            return
        }
        let location = NSEvent.mouseLocation
        switch state.mode {
        case .collapsed, .live:
            let inside = hotRect.contains(location)
            if inside, event.type == .leftMouseDown { expand(); return }
            if inside { scheduleExpand() } else { cancelExpand() }
        case .expanded:
            if shapeRect.contains(location) { cancelCollapse() } else { scheduleCollapse() }
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
            if self.state.mode == .expanded, !self.shapeRect.contains(NSEvent.mouseLocation) { self.collapse() }
        }
    }

    private func cancelCollapse() { collapseTask?.cancel(); collapseTask = nil }

    /// Hovering acknowledges the live strip (Q11): leaving collapses it until the next event.
    func expand() {
        cancelExpand()
        state.mode = .expanded
        relayout()
    }

    func collapse() {
        cancelExpand(); cancelCollapse()
        state.message = nil
        state.highlightId = nil
        state.list.reset()
        state.mode = .collapsed
        relayout()
    }

    /// D13, Q11: a session started working, needs you, or finished. Collapsed → open the live strip
    /// (unless switched off, Q16); expanded → outline that row for 2.5 s instead.
    func attention(_ session: Session, kind: AttentionKind) {
        // The store fires mid-merge, before it publishes; act once the new list is visible.
        Task { @MainActor [weak self] in self?.applyAttention(session, kind: kind) }
    }

    private func applyAttention(_ session: Session, kind: AttentionKind) {
        switch state.mode {
        case .expanded:
            guard kind != .started else { return }
            highlightTask?.cancel()
            state.highlightId = session.id
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: NotchPanelController.highlightDuration)
                guard !Task.isCancelled, let self, self.state.highlightId == session.id else { return }
                self.state.highlightId = nil
            }
        case .collapsed:
            guard settings.autoOpen else { return }
            state.mode = .live
            relayout()
        case .live:
            relayout()
        }
    }
}
