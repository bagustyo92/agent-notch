import AgentNotchCore
import AppKit
import SwiftUI

/// `AgentNotch --demo [notch|dropdown|menubar|bench-…]`: a scripted run on synthetic sessions (paths under
/// /Users/dev, R6) in front of a clean backdrop, for README media that must never show a real
/// session. It does not start the monitor and never reads ~/.claude (R1, R5). `menubar` has no
/// backdrop: it steps the real menu bar item through its states and writes a PNG of each.
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
        /// Starting context size (D38): one session around 40%, one amber, one red.
        let contextTokens: Int
        let tools: [String]
    }

    private enum State {
        case idle, busy
        case waiting(why: String, needs: String)
    }

    private static let specs = [
        Spec(id: "demo-storefront", pid: 41001, repo: "storefront-web", branch: "feat/checkout-redesign", title: "Redesign the checkout flow",
             source: .cursor, model: "claude-opus-5-5", effort: "high", ageMinutes: 14, contextTokens: 402_000,
             tools: ["Edit · CheckoutView.swift", "Read · CartSummary.swift", "Edit · PaymentStep.swift", "Bash · run unit tests"]),
        Spec(id: "demo-billing", pid: 41002, repo: "billing-api", branch: "fix/invoice-rounding", title: "Fix invoice rounding",
             source: .terminal, model: "claude-sonnet-5-5", effort: "medium", ageMinutes: 6, contextTokens: 752_000,
             tools: ["Read · invoice_totals.go", "Edit · rounding.go", "Bash · run go tests"]),
        Spec(id: "demo-infra", pid: 41003, repo: "infra-terraform", branch: "feat/staging-vpc", title: "Add a staging VPC",
             source: .vscode, model: "claude-opus-5-5", effort: "high", ageMinutes: 31, contextTokens: 912_000,
             tools: ["Write · vpc.tf", "Edit · variables.tf", "Bash · terraform validate"]),
        Spec(id: "demo-docs", pid: nil, repo: "docs-site", branch: "docs/migration-guide", title: "Draft the migration guide",
             source: .background, model: "claude-haiku-5-5", effort: "low", ageMinutes: 3, contextTokens: 118_000,
             tools: ["Read · upgrade-notes.md", "Write · migration.md"]),
    ]

    private let store: SessionStore
    private let settings: Settings
    private let notch: NotchPanelController?
    private let statusItem: StatusItemController?
    private var states: [String: State] = [:]
    private var contextTokens: [String: Int] = [:]
    private var tickCount = 0
    /// `--demo menubar <dir>` writes one PNG per state there.
    var snapshotDir: String?

    init(store: SessionStore, settings: Settings, notch: NotchPanelController?, statusItem: StatusItemController?) {
        self.store = store
        self.settings = settings
        self.notch = notch
        self.statusItem = statusItem
    }

    /// Opens the backdrop window and starts the chosen scene. Prints the screen rect to capture.
    static func start(scene: String, store: SessionStore, settings: Settings, notch: NotchPanelController?,
                      statusItem: StatusItemController?) -> DemoDriver {
        let driver = DemoDriver(store: store, settings: settings, notch: notch, statusItem: statusItem)
        if scene == "menubar" {
            let args = CommandLine.arguments
            driver.snapshotDir = args.firstIndex(of: "menubar").flatMap { args.dropFirst($0 + 1).first }
            Task { @MainActor in await driver.runMenuBar() }
            return driver
        }
        if scene.hasPrefix("bench") {                 // no stage: nothing on screen but the notch
            Task { @MainActor in await driver.runBench(scene) }
            return driver
        }
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

    /// The menu bar card with every state. A finished turn (`demo-docs`) keeps a fork and a Bash task
    /// running in the background (D41); after ~25 s both finish and fold, then every session goes
    /// quiet. Capture the stills before that.
    private func runDropdown() async {
        seed()
        let now = Date()
        set("demo-docs", .busy, phase: .tool, tool: 0, at: now.addingTimeInterval(-300))   // a finished turn with files
        set("demo-docs", .busy, phase: .tool, tool: 1, at: now.addingTimeInterval(-200))
        set("demo-docs", .idle, at: now.addingTimeInterval(-120))
        spawn("bg1", "fork", "Run the release checklist", "Bash · Run e2e suite", .tool, session: "demo-docs",
              at: now.addingTimeInterval(-170))
        startTask("toolu_demo_api", "Run local API server", session: "demo-docs", at: now.addingTimeInterval(-150))
        set("demo-storefront", .busy, phase: .tool, tool: 2)
        // a2 and a3 nest under a1, so the card shows one subagent and "+2 more" and the list fits
        // ListMetrics.maxHeight with the two background rows.
        spawn("a1", "Explore", "Map the checkout screens", "Grep · checkout", .tool, spawns: ["a2", "a3"])
        spawn("a2", "general-purpose", "Write tests for totals", "Read · CartSummary.swift", .tool)
        spawn("a3", "Plan", "Design the payment step", "Read · PaymentStep.swift", .tool)
        set("demo-billing", .busy, phase: .thinking)
        set("demo-infra", .waiting(why: "dialog open", needs: "Apply the Terraform plan to staging?"))
        await wait(25)
        finishSubagent("bg1", session: "demo-docs")                            // folds at once: its parent is idle
        closeTask("toolu_demo_api", session: "demo-docs")
        await wait(6)
        for id in ["a1", "a2", "a3"] { finishSubagent(id) }
        for id in ["demo-storefront", "demo-billing", "demo-infra"] { set(id, .idle) }   // "All quiet"
        while true { await wait(2) }
    }

    /// `--demo bench-<working|waiting|thinking>[-strip]`: hold one state forever, the notch collapsed
    /// unless `-strip`, so its CPU can be measured (D42); `bench-idle` holds every session idle.
    /// Measure with `ps -o time= -p <pid>` over 20 s after an 8 s settle.
    private func runBench(_ scene: String) async {
        seed()
        try? await Task.sleep(for: .seconds(1))
        if scene.hasPrefix("bench-working") { set("demo-storefront", .busy, phase: .tool, tool: 0) }
        if scene.hasPrefix("bench-waiting") { set("demo-infra", .waiting(why: "dialog open", needs: "Apply?")) }
        if scene.hasPrefix("bench-thinking") { set("demo-billing", .busy, phase: .thinking) }
        try? await Task.sleep(for: .seconds(1))
        if !scene.hasSuffix("-strip") { notch?.collapse() }
        print("BENCH READY"); fflush(stdout)
        while true { try? await Task.sleep(for: .seconds(60)) }
    }

    /// Each state the menu bar item can show, held long enough to capture (the check lasts 4 s).
    private func runMenuBar() async {
        seed()
        await shot("idle")
        set("demo-storefront", .busy, phase: .tool, tool: 0)
        set("demo-billing", .busy, phase: .thinking)
        await shot("working")
        set("demo-infra", .waiting(why: "dialog open", needs: "Apply the Terraform plan to staging?"))
        await shot("working-and-needs-you")
        set("demo-storefront", .idle)
        set("demo-billing", .idle)
        await shot("needs-you")
        set("demo-infra", .busy, phase: .tool, tool: 1)
        await wait(1)
        set("demo-infra", .idle)                                                // finished turn: green check
        await shot("finished")
        await wait(4)
        await shot("idle-again")
        print("DEMO DONE")
        fflush(stdout)
        exit(0)
    }

    /// Lets the item settle, prints `SHOT <name> <width>` and writes `<snapshotDir>/<name>.png`,
    /// then holds. macOS draws status items out of process, so `screencapture` cannot reach them:
    /// the PNG renders the item's view clipped to the button's real size, on a dark bar.
    private func shot(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(800))
        if let statusItem, let size = statusItem.button?.bounds.size {
            if let dir = snapshotDir {
                let renderer = ImageRenderer(content: statusItem.view
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .background(Color(white: 0.12))
                    .environment(\.colorScheme, .dark))
                renderer.scale = 4
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
            }
            print("SHOT \(name) \(Int(size.width))")
            fflush(stdout)
        }
        try? await Task.sleep(for: .milliseconds(1500))
    }

    // MARK: - Store plumbing

    private func seed() {
        for spec in Self.specs { states[spec.id] = .idle; contextTokens[spec.id] = spec.contextTokens }
        apply()
        for spec in Self.specs {
            store.setProbe(id: spec.id, source: spec.source, tty: spec.pid == nil ? nil : "ttys003")
            store.updateTranscript(
                id: spec.id, aiTitle: spec.title, branch: spec.branch, activity: nil, phase: nil,
                model: spec.model, effort: spec.effort, contextTokens: spec.contextTokens
            )
        }
    }

    private func apply(at now: Date = Date()) {
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

    private func set(_ id: String, _ state: State, phase: Phase? = nil, tool: Int? = nil, at now: Date = Date()) {
        states[id] = state
        apply(at: now)
        guard let spec = Self.specs.first(where: { $0.id == id }) else { return }
        var activity: Activity?
        var edits: [Int] = []
        if let tool {
            let line = spec.tools[tool % spec.tools.count]
            activity = Activity(full: line, brief: String(line.prefix { $0 != " " }))
            edits = Self.editedPathHashes(line, repo: spec.repo)
        }
        if phase != nil || activity != nil {
            store.updateTranscript(id: id, aiTitle: nil, branch: nil, activity: activity, phase: phase, editedPathHashes: edits)
        }
    }

    private func spawn(
        _ id: String, _ type: String, _ description: String, _ tool: String, _ phase: Phase,
        session: String = "demo-storefront", spawns: [String] = [], at startedAt: Date = Date()
    ) {
        let now = Date()
        let activity = Activity(full: tool, brief: String(tool.prefix { $0 != " " }))
        let repo = Self.specs.first { $0.id == session }?.repo ?? "storefront-web"
        store.updateSubagent(
            sessionId: session,
            update: SubagentUpdate(
                agentId: id, agentType: type, description: description, toolUseId: "tu-\(id)", spawnDepth: 1,
                startedAt: startedAt, lastWriteAt: now,
                transcript: TranscriptUpdate(activity: activity, phase: phase, model: "claude-sonnet-5-5", effort: "medium",
                                             spawnedToolUseIds: spawns.map { "tu-\($0)" },
                                             editedPathHashes: Self.editedPathHashes(tool, repo: repo))
            ),
            now: now
        )
    }

    /// A background Bash call (D41): the main session's goes through its transcript, a subagent's
    /// through that subagent's.
    private func startTask(_ id: String, _ description: String, session: String, owner: String? = nil, at startedAt: Date = Date()) {
        let start = BackgroundStart(
            toolUseId: id, activity: ActivitySummary.forToolUse(name: "Bash", input: ["description": description]), startedAt: startedAt
        )
        taskRecord(session: session, owner: owner, TranscriptUpdate(backgroundStarts: [start]))
    }

    /// The task's `<task-notification>` arrives.
    private func closeTask(_ id: String, session: String, owner: String? = nil) {
        taskRecord(session: session, owner: owner, TranscriptUpdate(closedToolUseIds: [id]))
    }

    private func taskRecord(session: String, owner: String?, _ read: TranscriptUpdate) {
        let now = Date()
        guard let owner else { store.updateTranscript(id: session, update: read, now: now); return }
        let agent = store.session(id: session)?.subagents.first { $0.id == owner }
        store.updateSubagent(
            sessionId: session,
            update: SubagentUpdate(agentId: owner, agentType: agent?.agentType ?? "Agent", description: agent?.description ?? "",
                                   toolUseId: agent?.toolUseId, spawnDepth: agent?.spawnDepth ?? 1, lastWriteAt: now, transcript: read),
            now: now
        )
    }

    /// `Edit · PaymentStep.swift` counts toward the turn summary (D39); reads and commands do not.
    private static func editedPathHashes(_ line: String, repo: String) -> [Int] {
        guard line.hasPrefix("Edit · ") || line.hasPrefix("Write · ") else { return [] }
        let file = line.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
        return ["/Users/dev/work/\(repo)/\(file)".hashValue]
    }

    private func finishSubagent(_ id: String, session: String = "demo-storefront") {
        let now = Date()
        store.updateSubagent(
            sessionId: session,
            update: SubagentUpdate(agentId: id, agentType: "Agent", finished: true, lastWriteAt: now),
            now: now
        )
    }

    /// Keep working rows moving: rotate the tool line and the phase, and let the context creep up.
    private func tickActivity() {
        tickCount += 1
        for spec in Self.specs {
            guard case .busy = states[spec.id] ?? .idle else { continue }
            let phases: [Phase] = [.tool, .thinking, .tool, .writing]
            set(spec.id, .busy, phase: phases[(tickCount + spec.tools.count) % phases.count], tool: tickCount)
            let grown = (contextTokens[spec.id] ?? spec.contextTokens) + 1_400
            contextTokens[spec.id] = grown
            store.updateTranscript(id: spec.id, aiTitle: nil, branch: nil, activity: nil, contextTokens: grown)
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
        let size = scene == "dropdown" ? CGSize(width: 520, height: 840) : CGSize(width: 900, height: 640)
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
    private let barState = StatusItemState()

    var body: some View {
        ZStack(alignment: .top) {
            demoWallpaper
            HStack(spacing: 16) {
                Text("Terminal").fontWeight(.bold)
                Text("Shell"); Text("Edit"); Text("View")
                Spacer()
                StatusItemView(store: store, state: barState)
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
