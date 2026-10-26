import Foundation

/// What a row shows, derived from status, phase and the last finished turn (D32).
public enum DisplayState: Sendable, Equatable {
    case working(Phase?)
    case needsYou
    case finished
    case idle
    case ended

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

    public static func of(_ subagent: Subagent) -> DisplayState {
        subagent.finished ? .finished : .working(subagent.phase)
    }

    public var isLive: Bool {
        switch self {
        case .working, .needsYou: true
        case .finished, .idle, .ended: false
        }
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

/// One line of a session list: a section header, a session, one of its subagents, "+N more"
/// subagents (D33, Q25), or "+N more" sessions of a section (D36).
public enum TreeItem: Identifiable, Sendable, Equatable {
    case header(SessionSection, count: Int)
    case session(Session)
    case subagent(Subagent, sessionId: String, level: Int)
    case more(sessionId: String, hidden: Int)
    case sectionMore(SessionSection, hidden: Int)

    public var id: String {
        switch self {
        case .header(let section, _): "h:\(section.rawValue)"
        case .session(let s): "s:\(s.id)"
        case .subagent(let a, let sid, _): "a:\(sid):\(a.id)"
        case .more(let sid, _): "m:\(sid)"
        case .sectionMore(let section, _): "sm:\(section.rawValue)"
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
    public static func sectioned(
        _ sessions: [Session], expanded: Set<String> = [], expandedSections: Set<SessionSection> = []
    ) -> [TreeItem] {
        var out: [TreeItem] = []
        for section in SessionSection.allCases {
            var members = sessions.filter { SessionSection.of($0) == section }
            guard !members.isEmpty else { continue }
            out.append(.header(section, count: members.count))
            guard section == .done else { out += items(members, expanded: expanded); continue }
            members.sort { $0.statusChangedAt != $1.statusChangedAt ? $0.statusChangedAt > $1.statusChangedAt : $0.id < $1.id }
            let open = expandedSections.contains(.done)
            let shown = open ? members : Array(members.prefix(doneLimit))
            out += items(shown, expanded: expanded)
            if members.count > doneLimit { out.append(.sectionMore(.done, hidden: open ? 0 : members.count - shown.count)) }
        }
        return out
    }

    /// Sessions in store order, each followed by its subagents. Collapsed sessions show their first
    /// `childLimit` top-level subagents (running first); expanded ones show the whole tree, two
    /// levels deep, with deeper agents under their nearest shown ancestor.
    public static func items(
        _ sessions: [Session], expanded: Set<String> = [], includeSubagents: Bool = true, runningOnly: Bool = false
    ) -> [TreeItem] {
        var out: [TreeItem] = []
        for session in sessions {
            out.append(.session(session))
            guard includeSubagents else { continue }
            let agents = runningOnly ? session.subagents.filter { !$0.finished } : session.subagents
            let tree = nested(agents)
            guard !tree.isEmpty else { continue }
            if expanded.contains(session.id) {
                out += tree.map { .subagent($0.agent, sessionId: session.id, level: $0.level) }
            } else {
                let top = tree.filter { $0.level == 1 }.prefix(childLimit)
                out += top.map { .subagent($0.agent, sessionId: session.id, level: 1) }
                if tree.count > top.count { out.append(.more(sessionId: session.id, hidden: tree.count - top.count)) }
            }
        }
        return out
    }

    /// Depth-first order: running before finished, then oldest first, at every level.
    static func nested(_ agents: [Subagent]) -> [(agent: Subagent, level: Int)] {
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
        var out: [(Subagent, Int)] = []
        var visited = Set<String>()
        func walk(_ id: String, depth: Int) {
            guard let agent = byId[id], visited.insert(id).inserted else { return }
            out.append((agent, min(depth, 2)))
            for child in order(agents.filter { parent[$0.id] == id }) { walk(child.id, depth: depth + 1) }
        }
        for root in order(agents.filter { parent[$0.id] == nil }) { walk(root.id, depth: 1) }
        for agent in order(agents) where !visited.contains(agent.id) { walk(agent.id, depth: 1) }   // cycles
        return out
    }
}
