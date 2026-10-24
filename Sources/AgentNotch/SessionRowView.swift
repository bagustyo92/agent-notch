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

extension Status {
    var label: String {
        switch self {
        case .waiting: "WAIT"
        case .working: "WORK"
        case .idle: "IDLE"
        case .done: "DONE"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .orange
        case .working: .blue
        case .idle: .secondary
        case .done: .gray
        }
    }
}

/// D10: the ONE row view shared by the notch and the dropdown (D21).
struct SessionRowView: View {
    static let height: CGFloat = 56

    let session: Session
    let hideDetails: Bool
    let now: Date
    var highlighted = false
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusChip(status: session.status)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(line1)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(session.repo)
                    Text("·")
                    Text(session.branch ?? "–")
                    Text("·")
                    Text(session.source.label)
                    Text("·")
                    Text(ElapsedFormatter.string(for: session, now: now)).monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(activityLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted ? Color.orange.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlighted ? Color.orange : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var line1: String {
        hideDetails ? "\(session.repo) · \(session.branch ?? "–")" : session.title
    }

    private var activityLine: String {
        if session.activityUnavailable { return "activity unavailable" }
        guard let activity = session.activity else { return session.status == .done ? "Done" : "—" }
        return hideDetails ? activity.brief : activity.full
    }
}

struct StatusChip: View {
    let status: Status

    var body: some View {
        Text(status.label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.color.opacity(0.22)))
            .foregroundStyle(status.color)
            .frame(width: 40)
    }
}

/// The row list used by both surfaces. Elapsed labels tick only while this view is on screen.
struct SessionListView: View {
    let store: SessionStore
    let settings: Settings
    var onlySessionId: String? = nil
    var highlightId: String? = nil
    let onMessage: (String) -> Void

    static let maxVisibleRows = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = onlySessionId.map { id in store.sessions.filter { $0.id == id } } ?? store.sessions
            if rows.isEmpty {
                Text("No Claude Code sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { session in
                            SessionRowView(
                                session: session, hideDetails: settings.hideDetails, now: context.date,
                                highlighted: session.id == highlightId
                            ) {
                                if let message = Focus.focus(session) { onMessage(message) }
                            }
                        }
                    }
                }
                .frame(height: Self.listHeight(rows: rows.count))
            }
        }
    }

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(max(1, min(rows, maxVisibleRows))) * (SessionRowView.height + 2)
    }
}
