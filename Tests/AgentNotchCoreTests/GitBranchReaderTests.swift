import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct GitBranchReading {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readsStandardRepoAndSubdirectory() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
        let subDir = repo.appendingPathComponent("Sources/Core", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/antigravity-support\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        #expect(GitBranchReader.branch(forDirectory: repo.path) == "feat/antigravity-support")
        #expect(GitBranchReader.branch(forDirectory: subDir.path) == "feat/antigravity-support")
    }

    @Test func readsWorktreePointerFileAbsoluteAndRelative() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let actualGitDir = root.appendingPathComponent("main-repo/.git/worktrees/wt-1", isDirectory: true)
        try FileManager.default.createDirectory(at: actualGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/fix/worktree-branch\n".write(to: actualGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Absolute gitdir pointer
        let absWorktree = root.appendingPathComponent("wt-abs", isDirectory: true)
        try FileManager.default.createDirectory(at: absWorktree, withIntermediateDirectories: true)
        try "gitdir: \(actualGitDir.path)\n".write(to: absWorktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitBranchReader.branch(forDirectory: absWorktree.path) == "fix/worktree-branch")

        // Relative gitdir pointer
        let relWorktree = root.appendingPathComponent("wt-rel", isDirectory: true)
        try FileManager.default.createDirectory(at: relWorktree, withIntermediateDirectories: true)
        try "gitdir: ../main-repo/.git/worktrees/wt-1\n".write(to: relWorktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitBranchReader.branch(forDirectory: relWorktree.path) == "fix/worktree-branch")
    }

    @Test func shortensDetachedHeadShaAndDegradesOnInvalidInput() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "08dfdfb4e2c1a9f0123456789abcdef012345678\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        #expect(GitBranchReader.branch(forDirectory: repo.path) == "08dfdfb")
        #expect(GitBranchReader.parseHead("ref: refs/tags/v0.6.2\n") == "v0.6.2")
        #expect(GitBranchReader.parseHead("not a valid head\n") == nil)
        #expect(GitBranchReader.branch(forDirectory: "") == nil)
        #expect(GitBranchReader.branch(forDirectory: "/Users/dev/does-not-exist-\(UUID().uuidString)") == nil)
    }
}
