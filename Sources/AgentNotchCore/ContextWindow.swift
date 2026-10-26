import Foundation

/// How full a session's context is, against the point where Claude Code auto-compacts (D38).
public enum ContextLevel: Sendable, Equatable {
    case normal, warn, critical
}

/// Context-window math, the same formula as Claude Code's own status line (D38, F20, F21).
public enum ContextWindow {
    public static let oneMillion = 1_000_000
    public static let standard = 200_000
    /// Claude Code compacts at `window − compactBuffer` (F21).
    public static let compactBuffer = 33_000

    /// Model id prefixes from Claude Code 2.1.310 (F20). Update this table when Claude Code adds a model.
    static let table: [(prefix: String, window: Int)] = [
        ("claude-opus-5", oneMillion), ("claude-fable-5", oneMillion), ("claude-sonnet-5", oneMillion),
        ("claude-haiku-5-5", oneMillion), ("claude-opus-4-7", oneMillion), ("claude-opus-4-8", oneMillion),
        ("claude-opus-4-0", standard), ("claude-opus-4-1", standard), ("claude-opus-4-5", standard),
        ("claude-opus-4-6", standard), ("claude-sonnet-4", standard), ("claude-haiku-4-5", standard),
    ]

    /// Longest table prefix that ends on an id boundary, so `claude-opus-4-1` never matches
    /// `claude-opus-4-10`. A `[1m]` suffix selects the 1M window. Nil for unknown models.
    public static func window(forModel model: String?) -> Int? {
        guard let id = model?.lowercased(), !id.isEmpty else { return nil }
        let match = table
            .filter { entry in
                guard id.hasPrefix(entry.prefix) else { return false }
                guard let next = id.dropFirst(entry.prefix.count).first else { return true }
                return next == "-" || next == "["
            }
            .max { $0.prefix.count < $1.prefix.count }
        guard let match else { return nil }
        return id.hasSuffix("[1m]") ? oneMillion : match.window
    }

    /// `round(tokens / window × 100)`, clamped to 0…100.
    public static func percent(tokens: Int, window: Int) -> Int {
        guard window > 0 else { return 0 }
        let p = (Double(tokens) / Double(window) * 100).rounded()
        return Int(min(100, max(0, p)))
    }

    /// Amber from 75% of the compact point, red from 90%. Unknown windows stay normal.
    public static func level(tokens: Int, window: Int?) -> ContextLevel {
        guard let window else { return .normal }
        let t = clamp(tokens), compactPoint = clamp(max(1, window - compactBuffer))
        if t * 100 >= compactPoint * 90 { return .critical }
        if t * 100 >= compactPoint * 75 { return .warn }
        return .normal
    }

    /// `62%`, or a raw count (`412k`) when the window is unknown.
    public static func label(tokens: Int, window: Int?) -> String {
        if let window { return "\(percent(tokens: tokens, window: window))%" }
        let n = clamp(tokens)
        if n < 1_000 { return "\(n)" }
        if n < 999_500 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// R8: keeps `× 100` far from Int overflow whatever a transcript claims.
    static func clamp(_ n: Int) -> Int { min(max(0, n), 1 << 40) }
}

/// The context part of a session row: shown while working, waiting or idle, never on done
/// sessions, subagents or before the first reply (D38).
public struct ContextIndicator: Sendable, Equatable {
    /// `62%`, or `412k` for an unknown model.
    public var label: String
    public var level: ContextLevel

    public init(label: String, level: ContextLevel) { self.label = label; self.level = level }

    public static func of(_ session: Session) -> ContextIndicator? {
        guard session.status != .done, let tokens = session.contextTokens else { return nil }
        return ContextIndicator(
            label: ContextWindow.label(tokens: tokens, window: session.contextWindow),
            level: ContextWindow.level(tokens: tokens, window: session.contextWindow)
        )
    }
}
