import Foundation

/// Pure read-only `<cwd>/.git/HEAD` branch resolver (R1, R2, R7).
/// Handles standard `.git` directories, `.git` worktree/submodule pointer files,
/// symbolic branch refs and detached HEAD commits without spawning any subprocess.
public enum GitBranchReader {
    private static let maxReadBytes = 4096
    private static let maxParentHops = 16

    public static func branch(forDirectory cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let headURL = locateHead(startingAt: URL(fileURLWithPath: trimmed, isDirectory: true)) else { return nil }
        guard let content = readSmallUTF8(headURL) else { return nil }
        return parseHead(content)
    }

    static func parseHead(_ raw: String) -> String? {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return nil }
        if firstLine.hasPrefix("ref:") {
            let ref = firstLine.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { return nil }
            if ref.hasPrefix("refs/heads/") {
                let branch = String(ref.dropFirst("refs/heads/".count))
                return branch.isEmpty ? nil : branch
            }
            if ref.hasPrefix("refs/tags/") {
                let tag = String(ref.dropFirst("refs/tags/".count))
                return tag.isEmpty ? nil : tag
            }
            let last = (ref as NSString).lastPathComponent
            return last.isEmpty ? nil : last
        }
        // Detached HEAD: hexadecimal commit hash (7…64 hex chars) → 7-char short SHA.
        if firstLine.count >= 7, firstLine.count <= 64, firstLine.allSatisfy(\.isHexDigit) {
            return String(firstLine.prefix(7))
        }
        return nil
    }

    private static func locateHead(startingAt directory: URL) -> URL? {
        let fm = FileManager.default
        var current = directory.standardizedFileURL
        for _ in 0..<maxParentHops {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return dotGit.appendingPathComponent("HEAD")
                }
                if let gitDir = resolveGitDirPointer(dotGit, relativeTo: current) {
                    return gitDir.appendingPathComponent("HEAD")
                }
                return nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func resolveGitDirPointer(_ fileURL: URL, relativeTo repoDir: URL) -> URL? {
        guard let content = readSmallUTF8(fileURL) else { return nil }
        let line = content.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.lowercased().hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        }
        return repoDir.appendingPathComponent(target, isDirectory: true).standardizedFileURL
    }

    private static func readSmallUTF8(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxReadBytes), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
