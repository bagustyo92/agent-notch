import AgentNotchCore
import AppKit
import SwiftUI

/// D34: one color and one motion per state, shared by every surface. Motion is the signal, not
/// decoration: only working and needs-you animate, and Reduce Motion stills both.
enum Palette {
    static let working = adaptive(dark: (0.38, 0.70, 1.0), light: (0.0, 0.42, 0.88))
    static let needsYou = Color.orange
    static let finished = adaptive(dark: (0.32, 0.84, 0.47), light: (0.10, 0.56, 0.24))
    /// A child still running after its parent's turn ended (D41). Static: it never animates.
    static let background = adaptive(dark: (0.69, 0.55, 1.0), light: (0.45, 0.27, 0.85))
    /// Context nearing auto-compact (D38): amber, then red.
    static let contextWarn = adaptive(dark: (1.0, 0.78, 0.20), light: (0.70, 0.47, 0.0))
    static let contextCritical = adaptive(dark: (1.0, 0.38, 0.36), light: (0.80, 0.13, 0.11))

    /// The notch is always dark; the dropdown follows the system, where light needs deeper tones.
    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension DisplayState {
    var color: Color {
        switch self {
        case .working: Palette.working
        case .needsYou: Palette.needsYou
        case .finished: Palette.finished
        case .idle: .secondary
        case .ended: .gray
        case .background: Palette.background
        }
    }
}

extension ContextLevel {
    /// Nil at normal: the context reads like the rest of the capsule.
    var color: Color? {
        switch self {
        case .normal: nil
        case .warn: Palette.contextWarn
        case .critical: Palette.contextCritical
        }
    }
}

/// Three dots rising in turn: the "working" signal (Q4). Core Animation runs the motion (D42);
/// `animated: false` and Reduce Motion draw the dots still.
struct WorkingDots: View {
    var color: Color = Palette.working
    var size: CGFloat = 4.5
    /// False for the menu bar item: macOS re-snapshots the whole item for every frame, ~20 ms each,
    /// whatever draws it (D42).
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if animated, !reduceMotion {
                DotsLayer(color: LayerMotion.cgColor(color, dark: colorScheme == .dark), size: size)
            } else {
                HStack(spacing: size * 0.6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(color)
                            .frame(width: size, height: size)
                            .opacity(0.35 + 0.65 * 0.7)
                            .offset(y: -size * 0.4 * 0.7)
                    }
                }
            }
        }
        .frame(width: size * 4.2, height: size * 1.8)
        .accessibilityElement()
        .accessibilityLabel("Working")
    }
}

/// A soft glow that breathes every two seconds: the "needs you" signal (Q4). Core Animation runs it
/// (D42); Reduce Motion holds it still.
struct BreathingGlow<Content: View>: View {
    let content: Content
    let color: Color
    var radius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceMotion {
            content.shadow(color: color.opacity(0.35 + 0.5 * 0.6), radius: radius * (0.4 + 0.6 * 0.6))
        } else {
            // SwiftUI sizes the hidden copy; the layer draws the content and its shadow in exactly that frame.
            content.hidden().overlay {
                GlowLayer(content: content.environment(\.colorScheme, colorScheme),
                          color: LayerMotion.cgColor(color, dark: colorScheme == .dark), radius: radius)
            }
        }
    }
}

extension View {
    func breathingGlow(_ color: Color, radius: CGFloat = 6) -> some View { BreathingGlow(content: self, color: color, radius: radius) }
}

/// The leading state mark of every row: a tinted disc holding the state's symbol or motion.
struct StateBadge: View {
    let state: DisplayState
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(state.color.opacity(state == .idle || state == .ended ? 0.10 : 0.17))
            switch state {
            case .working:
                WorkingDots(size: size * 0.15)
            case .needsYou:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Palette.needsYou)
                    .breathingGlow(Palette.needsYou, radius: size * 0.22)
            case .finished:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Palette.finished)
            case .idle:
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: size * 0.22, height: size * 0.22)
            case .ended:
                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.gray)
            case .background:
                Circle()                                        // a hollow ring, no motion (D34, D41)
                    .strokeBorder(Palette.background, lineWidth: max(1.5, size * 0.08))
                    .frame(width: size * 0.42, height: size * 0.42)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Text with a light band sweeping across it: the thinking verb (Q5). The text itself is SwiftUI;
/// Core Animation moves the band (D42).
struct ShimmerText: View {
    let text: String
    var color: Color = Palette.working
    var font: Font = .system(size: 11.5, weight: .medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let label = Text(text).font(font).lineLimit(1).truncationMode(.tail)
        if reduceMotion {
            label.foregroundStyle(color)
        } else {
            label
                .foregroundStyle(color.opacity(0.6))
                .overlay {
                    ShimmerLayer(content: label
                        .foregroundStyle(color)
                        .brightness(colorScheme == .dark ? 0.25 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .environment(\.colorScheme, colorScheme))
                    .accessibilityHidden(true)
                }
        }
    }
}

/// `Opus 5.5 · high · 62%`, sized to read at a glance (Q6). Only the trailing context label turns
/// amber or red (D38).
struct ModelCapsule: View {
    let text: String
    var context: ContextIndicator? = nil

    var body: some View {
        Text(styled)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.78))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .fixedSize()
    }

    private var styled: AttributedString {
        var s = AttributedString(text)
        if let context, let tint = context.level.color, let range = s.range(of: context.label, options: .backwards) {
            s[range].foregroundColor = tint
        }
        return s
    }
}

/// The phase-aware third line: verb while thinking, the tool or text line, the needs-you label, the
/// finished/idle/ended note, or `Background · <activity>` for a child of an idle parent (D29, D31,
/// D32, D41). An idle parent's line ends in `· N in background` when `backgroundCount > 0`.
struct PhaseLine: View {
    let id: String
    let state: DisplayState
    let activity: Activity?
    let hideDetails: Bool
    let now: Date
    var waitingFor: String? = nil
    var needs: String? = nil
    var finishedAt: Date? = nil
    var startedAt: Date? = nil
    var files = 0
    var unavailable = false
    var backgroundCount = 0
    var size: CGFloat = 11.5

    var body: some View {
        switch state {
        case .working(let phase):
            if phase == .thinking || activity == nil {
                ShimmerText(text: SpinnerVerbs.verb(for: id, at: now), font: .system(size: size, weight: .medium))
            } else if unavailable {
                plain("activity unavailable")
            } else if let activity {
                plain(hideDetails ? (phase == .writing ? "Writing…" : activity.brief) : activity.full, primary: true)
            }
        case .needsYou:
            HStack(spacing: 5) {
                Text(NeedsLabel.text(waitingFor: waitingFor))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Palette.needsYou)
                    .layoutPriority(1)                  // the detail truncates first
                if !hideDetails, let needs {
                    Text(needs).font(.system(size: size)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .lineLimit(1)
        case .finished:
            HStack(spacing: 4) {
                Text(FinishedLabel.text(finishedAt: finishedAt, startedAt: startedAt, files: files, now: now))
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Palette.finished.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                backgroundSuffix                            // keeps its width: the Finished text truncates first
            }
        case .idle:
            HStack(spacing: 4) {
                plain("Idle")
                backgroundSuffix
            }
        case .ended:
            plain("Ended")
        case .background:
            HStack(spacing: 4) {
                Text(BackgroundLabel.state)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Palette.background)
                    .layoutPriority(1)
                if let detail = BackgroundLabel.activity(activity, hideDetails: hideDetails) {
                    plain("· \(detail)")
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var backgroundSuffix: some View {
        if let suffix = BackgroundLabel.parentSuffix(count: backgroundCount) {
            Text(suffix)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.background)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private func plain(_ s: String, primary: Bool = false) -> some View {
        Text(s)
            .font(.system(size: size))
            .foregroundStyle(primary ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
