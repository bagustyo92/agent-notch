import Foundation

/// What a row shows, derived from status, phase and the last finished turn (D32). `background` is a
/// child still running after its parent's turn ended (D41).
public enum DisplayState: Sendable, Equatable {
    case working(Phase?)
    case needsYou
    case finished
    case idle
    case ended
    case background

    /// How long an idle session keeps the green "Finished" look after its turn ends.
    public static let finishedWindow: TimeInterval = 600

    public static func of(_ session: Session, now: Date) -> DisplayState {
        switch session.status {
        case .working: return .working(session.phase)
        case .waiting: return .needsYou
        case .done: return .ended
        case .idle:
            guard let at = session.turnFinishedAt, now.timeIntervalSince(at) < finishedWindow else { return .idle }
            return .finished
        }
    }

    /// A running subagent of an idle parent is in the background; under a working or waiting parent
    /// it looks as it always has (D41).
    public static func of(_ subagent: Subagent, parent: Status) -> DisplayState {
        if subagent.finished { return .finished }
        return parent == .idle ? .background : .working(subagent.phase)
    }

    /// A background Bash task: `Background` under an idle parent, `Running` (working) otherwise (D41).
    public static func of(_ task: BackgroundTask, parent: Status) -> DisplayState {
        switch parent {
        case .idle: .background
        case .done: .ended
        case .working, .waiting: .working(.tool)
        }
    }

    /// Only working and needs-you animate or count as live (D34); background never opens the notch.
    public var isLive: Bool {
        switch self {
        case .working, .needsYou: true
        case .finished, .idle, .ended, .background: false
        }
    }
}

/// The words of the Background state (D41).
public enum BackgroundLabel {
    public static let state = "Background"
    /// Line 2 of a task row while its parent works or waits.
    public static let running = "Running"

    /// `· 2 in background` after an idle parent's Idle or Finished line; nil at zero. Counts only, so
    /// Hide details shows it.
    public static func parentSuffix(count: Int) -> String? { count > 0 ? "· \(count) in background" : nil }

    /// `2 in background`, the header chip; nil at zero.
    public static func chip(count: Int) -> String? { count > 0 ? "\(count) in background" : nil }

    /// What follows `Background ·` on a subagent row: the brief activity under Hide details.
    public static func activity(_ activity: Activity?, hideDetails: Bool) -> String? {
        guard let activity else { return nil }
        return hideDetails ? activity.brief : activity.full
    }

    /// `Run e2e suite`, after `Bash` on a task row's first line; nil under Hide details or when the
    /// call had no description.
    public static func taskDetail(_ task: BackgroundTask, hideDetails: Bool) -> String? {
        let prefix = task.activity.brief + " · "
        guard !hideDetails, task.activity.full.hasPrefix(prefix) else { return nil }
        let detail = task.activity.full.dropFirst(prefix.count)
        return detail.isEmpty ? nil : String(detail)
    }
}

/// The needs-you label from Claude Code's `waitingFor` (D31). Values seen in 2.1.310:
/// `dialog open`, `input needed`, `sandbox request`, `goal proposal`.
public enum NeedsLabel {
    public static func text(waitingFor: String?) -> String {
        switch waitingFor?.lowercased() {
        case "dialog open": "Needs a decision"
        case "input needed": "Needs your input"
        case "sandbox request": "Needs network access"
        case "goal proposal": "Needs goal approval"
        default: "Needs you"
        }
    }
}

/// The "+N more" line under a collapsed session (Q25). A background task is not an agent, so the
/// noun goes once the session has any (D41).
public enum MoreLabel {
    public static func children(hidden: Int, hasTasks: Bool) -> String {
        hasTasks ? "\(hidden) more" : "\(hidden) more agent\(hidden == 1 ? "" : "s")"
    }
}

/// The name on a live-strip line: the AI title cut short, or the repo while no title exists yet
/// and under Hide details (D10, D35).
public enum StripLabel {
    /// Longest label, ellipsis included.
    public static let maxLength = 24

    public static func text(for session: Session, hideDetails: Bool) -> String {
        guard !hideDetails, let title = session.aiTitle else { return session.repo }
        let short = shorten(title)
        return short.isEmpty ? session.repo : short
    }

    /// `· 81% ctx` after the name, only when the context is amber or red (D38).
    public static func contextSuffix(for session: Session) -> (text: String, level: ContextLevel)? {
        guard let context = ContextIndicator.of(session), context.level != .normal else { return nil }
        return ("· \(context.label) ctx", context.level)
    }

    /// Cut at a word boundary, ending in `…`; a first word longer than the cap is cut hard.
    static func shorten(_ title: String, limit: Int = maxLength) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        var head = String(trimmed.prefix(limit - 1))
        let cutMidWord = !(trimmed.dropFirst(head.count).first?.isWhitespace ?? true)
        if cutMidWord, let space = head.lastIndex(where: \.isWhitespace) { head = String(head[..<space]) }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return head.isEmpty ? String(trimmed.prefix(limit - 1)) + "…" : head + "…"
    }
}

/// `claude-opus-5-5` → `Opus 5.5`, `claude-sonnet-4-5-20250929[1m]` → `Sonnet 4.5`,
/// `claude-3-5-haiku-20241022` → `Haiku 3.5` (D30). Ids that do not look like that pass through.
public enum ModelName {
    public static func display(_ id: String) -> String {
        let base = id.split(separator: "[").first.map(String.init) ?? id
        let parts = base.lowercased().split(separator: "-").map(String.init)
        guard parts.first == "claude" else { return id }
        var family: String?
        var version: [String] = []
        for part in parts.dropFirst() {
            if part.allSatisfy(\.isNumber) {
                if part.count <= 2 { version.append(part) }        // 8-digit snapshot dates are dropped
            } else if family == nil, part.allSatisfy(\.isLetter) {
                family = part.prefix(1).uppercased() + part.dropFirst()
            } else {
                return id
            }
        }
        guard let family else { return id }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }

    /// `Opus 5.5 · high · 62%`; nil when none is known. The context label comes from
    /// `ContextIndicator` (D38).
    public static func capsule(model: String?, effort: String?, context: String? = nil) -> String? {
        let parts = [model.map(display), effort, context].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The finished-turn line: `Finished 2m ago · 4 files · ran 3m` (D39). Counts only, so Hide
/// details shows it as is.
public enum FinishedLabel {
    public static func text(finishedAt: Date?, startedAt: Date?, files: Int, now: Date) -> String {
        guard let finishedAt else { return "Finished" }
        var parts = ["Finished \(ElapsedFormatter.string(now.timeIntervalSince(finishedAt))) ago"]
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if let startedAt { parts.append("ran \(ElapsedFormatter.string(finishedAt.timeIntervalSince(startedAt)))") }
        return parts.joined(separator: " · ")
    }
}

/// The rotating "Percolating…" verb shown while a session thinks (D29). Our own list: Claude Code's
/// spinner text is not written anywhere AgentNotch can read.
public enum SpinnerVerbs {
    public static let all = [
        "Combobulating", "Percolating", "Noodling", "Pondering", "Mulling", "Tinkering", "Brewing",
        "Simmering", "Whirring", "Cogitating", "Ruminating", "Musing", "Churning", "Conjuring",
        "Crafting", "Deliberating", "Fermenting", "Hatching", "Incubating", "Kneading", "Marinating",
        "Puzzling", "Scheming", "Sifting", "Spelunking", "Stewing", "Untangling", "Whittling",
        "Wrangling", "Distilling", "Finagling", "Moseying", "Synthesizing", "Tumbling", "Unfurling",
        "Pottering", "Riffing", "Sleuthing", "Vibing", "Zigzagging",
    ]
    public static let interval: TimeInterval = 4

    /// Deterministic per id and time slot, so rows rotate out of step and never flicker.
    public static func verb(for id: String, at date: Date) -> String {
        let slot = UInt64(max(0, date.timeIntervalSince1970 / interval))
        let index = (fnv1a(id) &+ slot) % UInt64(all.count)
        return all[Int(index)] + "…"
    }

    /// Stable across launches, unlike `hashValue`.
    static func fnv1a(_ s: String) -> UInt64 {
        s.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// The three groups of the full list, in display order (D36).
public enum SessionSection: String, Sendable, CaseIterable {
    case needsYou, working, done

    public static func of(_ session: Session) -> SessionSection {
        switch session.status {
        case .waiting: .needsYou
        case .working: .working
        case .idle, .done: .done
        }
    }
}

/// One line of a session list: a section header, a session, one of its subagents or background
/// tasks, "+N more" children (D33, Q25, D41), or "+N more" sessions of a section (D36).
public enum TreeItem: Identifiable, Sendable, Equatable {
    case header(SessionSection, count: Int)
    case session(Session)
    case subagent(Subagent, sessionId: String, level: Int)
    case task(BackgroundTask, sessionId: String, level: Int)
    case more(sessionId: String, hidden: Int)
    case sectionMore(SessionSection, hidden: Int)

    public var id: String {
        switch self {
        case .header(let section, _): "h:\(section.rawValue)"
        case .session(let s): "s:\(s.id)"
        case .subagent(let a, let sid, _): "a:\(sid):\(a.id)"
        case .task(let t, let sid, _): "t:\(sid):\(t.id)"
        case .more(let sid, _): "m:\(sid)"
        case .sectionMore(let section, _): "sm:\(section.rawValue)"
        }
    }

    /// The drawn depth of a child row; nil for every other line.
    public var level: Int? {
        switch self {
        case .subagent(_, _, let level), .task(_, _, let level): level
        case .header, .session, .more, .sectionMore: nil
        }
    }
}

public enum SessionTree {
    /// Subagents shown per session before "+N more" (Q25).
    public static let childLimit = 2
    /// Done sessions shown before "Show N more" (D36).
    public static let doneLimit = 2

    /// The full list in sections: Needs you, Working, Done (newest first), each under a header
    /// and hidden when empty. Done shows `doneLimit` sessions until its section is expanded; an
    /// expanded section that had more keeps a `sectionMore(hidden: 0)` line to fold it again.
    /// Idle sessions with running children are pinned first in Done, newest first, and never count
    /// toward `doneLimit` (D41).
    public static func sectioned(
        _ sessions: [Session], expanded: Set<String> = [], expandedSections: Set<SessionSection> = []
    ) -> [TreeItem] {
        var out: [TreeItem] = []
        for section in SessionSection.allCases {
            let members = sessions.filter { SessionSection.of($0) == section }
            guard !members.isEmpty else { continue }
            out.append(.header(section, count: members.count))
            guard section == .done else { out += items(members, expanded: expanded); continue }
            let newestFirst: (Session, Session) -> Bool = {
                $0.statusChangedAt != $1.statusChangedAt ? $0.statusChangedAt > $1.statusChangedAt : $0.id < $1.id
            }
            let pinned = members.filter { $0.backgroundChildCount > 0 }.sorted(by: newestFirst)
            let rest = members.filter { $0.backgroundChildCount == 0 }.sorted(by: newestFirst)
            let open = expandedSections.contains(.done)
            let shown = open ? rest : Array(rest.prefix(doneLimit))
            out += items(pinned + shown, expanded: expanded)
            if rest.count > doneLimit { out.append(.sectionMore(.done, hidden: open ? 0 : rest.count - shown.count)) }
        }
        return out
    }

    /// Sessions in store order, each followed by its subagents and background tasks. Collapsed
    /// sessions show their first `childLimit` top-level children (subagents first, running first,
    /// then tasks oldest first); expanded ones show the whole tree, two levels deep, with deeper
    /// children under their nearest shown ancestor (D33, D41).
    public static func items(
        _ sessions: [Session], expanded: Set<String> = [], includeSubagents: Bool = true, includeTasks: Bool = true,
        runningOnly: Bool = false
    ) -> [TreeItem] {
        var out: [TreeItem] = []
        for session in sessions {
            out.append(.session(session))
            let agents = !includeSubagents ? [] : runningOnly ? session.subagents.filter { !$0.finished } : session.subagents
            let tree = children(agents, tasks: includeTasks ? session.backgroundTasks : [], sessionId: session.id)
            guard !tree.isEmpty else { continue }
            if expanded.contains(session.id) {
                out += tree
            } else {
                let top = tree.filter { $0.level == 1 }.prefix(childLimit)
                out += top
                if tree.count > top.count { out.append(.more(sessionId: session.id, hidden: tree.count - top.count)) }
            }
        }
        return out
    }

    /// Depth-first child rows, running subagents before finished ones, then oldest first, at every
    /// level. Under each subagent: its child subagents, then its tasks one level down, oldest first.
    /// Last, at level 1: the main session's tasks and those whose owner is not in `agents`.
    static func children(_ agents: [Subagent], tasks: [BackgroundTask], sessionId: String) -> [TreeItem] {
        let byId = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parent: [String: String] = [:]
        for agent in agents {
            guard let use = agent.toolUseId else { continue }
            if let owner = agents.first(where: { $0.id != agent.id && $0.spawnedToolUseIds.contains(use) }) {
                parent[agent.id] = owner.id
            }
        }
        func order(_ list: [Subagent]) -> [Subagent] {
            list.sorted {
                if $0.finished != $1.finished { return !$0.finished }
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id < $1.id
            }
        }
        let oldestFirst = tasks.sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }
        func hasShownOwner(_ task: BackgroundTask) -> Bool { task.ownerAgentId.map { byId[$0] != nil } ?? false }
        let owned = Dictionary(grouping: oldestFirst.filter(hasShownOwner)) { $0.ownerAgentId ?? "" }
        var out: [TreeItem] = []
        var visited = Set<String>()
        func walk(_ id: String, depth: Int) {
            guard let agent = byId[id], visited.insert(id).inserted else { return }
            out.append(.subagent(agent, sessionId: sessionId, level: min(depth, 2)))
            for child in order(agents.filter { parent[$0.id] == id }) { walk(child.id, depth: depth + 1) }
            for task in owned[id] ?? [] { out.append(.task(task, sessionId: sessionId, level: min(depth + 1, 2))) }
        }
        for root in order(agents.filter { parent[$0.id] == nil }) { walk(root.id, depth: 1) }
        for agent in order(agents) where !visited.contains(agent.id) { walk(agent.id, depth: 1) }   // cycles
        for task in oldestFirst where !hasShownOwner(task) {
            out.append(.task(task, sessionId: sessionId, level: 1))
        }
        return out
    }
}
