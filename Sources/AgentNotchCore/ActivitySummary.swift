import Foundation

/// Turns a tool_use block or a text block into the safe one-line activity (D11).
/// Risk area: secrets on screen and during screen share. Nothing here keeps the input.
public enum ActivitySummary {
    public static let maxLength = 80
    public static let textBrief = "Text"

    static let fileTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let describedTools: Set<String> = ["Agent", "Task"]

    public static func forToolUse(name: String, input: [String: Any]) -> Activity {
        let label = displayName(for: name)
        let detail: String?
        if name == "Bash" {
            detail = string(input["description"])                      // never input.command
        } else if fileTools.contains(name) {
            detail = (string(input["file_path"]) ?? string(input["notebook_path"])).map { ($0 as NSString).lastPathComponent }
        } else if describedTools.contains(name) {
            detail = string(input["description"])
        } else {
            detail = nil                                               // Grep/Glob/WebFetch/WebSearch/mcp/anything else
        }
        let full: String
        if let detail, !detail.isEmpty { full = finish("\(label) · \(detail)") } else { full = finish(label) }
        return Activity(full: full, brief: finish(label))
    }

    public static func forText(_ text: String) -> Activity? {
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first else { return nil }
        return Activity(full: finish(first), brief: textBrief)
    }

    /// `mcp__<server>__<tool>` → `<server> · <tool>`; everything else unchanged.
    static func displayName(for name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2, !parts[0].isEmpty else { return name }
        return "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))"
    }

    /// 1. 32+ char identifier-like runs → `•••`. 2. `password=…`, `token: …`, … → `<key>=•••`.
    public static func mask(_ s: String) -> String {
        var out = longTokens.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "•••")
        out = credentials.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1=•••")
        return out
    }

    /// Collapse whitespace, mask, then truncate to 80 characters (D11).
    public static func finish(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let masked = mask(collapsed)
        guard masked.count > maxLength else { return masked }
        return String(masked.prefix(maxLength - 1)) + "…"
    }

    private static func string(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let longTokens = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{32,}"#)
    private static let credentials = try! NSRegularExpression(
        pattern: #"(password|passwd|pwd|token|secret|api[_-]?key|authorization)\s*[=:]\s*\S+"#,
        options: [.caseInsensitive]
    )
}
