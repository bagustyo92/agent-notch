import AgentNotchCore
import AppKit
import SwiftUI

/// `AgentNotch --demo [notch|dropdown]`: a scripted run on synthetic sessions (paths under
/// /Users/dev, R6) in front of a clean backdrop, for README media that must never show a real
/// session. It does not start the monitor and never reads ~/.claude (R1, R5).
@MainActor
final class DemoDriver {
    private struct Spec {
        let id: String
        let pid: Int32?
        let repo: String
        let branch: String
        let title: String
        let source: Source
        let model: String
        let effort: String
        let ageMinutes: Double
        let tools: [String]
    }

    private enum State {
        case idle, busy
        case waiting(why: String, needs: String)
    }

    private static let specs = [
        Spec(id: "demo-storefront", pid: 41001, repo: "storefront-web", branch: "feat/checkout-redesign", title: "Redesign the checkout flow",
             source: .cursor, model: "claude-opus-5-5", effort: "high", ageMinutes: 14,
             tools: ["Edit · CheckoutView.swift", "Read · CartSummary.swift", "Edit · PaymentStep.swift", "Bash · run unit tests"]),
        Spec(id: "demo-billing", pid: 41002, repo: "billing-api", branch: "fix/invoice-rounding", title: "Fix invoice rounding",
             source: .terminal, model: "claude-sonnet-5-5", effort: "medium", ageMinutes: 6,
             tools: ["Read · invoice_totals.go", "Edit · rounding.go", "Bash · run go tests"]),
        Spec(id: "demo-infra", pid: 41003, repo: "infra-terraform", branch: "feat/staging-vpc", title: "Add a staging VPC",
             source: .vscode, model: "claude-opus-5-5", effort: "high", ageMinutes: 31,
             tools: ["Write · vpc.tf", "Edit · variables.tf", "Bash · terraform validate"]),
        Spec(id: "demo-docs", pid: nil, repo: "docs-site", branch: "docs/migration-guide", title: "Draft the migration guide",
             source: .background, model: "claude-haiku-5-5", effort: "low", ageMinutes: 3,
             tools: ["Read · upgrade-notes.md", "Write · migration.md"]),
    ]

    private let store: SessionStore
    private let settings: Settings
    private let notch: NotchPanelController?
    private var states: [String: State] = [:]
    private var tickCount = 0

    init(store: SessionStore, settings: Settings, notch: NotchPanelController?) {
        self.store = store
        self.settings = settings
        self.notch = notch
    }

    /// Opens the backdrop window and starts the chosen scene. Prints the screen rect to capture.
    static func start(scene: String, store: SessionStore, settings: Settings, notch: NotchPanelController?) -> DemoDriver {
        let driver = DemoDriver(store: store, settings: settings, notch: notch)
        let stage = DemoStage(scene: scene, store: store, settings: settings)
        stage.show()
        print("STAGE \(Int(stage.captureRect.minX)),\(Int(stage.captureRect.minY)),\(Int(stage.captureRect.width)),\(Int(stage.captureRect.height))")
        fflush(stdout)
        Task { @MainActor in
            if scene == "dropdown" { await driver.runDropdown() } else { await driver.runNotch() }
        }
        retained = [stage]
        return driver
    }

    private static var retained: [DemoStage] = []

    // MARK: - Scenes

    private func runNotch() async {
        seed()
        await wait(3)
        set("demo-storefront", .busy, phase: .thinking)                        // the live strip opens
        await wait(2.5)
        set("demo-storefront", .busy, phase: .tool, tool: 0)
        spawn("a1", "Explore", "Map the checkout screens", "Grep · checkout", .tool)
        spawn("a2", "general-purpose", "Write tests for totals", "Read · CartSummary.swift", .tool)
        await wait(3)
        set("demo-billing", .busy, phase: .thinking)
        await wait(2.5)
        set("demo-billing", .busy, phase: .tool, tool: 0)
        set("demo-infra", .busy, phase: .tool, tool: 0)
        await wait(3)
        set("demo-infra", .waiting(why: "dialog open", needs: "Apply the Terraform plan to staging?"))   // needs you
        await wait(3.5)
        set("demo-docs", .busy, phase: .tool, tool: 0)                         // a fourth: "+1 more"
        await wait(3)
        notch?.expand()                                                          // hover: the full list
        spawn("a3", "Plan", "Design the payment step", "Read · PaymentStep.swift", .tool)
        spawn("a4", "general-purpose", "Update the Storybook stories", "Edit · Checkout.stories.tsx", .tool)
        await wait(8)
        for id in ["a1", "a2", "a3", "a4"] { finishSubagent(id) }
        set("demo-storefront", .idle)                                           // finished turn: green check
        await wait(4.5)
        notch?.collapse()
        await wait(3)
        set("demo-infra", .busy, phase: .tool, tool: 1)                        // answered: back to working, no pop-open
        await wait(2.5)
        settings.hideDetails = true                                             // screen-share mode
        notch?.expand()
        await wait(5)
        notch?.collapse()
        settings.hideDetails = false
        await wait(2)
        for id in ["demo-billing", "demo-docs", "demo-infra"] { set(id, .idle) }
        await wait(5)
        print("DEMO DONE")
        fflush(stdout)
        exit(0)
    }

    private func runDropdown() async {
        seed()
        set("demo-docs", .busy, phase: .tool, tool: 1)
        set("demo-docs", .idle)
        set("demo-storefront", .busy, phase: .tool, tool: 2)
        spawn("a1", "Explore", "Map the checkout screens", "Grep · checkout", .tool)
        spawn("a2", "general-purpose", "Write tests for totals", "Read · CartSummary.swift", .tool)
        spawn("a3", "Plan", "Design the payment step", "Read · PaymentStep.swift", .tool)
        set("demo-billing", .busy, phase: .thinking)
        set("demo-infra", .waiting(why: "dialog open", needs: "Apply the Terraform plan to staging?"))
        while true {
            await wait(2)
            tickActivity()
        }
    }

    // MARK: - Store plumbing

    private func seed() {
        for spec in Self.specs { states[spec.id] = .idle }
        apply()
        for spec in Self.specs {
            store.setProbe(id: spec.id, source: spec.source, tty: spec.pid == nil ? nil : "ttys003")
            store.updateTranscript(
                id: spec.id, aiTitle: spec.title, branch: spec.branch, activity: nil, phase: nil,
                model: spec.model, effort: spec.effort
            )
        }
    }

    private func apply() {
        let now = Date()
        let listed = Self.specs.map { spec -> ListedSession in
            var status: String?, state: String?, why: String?, needs: String?
            switch states[spec.id] ?? .idle {
            case .idle: status = "idle"; state = "idle"
            case .busy: status = "busy"; state = "running"
            case .waiting(let w, let n): status = "waiting"; state = "blocked"; why = w; needs = n
            }
            return ListedSession(
                sessionId: spec.id, pid: spec.pid, cwd: "/Users/dev/work/\(spec.repo)",
                kind: spec.pid == nil ? .background : .interactive, name: spec.title,
                startedAt: now.addingTimeInterval(-spec.ageMinutes * 60),
                status: spec.pid == nil ? nil : status, state: spec.pid == nil ? state : nil,
                waitingFor: why, version: SessionStore.defaultTestedVersion, transcriptModifiedAt: now, needs: needs
            )
        }
        store.replaceList(listed, now: now)
    }

    private func set(_ id: String, _ state: State, phase: Phase? = nil, tool: Int? = nil) {
        states[id] = state
        apply()
        guard let spec = Self.specs.first(where: { $0.id == id }) else { return }
        var activity: Activity?
        if let tool {
            let line = spec.tools[tool % spec.tools.count]
            activity = Activity(full: line, brief: String(line.prefix { $0 != " " }))
        }
        if phase != nil || activity != nil {
            store.updateTranscript(id: id, aiTitle: nil, branch: nil, activity: activity, phase: phase)
        }
    }

    private func spawn(_ id: String, _ type: String, _ description: String, _ tool: String, _ phase: Phase) {
        let now = Date()
        let activity = Activity(full: tool, brief: String(tool.prefix { $0 != " " }))
        store.updateSubagent(
            sessionId: "demo-storefront",
            update: SubagentUpdate(
                agentId: id, agentType: type, description: description, toolUseId: "tu-\(id)", spawnDepth: 1,
                startedAt: now, lastWriteAt: now,
                transcript: TranscriptUpdate(activity: activity, phase: phase, model: "claude-sonnet-5-5", effort: "medium")
            ),
            now: now
        )
    }

    private func finishSubagent(_ id: String) {
        let now = Date()
        store.updateSubagent(
            sessionId: "demo-storefront",
            update: SubagentUpdate(agentId: id, agentType: "Agent", finished: true, lastWriteAt: now),
            now: now
        )
    }

    /// Keep working rows moving: rotate the tool line and the phase.
    private func tickActivity() {
        tickCount += 1
        for spec in Self.specs {
            guard case .busy = states[spec.id] ?? .idle else { continue }
            let phases: [Phase] = [.tool, .thinking, .tool, .writing]
            set(spec.id, .busy, phase: phases[(tickCount + spec.tools.count) % phases.count], tool: tickCount)
        }
    }

    private func wait(_ seconds: Double) async {
        var left = seconds
        while left > 0 {
            let step = min(left, 2.5)
            try? await Task.sleep(for: .seconds(step))
            left -= step
            tickActivity()
        }
    }
}

/// A borderless window with a calm gradient, a mock menu bar and the notch region. It sits below the
/// notch panel (statusBar + 1) and covers everything behind it, so a screen capture of `captureRect`
/// shows nothing from the real desktop. Mouse events pass through.
@MainActor
final class DemoStage {
    private let window: NSWindow
    let captureRect: CGRect

    init(scene: String, store: SessionStore, settings: Settings) {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let notch = NotchGeometry.notchRect(on: screen)
        let size = scene == "dropdown" ? CGSize(width: 520, height: 780) : CGSize(width: 900, height: 640)
        let centerX = notch?.midX ?? screen.frame.midX
        let x = scene == "dropdown" ? screen.frame.midX - size.width / 2 : centerX - size.width / 2
        let frame = CGRect(x: x, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        captureRect = CGRect(x: frame.minX - screen.frame.minX, y: 0, width: size.width, height: size.height)

        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view: AnyView = scene == "dropdown"
            ? AnyView(DemoDropdownStage(store: store, settings: settings))
            : AnyView(DemoNotchStage(store: store, barHeight: notch?.height ?? 32))
        window.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    }

    func show() { window.orderFrontRegardless() }
}

private let demoWallpaper = LinearGradient(
    colors: [Color(red: 0.07, green: 0.09, blue: 0.24), Color(red: 0.30, green: 0.14, blue: 0.40), Color(red: 0.80, green: 0.38, blue: 0.36)],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

/// Wallpaper plus a mock menu bar: app menus left of the notch, status items right of it.
private struct DemoNotchStage: View {
    let store: SessionStore
    let barHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            demoWallpaper
            HStack(spacing: 16) {
                Text("Terminal").fontWeight(.bold)
                Text("Shell"); Text("Edit"); Text("View")
                Spacer()
                StatusItemView(store: store)
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text("Fri 9:41")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: barHeight)
            .background(Color.black.opacity(0.28))
        }
        .ignoresSafeArea()
    }
}

/// The menu bar dropdown on a solid card (a material would blur the real desktop behind the window).
private struct DemoDropdownStage: View {
    let store: SessionStore
    let settings: Settings
    private let popoverState: PopoverState = {
        let state = PopoverState()
        state.isShown = true
        return state
    }()

    var body: some View {
        ZStack {
            demoWallpaper
            PopoverView(store: store, settings: settings, popoverState: popoverState)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        }
        .ignoresSafeArea()
    }
}
