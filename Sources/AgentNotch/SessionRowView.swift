import AgentNotchCore
import SwiftUI

extension Source {
    /// Plain text: an icon here read as a loading spinner.
    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .background: "Background"
        case .unknown: "Unknown"
        }
    }
}

/// Per-surface list state. A class, not `@State`: the CLT has no SwiftUI macro plugin (V1).
@MainActor
@Observable
final class ListUIState {
    var hoveredId: String?
    /// Sessions whose whole subagent tree is shown (Q25).
    var expanded: Set<String> = []
    /// Sections showing every session (D36).
    var expandedSections: Set<SessionSection> = []

    func reset() {
        hoveredId = nil
        expanded.removeAll()
        expandedSections.removeAll()
    }
}

/// Fixed heights, so the notch controller can size the panel before SwiftUI lays it out.
enum ListMetrics {
    static let sessionRow: CGFloat = 62
    static let subagentRow: CGFloat = 44
    static let moreRow: CGFloat = 24
    static let headerRow: CGFloat = 22
    static let spacing: CGFloat = 4
    static let maxHeight: CGFloat = 520

    static let stripSession: CGFloat = 30
    static let stripSubagent: CGFloat = 26
    static let stripMore: CGFloat = 20
    static let stripSpacing: CGFloat = 2
    static let stripSessionLimit = 3

    static func listHeight(_ items: [TreeItem]) -> CGFloat {
        guard !items.isEmpty else { return 44 }
        let rows = items.reduce(CGFloat(0)) { sum, item in
            switch item {
            case .header: sum + headerRow
            case .session: sum + sessionRow
            case .subagent: sum + subagentRow
            case .more, .sectionMore: sum + moreRow
            }
        }
        return min(maxHeight, rows + spacing * CGFloat(items.count - 1))
    }

    static func stripHeight(_ items: [TreeItem]) -> CGFloat {
        let rows = items.reduce(CGFloat(0)) { sum, item in
            switch item {
            case .session: sum + stripSession
            case .subagent: sum + stripSubagent
            case .more, .sectionMore: sum + stripMore
            case .header: sum
            }
        }
        return rows + stripSpacing * CGFloat(max(0, items.count - 1))
    }
}

/// D10: the ONE session row shared by the notch and the dropdown (D21).
struct SessionRowView: View {
    let session: Session
    let hideDetails: Bool
    let now: Date
    var highlighted = false
    var hovered = false
    let onTap: () -> Void

    var body: some View {
        let state = DisplayState.of(session, now: now)
        HStack(alignment: .center, spacing: 10) {
            StateBadge(state: state)
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(line1)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let capsule = ModelName.capsule(model: session.model, effort: session.effort) {
                        ModelCapsule(text: capsule)
                    }
                }
                Text(metaLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                PhaseLine(
                    id: session.id, state: state, activity: session.activity, hideDetails: hideDetails, now: now,
                    waitingFor: session.waitingFor, needs: session.needs, finishedAt: session.turnFinishedAt,
                    unavailable: session.activityUnavailable
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ListMetrics.sessionRow)
        .background(RowCard(state: state, highlighted: highlighted, hovered: hovered))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var line1: String {
        hideDetails ? "\(session.repo) · \(session.branch ?? "–")" : session.title
    }

    private var metaLine: String {
        let elapsed = ElapsedFormatter.string(for: session, now: now)
        if hideDetails { return "\(session.source.label) · \(elapsed)" }
        return "\(session.repo) · \(session.branch ?? "–") · \(session.source.label) · \(elapsed)"
    }
}

/// The raised card behind a row: a quiet fill that brightens on hover, tinted when it needs you.
struct RowCard: View {
    let state: DisplayState
    var highlighted = false
    var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let tint: Color = state == .needsYou || highlighted ? Palette.needsYou : .primary
        shape
            .fill(tint.opacity(state == .needsYou || highlighted ? 0.12 : (hovered ? 0.10 : 0.055)))
            .overlay(shape.strokeBorder(
                highlighted ? Palette.needsYou : tint.opacity(state == .needsYou ? 0.35 : 0.07),
                lineWidth: highlighted ? 1.5 : 0.5
            ))
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Thin elbow from the parent row down to a child (D33).
struct TreeConnector: View {
    let level: Int

    var body: some View {
        Canvas { context, size in
            let x = level == 1 ? 13.0 : 31.0
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height / 2 - 5))
            path.addQuadCurve(to: CGPoint(x: x + 6, y: size.height / 2), control: CGPoint(x: x, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.primary.opacity(0.22)), lineWidth: 1)
        }
        .frame(width: level == 1 ? 24 : 42)
    }
}

struct SubagentRowView: View {
    let agent: Subagent
    let level: Int
    let hideDetails: Bool
    let now: Date

    var body: some View {
        let state = DisplayState.of(agent)
        HStack(spacing: 6) {
            TreeConnector(level: level)
            StateBadge(state: state, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(agent.agentType)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !hideDetails, !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if let capsule = ModelName.capsule(model: agent.model, effort: agent.effort) {
                        ModelCapsule(text: capsule)
                    }
                }
                HStack(spacing: 6) {
                    if agent.finished {
                        Text("Done").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.finished.opacity(0.9))
                    } else {
                        PhaseLine(id: agent.id, state: state, activity: agent.activity, hideDetails: hideDetails, now: now, size: 11)
                    }
                    Spacer(minLength: 4)
                    Text(ElapsedFormatter.precise((agent.finishedAt ?? now).timeIntervalSince(agent.startedAt)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.trailing, 10)
        .frame(height: ListMetrics.subagentRow)
        .opacity(agent.finished ? 0.75 : 1)
    }
}

/// "+3 more agents" / "Show 4 more" / "Show fewer" (Q25, D36).
struct MoreRow: View {
    let label: String
    let expanded: Bool
    var leading: CGFloat = 34
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
            Text(expanded ? "Show fewer" : label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, leading)
        .frame(maxWidth: .infinity, minHeight: ListMetrics.moreRow, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// `✋ Needs you  1` above each group of the full list (D36).
struct SectionHeader: View {
    let section: SessionSection
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.15)))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .frame(height: ListMetrics.headerRow, alignment: .bottom)
    }

    private var title: String {
        switch section {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        }
    }

    private var symbol: String {
        switch section {
        case .needsYou: "hand.raised.fill"
        case .working: "ellipsis"
        case .done: "checkmark"
        }
    }

    private var color: Color {
        switch section {
        case .needsYou: Palette.needsYou
        case .working: Palette.working
        case .done: .secondary
        }
    }
}

/// The row list used by both surfaces: sessions with their subagent trees (D33).
/// Elapsed labels tick only while this view is on screen.
struct SessionListView: View {
    let store: SessionStore
    let settings: Settings
    let ui: ListUIState
    var highlightId: String? = nil
    let onMessage: (String) -> Void

    static func items(store: SessionStore, ui: ListUIState) -> [TreeItem] {
        var items = SessionTree.sectioned(store.sessions, expanded: ui.expanded, expandedSections: ui.expandedSections)
        // An expanded tree keeps a trailing "Show fewer" line.
        for id in ui.expanded.sorted() {
            guard let last = items.lastIndex(where: {
                if case .subagent(_, let sid, _) = $0 { return sid == id }
                return false
            }) else { continue }
            items.insert(.more(sessionId: id, hidden: 0), at: last + 1)
        }
        return items
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let items = Self.items(store: store, ui: ui)
            if items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "moon.zzz").font(.system(size: 16)).foregroundStyle(.secondary)
                    Text("No Claude Code sessions").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: ListMetrics.spacing) {
                        ForEach(items) { item in row(item, now: context.date) }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: ListMetrics.listHeight(items))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TreeItem, now: Date) -> some View {
        switch item {
        case .session(let session):
            SessionRowView(
                session: session, hideDetails: settings.hideDetails, now: now,
                highlighted: session.id == highlightId, hovered: ui.hoveredId == session.id
            ) {
                if let message = Focus.focus(session) { onMessage(message) }
            }
            .onHover { inside in
                if inside { ui.hoveredId = session.id } else if ui.hoveredId == session.id { ui.hoveredId = nil }
            }
        case .subagent(let agent, _, let level):
            SubagentRowView(agent: agent, level: level, hideDetails: settings.hideDetails, now: now)
        case .more(let sessionId, let hidden):
            let expanded = ui.expanded.contains(sessionId)
            MoreRow(label: "\(hidden) more agent\(hidden == 1 ? "" : "s")", expanded: expanded) {
                if expanded { ui.expanded.remove(sessionId) } else { ui.expanded.insert(sessionId) }
            }
        case .header(let section, let count):
            SectionHeader(section: section, count: count)
        case .sectionMore(let section, let hidden):
            let expanded = ui.expandedSections.contains(section)
            MoreRow(label: "Show \(hidden) more", expanded: expanded, leading: 12) {
                if expanded { ui.expandedSections.remove(section) } else { ui.expandedSections.insert(section) }
            }
        }
    }
}

/// The compact strip the notch opens on its own (Q10): live sessions only, one line each, with
/// their running subagents when enabled (Q21).
struct LiveStripView: View {
    let store: SessionStore
    let settings: Settings

    static func items(store: SessionStore, settings: Settings, now: Date) -> [TreeItem] {
        let live = store.liveSessions(now: now)
        var items = SessionTree.items(
            Array(live.prefix(ListMetrics.stripSessionLimit)), includeSubagents: settings.showSubagentsLive, runningOnly: true
        )
        if live.count > ListMetrics.stripSessionLimit {
            items.append(.more(sessionId: "", hidden: live.count - ListMetrics.stripSessionLimit))
        }
        return items
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: ListMetrics.stripSpacing) {
                ForEach(Self.items(store: store, settings: settings, now: context.date)) { item in
                    line(item, now: context.date)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ item: TreeItem, now: Date) -> some View {
        switch item {
        case .session(let session):
            let state = DisplayState.of(session, now: now)
            HStack(spacing: 8) {
                StateBadge(state: state, size: 20)
                Text(StripLabel.text(for: session, hideDetails: settings.hideDetails))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: session.aiTitle)
                PhaseLine(
                    id: session.id, state: state, activity: session.activity, hideDetails: settings.hideDetails, now: now,
                    waitingFor: session.waitingFor, needs: session.needs, finishedAt: session.turnFinishedAt, size: 12
                )
                Spacer(minLength: 6)
                Text(ElapsedFormatter.precise(now.timeIntervalSince(session.statusChangedAt)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(height: ListMetrics.stripSession)
        case .subagent(let agent, _, _):
            let state = DisplayState.of(agent)
            HStack(spacing: 6) {
                TreeConnector(level: 1).frame(width: 22)
                StateBadge(state: state, size: 16)
                Text(agent.agentType)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                PhaseLine(id: agent.id, state: state, activity: agent.activity, hideDetails: settings.hideDetails, now: now, size: 11.5)
                Spacer(minLength: 6)
                Text(ElapsedFormatter.precise(now.timeIntervalSince(agent.startedAt)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(height: ListMetrics.stripSubagent)
        case .more(let sessionId, let hidden):
            Text(sessionId.isEmpty ? "+\(hidden) more session\(hidden == 1 ? "" : "s")" : "+\(hidden) more agent\(hidden == 1 ? "" : "s")")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, sessionId.isEmpty ? 28 : 50)
                .frame(maxWidth: .infinity, minHeight: ListMetrics.stripMore, alignment: .leading)
        case .header, .sectionMore:
            EmptyView()
        }
    }
}
