import Foundation

/// D45: dot-separated numeric app version (same digits-and-dots rule as `scripts/bundle.sh`).
/// Strips a single leading `v`, compares component-wise with missing trailing components as 0
/// (`0.7 == 0.7.0`), and rejects pre-release tags or malformed inputs.
public struct AppVersion: Equatable, Comparable, Hashable, CustomStringConvertible, Sendable {
    public let components: [Int]
    public let description: String

    /// Normalized components with trailing zeros stripped so equal versions hash identically.
    private var normalized: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        return trimmed
    }

    public init?(_ string: String) {
        let body: Substring = string.hasPrefix("v") ? string.dropFirst() : string[...]
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(part)
            else {
                return nil
            }
            parsed.append(value)
        }
        self.components = parsed
        self.description = String(body)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalized == rhs.normalized
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}
