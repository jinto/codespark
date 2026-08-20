# Remote (ssh) Worktree Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 원격(ssh) 프로젝트도 로컬 프로젝트와 동등하게 워크트리를 스캔해 사이드바에 펼치고, 그 워크트리에서 탭을 열고, 원격 워크트리를 만들고 지운다.

**Architecture:** 원격 워크트리의 주소는 `ssh://user@host/remote/path` URI다 — `workspacePath`가 이미 문자열 하나로 탭의 소속을 정하는 키이므로, 같은 문자열 공간에 원격 워크트리를 넣으면 그룹핑·선택·복원·삭제 로직이 그대로 동작한다. URI ↔ 원격 raw 경로 변환은 `SSHConnectionInfo` 한 곳에만 두고, git 인자에는 절대 URI를 넘기지 않는다. 스캔 분기는 `GitWorktreeService.fetchWorktrees(at:)` 한 곳에서만 일어난다.

**Tech Stack:** Swift 5 / SwiftUI / XCTest, `Foundation.Process`로 `/usr/bin/git`·`/usr/bin/ssh` 실행, Ghostty(GhosttyKit) 터미널 엔진.

**Spec:** `docs/superpowers/specs/2026-08-20-remote-worktree-scan-design.md`

## Global Constraints

- 워크스페이스 주소(= `SessionViewData.workspacePath`, `GitWorktree.path`, `WorkspaceViewData.path`)는 원격의 경우 **항상 `ssh://` URI**다. 원격 raw 경로가 이 자리에 들어가면 안 된다.
- git 명령 인자(`-C`, `worktree add`, `worktree remove`)에는 **항상 원격 raw 경로**가 들어간다. URI가 들어가면 안 된다.
- URI 생성·분해는 `SSHConnectionInfo`의 `workspaceURI(forRemotePath:)` / `remotePath(fromWorkspaceURI:)` **두 함수 밖에서 하지 않는다**.
- 원격 ssh 호출 옵션은 항상 `-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2`. 백그라운드 스캔이 비밀번호 프롬프트에 매달리면 안 된다.
- `ControlMaster`/`ControlPersist`는 쓰지 않는다.
- 원격 경로를 원격 셸에 넘길 때는 반드시 `SSHConnectionInfo.shellQuoted(_:)`를 통과시킨다. 단 tilde(`~`)를 전개해야 하는 자리는 예외이며 `remoteRootExpression(_:)`이 담당한다.
- 테스트 명령: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests`
  - 단일 테스트: 위 명령에 `-only-testing:CodeSparkTests/<Suite>/<test_name>` 을 붙인다.
- 기존 유닛 테스트 192개는 전부 그린을 유지한다 (6개는 sshd 미기동으로 skip).
- pre-commit 훅이 커밋마다 빌드 + 유닛 테스트를 돌린다. 커밋이 30초쯤 걸리는 것은 정상이다.

---

## File Structure

| 파일 | 책임 | 변경 |
|---|---|---|
| `apps/macos/CodeSpark/Services/SSHConnectionInfo.swift` | ssh 연결 정보 + **URI ↔ 원격 경로 변환의 유일한 출처** | 수정 |
| `apps/macos/CodeSpark/Services/GitWorktreeService.swift` | 워크트리 조회/생성/삭제. 로컬·원격 분기가 여기 한 곳 | 수정 |
| `apps/macos/CodeSpark/Models/AppModel.swift` | 스캔 게이트, 워크스페이스 선택, 새 탭, add/remove, visitingBranch | 수정 |
| `apps/macos/CodeSpark/Views/AddWorktreeSheet.swift` | 생성 시트의 경로 미리보기 | 수정 |
| `apps/macos/CodeSparkTests/SSHConnectionInfoTests.swift` | URI 변환·argv 테스트 | 수정 |
| `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift` | 원격 스캔·생성·삭제 (스텁 ssh) | **신규** |
| `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift` | 워크스페이스 선택/그룹핑 회귀 + 신규 케이스 | 수정 |
| `apps/macos/CodeSparkTests/SSHIntegrationTests.swift` | 실제 localhost sshd 왕복 | 수정 |

`GitWorktreeService.swift`는 현재 261줄이고 원격 경로가 붙으면 400줄에 가까워진다. 그래도 "워크트리를 조회/생성/삭제한다"는 책임 하나이고 로컬·원격이 같은 파서와 캐시를 공유하므로 쪼개지 않는다. 파일을 나누면 오히려 "분기는 한 곳"이라는 이 설계의 핵심 보장이 흐려진다.

---

### Task 1: URI ↔ 원격 경로 변환

원격 워크트리 주소 체계의 토대. 이후 모든 태스크가 이 두 함수를 쓴다.

**Files:**
- Modify: `apps/macos/CodeSpark/Services/SSHConnectionInfo.swift`
- Test: `apps/macos/CodeSparkTests/SSHConnectionInfoTests.swift`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces:
  - `func workspaceURI(forRemotePath remotePath: String) -> String`
  - `static func remotePath(fromWorkspaceURI uri: String) -> String?`
  - `static func canonicalRemotePath(_ path: String) -> String`
  - `static func shellQuoted(_ value: String) -> String` (기존 `private` → `internal`로 승격)

- [ ] **Step 1: Write the failing tests**

`apps/macos/CodeSparkTests/SSHConnectionInfoTests.swift` 맨 아래, 마지막 `}` 직전에 추가:

```swift
    // MARK: - Workspace addressing

    // A worktree on the other machine has to be addressable in the same string
    // space as the project itself — `workspacePath` is one column, and it is
    // what grouping, selection, restore, and removal all compare.

    func test_workspace_uri_carries_the_connection_authority() {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222, remotePath: "/srv/repo")
        XCTAssertEqual(
            info.workspaceURI(forRemotePath: "/srv/worktrees/repo-feat-ab12"),
            "ssh://jay@box:2222/srv/worktrees/repo-feat-ab12"
        )
    }

    func test_workspace_uri_round_trips_to_the_remote_path() {
        let info = SSHConnectionInfo(host: "box", remotePath: "/srv/repo")
        let uri = info.workspaceURI(forRemotePath: "/srv/wt/a b")
        XCTAssertEqual(SSHConnectionInfo.remotePath(fromWorkspaceURI: uri), "/srv/wt/a b")
    }

    // A local workspace path answers nil, which is how callers tell the two
    // namespaces apart without a second flag.
    func test_local_paths_have_no_remote_path() {
        XCTAssertNil(SSHConnectionInfo.remotePath(fromWorkspaceURI: "/Users/jay/projects/codespark"))
    }

    // Two spellings of one directory would be two different workspaces, and a
    // tab keyed to the wrong spelling answers to no row at all.
    func test_trailing_slash_is_not_a_different_worktree() {
        let info = SSHConnectionInfo(host: "box")
        XCTAssertEqual(
            info.workspaceURI(forRemotePath: "/srv/wt/repo/"),
            info.workspaceURI(forRemotePath: "/srv/wt/repo")
        )
    }

    func test_root_survives_canonicalization() {
        XCTAssertEqual(SSHConnectionInfo.canonicalRemotePath("/"), "/")
    }

    func test_shell_quoting_survives_an_apostrophe() {
        XCTAssertEqual(SSHConnectionInfo.shellQuoted("/srv/it's here"), "'/srv/it'\\''s here'")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests/SSHConnectionInfoTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `value of type 'SSHConnectionInfo' has no member 'workspaceURI'`.

- [ ] **Step 3: Implement**

`SSHConnectionInfo.swift`에서 기존 `private static func shellQuoted`의 `private`를 지운다:

```swift
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
```

그리고 `var displayLabel` 바로 위에 추가:

```swift
    // MARK: - Workspace addressing

    /// This connection's spelling of a remote directory, for use as a
    /// `workspacePath`.
    ///
    /// A tab's workspace is one string, and that one string is what grouping,
    /// selection memory, restore, and worktree removal all compare. Remote
    /// worktrees join the same string space as the project URI rather than
    /// getting a namespace of their own, so none of that machinery has to learn
    /// about hosts.
    func workspaceURI(forRemotePath remotePath: String) -> String {
        var addressed = self
        addressed.remotePath = Self.canonicalRemotePath(remotePath)
        return addressed.uri
    }

    /// The remote directory inside a workspace address, or nil when the address
    /// is a local filesystem path. The nil is the caller's cue about which
    /// namespace it is holding — remote paths must never reach local file APIs,
    /// and URIs must never reach `git -C`.
    static func remotePath(fromWorkspaceURI uri: String) -> String? {
        SSHConnectionInfo(uri: uri)?.remotePath
    }

    /// One directory, one spelling. A trailing slash would otherwise mint a
    /// second workspace that no tab is keyed to.
    static func canonicalRemotePath(_ path: String) -> String {
        guard path != "/" else { return path }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command.
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/SSHConnectionInfo.swift apps/macos/CodeSparkTests/SSHConnectionInfoTests.swift
git commit -m "feat: address remote directories as workspace URIs"
```

---

### Task 2: 원격 워크트리 조회

**Files:**
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift`
- Create: `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`

**Interfaces:**
- Consumes: `SSHConnectionInfo.workspaceURI(forRemotePath:)`, `SSHConnectionInfo.shellQuoted(_:)` (Task 1)
- Produces:
  - `static var sshExecutablePath: String` (기본 `/usr/bin/ssh`, 테스트가 스텁으로 교체)
  - `static func remoteSSHArguments(_ info: SSHConnectionInfo, remoteCommand: String) -> [String]`
  - `static func remoteWorktreeListCommand(repoPath: String) -> String`
  - `fetchWorktrees(at:)`가 ssh URI를 받으면 원격으로 간다

- [ ] **Step 1: Write the failing test**

Create `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`:

```swift
import XCTest
@testable import CodeSpark

/// Remote worktree lookups, driven through a stub `ssh` so they run without a
/// server. The stub records its argv and prints canned porcelain output.
final class RemoteWorktreeScanTests: XCTestCase {

    private var stubDirectory: URL!
    private var originalSSHPath: String!

    override func setUpWithError() throws {
        originalSSHPath = GitWorktreeService.sshExecutablePath
        stubDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-remote-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        GitWorktreeService.sshExecutablePath = originalSSHPath
        try? FileManager.default.removeItem(at: stubDirectory)
    }

    /// Installs a stub at `<tmp>/ssh` that writes its argv to `argv.txt` and
    /// prints `stdout`, then points the service at it.
    @discardableResult
    private func installStubSSH(stdout: String, exitCode: Int = 0) throws -> URL {
        let argvFile = stubDirectory.appendingPathComponent("argv.txt")
        let stub = stubDirectory.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > '\(argvFile.path)'
        cat <<'STUB_EOF'
        \(stdout)
        STUB_EOF
        exit \(exitCode)
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        GitWorktreeService.sshExecutablePath = stub.path
        return argvFile
    }

    private func recordedArgv(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - argv

    func test_remote_lookup_never_prompts_for_a_password() {
        let info = SSHConnectionInfo(host: "box")
        let argv = GitWorktreeService.remoteSSHArguments(info, remoteCommand: "true")
        XCTAssertTrue(argv.contains("BatchMode=yes"), "argv was \(argv)")
        XCTAssertTrue(argv.contains("ConnectTimeout=5"), "argv was \(argv)")
    }

    func test_remote_lookup_carries_user_and_port() {
        let info = SSHConnectionInfo(host: "box", user: "jay", port: 2222)
        let argv = GitWorktreeService.remoteSSHArguments(info, remoteCommand: "true")
        XCTAssertTrue(argv.contains("jay@box"), "argv was \(argv)")
        XCTAssertEqual(argv[argv.firstIndex(of: "-p")! + 1], "2222")
    }

    /// The remote side runs this through a shell, so a path with a space or an
    /// apostrophe has to survive as one word — a comparison of command strings
    /// would never catch this.
    func test_repo_path_survives_the_remote_shell_as_one_word() {
        let command = GitWorktreeService.remoteWorktreeListCommand(repoPath: "/srv/it's here")
        XCTAssertEqual(command, "git -C '/srv/it'\\''s here' worktree list --porcelain")
    }

    // MARK: - Scanning

    func test_remote_worktrees_come_back_addressed_as_uris() async throws {
        try installStubSSH(stdout: """
        worktree /srv/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /srv/wt/repo-feat-ab12
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat
        """)

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://jay@box/srv/repo"])

        let worktrees = try XCTUnwrap(service.worktrees(for: "ssh://jay@box/srv/repo"))
        XCTAssertEqual(worktrees.map(\.path), [
            "ssh://jay@box/srv/repo",
            "ssh://jay@box/srv/wt/repo-feat-ab12",
        ])
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feat"])
        XCTAssertTrue(worktrees[0].isMainWorktree)
    }

    func test_the_scan_asks_the_right_host_for_the_right_repo() async throws {
        let argvFile = try installStubSSH(stdout: """
        worktree /srv/repo
        branch refs/heads/main
        """)

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://jay@box:2222/srv/repo"])

        let argv = try recordedArgv(argvFile)
        XCTAssertTrue(argv.contains("jay@box"), "argv was \(argv)")
        XCTAssertTrue(argv.contains("git -C '/srv/repo' worktree list --porcelain"), "argv was \(argv)")
    }

    /// Without a remote path there is no way to know where the repository is,
    /// and guessing costs a connection on every poll.
    func test_a_project_without_a_remote_path_is_not_scanned() async throws {
        let argvFile = try installStubSSH(stdout: "")

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: ["ssh://box"])

        XCTAssertNil(service.worktrees(for: "ssh://box"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: argvFile.path), "ssh should not have run")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests/RemoteWorktreeScanTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `type 'GitWorktreeService' has no member 'sshExecutablePath'`.

- [ ] **Step 3: Implement**

`GitWorktreeService.swift`의 `static let defaultWorktreeRoot` 아래에 추가:

```swift
    /// Overridden by tests so remote lookups can be exercised without a server.
    static var sshExecutablePath = "/usr/bin/ssh"

    /// A background poll must never block on a prompt, and `ConnectTimeout`
    /// only covers getting connected — `ServerAlive*` is what notices a session
    /// that went quiet after that.
    static let remoteSSHOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=2",
    ]

    /// Ceiling for one remote lookup, in case the connection lives but the
    /// remote git does not answer.
    private static let remoteTimeout: TimeInterval = 20
```

`// MARK: - Parsing` 바로 위에 추가:

```swift
    // MARK: - Remote git

    static func remoteSSHArguments(_ info: SSHConnectionInfo, remoteCommand: String) -> [String] {
        var argv = remoteSSHOptions
        if let port = info.port { argv.append(contentsOf: ["-p", "\(port)"]) }
        if let user = info.user {
            argv.append("\(user)@\(info.host)")
        } else {
            argv.append(info.host)
        }
        argv.append(remoteCommand)
        return argv
    }

    /// The remote side hands this to a shell, so the repository path has to
    /// survive as a single word.
    static func remoteWorktreeListCommand(repoPath: String) -> String {
        "git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree list --porcelain"
    }
```

`fetchWorktrees(at:)`의 첫 줄에 분기를 넣는다:

```swift
    private static func fetchWorktrees(at path: String) async -> (String, [GitWorktree]?) {
        // The one place local and remote part ways. Everything downstream —
        // cache, parser, grouping — sees the same shapes either way.
        if let info = SSHConnectionInfo(uri: path) {
            guard let repoPath = info.remotePath else { return (path, nil) }
            return (path, await fetchRemoteWorktrees(info: info, repoPath: repoPath))
        }
        // ... 기존 로컬 구현 그대로
```

같은 파일 맨 아래, 마지막 `}` 직전에 추가:

```swift
    private static func fetchRemoteWorktrees(
        info: SSHConnectionInfo,
        repoPath: String
    ) async -> [GitWorktree]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = remoteSSHArguments(
            info,
            remoteCommand: remoteWorktreeListCommand(repoPath: repoPath)
        )
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let deadline = Task {
                try await Task.sleep(nanoseconds: UInt64(remoteTimeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
            defer { deadline.cancel() }
            // Read before waiting: a process that outgrows the pipe buffer
            // blocks until someone drains it.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let exitStatus: Int32 = await withCheckedContinuation { cont in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            }
            guard exitStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
            // Remote git answers in its own filesystem's terms; the app speaks
            // workspace addresses.
            let worktrees = parseWorktreeList(output).map { worktree in
                GitWorktree(
                    path: info.workspaceURI(forRemotePath: worktree.path),
                    branch: worktree.branch,
                    isMainWorktree: worktree.isMainWorktree
                )
            }
            return worktrees.isEmpty ? nil : worktrees
        } catch {
            return nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command.
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift
git commit -m "feat: scan worktrees over ssh"
```

---

### Task 3: 스캔 게이트 열기 + 동시 실행 제한

조회는 되지만 아무도 부르지 않는 상태를 푼다. **게이트가 두 겹이다** — 하나만 열면 원격 스캔은 영영 실행되지 않는다.

**Files:**
- Modify: `apps/macos/CodeSpark/Models/AppModel.swift` (`worktreeProjectPaths` ~1014-1020, `selectProject` ~210)
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift` (`refreshWorktrees`)
- Test: `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`

**Interfaces:**
- Consumes: Task 2의 원격 조회
- Produces: `AppModel.worktreeProjectPaths`가 스캔 가능한 ssh 프로젝트를 포함한다

- [ ] **Step 1: Write the failing tests**

`RemoteWorktreeScanTests.swift`의 마지막 `}` 직전에 추가:

```swift
    // MARK: - Concurrency

    /// One slow host must not hold up the others, but neither should every
    /// project on the list spawn an ssh at once.
    func test_lookups_run_no_more_than_four_at_a_time() async throws {
        let counterFile = stubDirectory.appendingPathComponent("live.txt")
        let peakFile = stubDirectory.appendingPathComponent("peak.txt")
        let stub = stubDirectory.appendingPathComponent("ssh")
        // Each run appends a mark, sleeps, then records the high-water mark.
        let script = """
        #!/bin/sh
        printf 'x' >> '\(counterFile.path)'
        live=$(wc -c < '\(counterFile.path)' | tr -d ' ')
        peak=$(cat '\(peakFile.path)' 2>/dev/null || echo 0)
        [ "$live" -gt "$peak" ] && printf '%s' "$live" > '\(peakFile.path)'
        sleep 0.4
        printf '%s' "$(cat '\(counterFile.path)' | sed 's/x//')" > '\(counterFile.path)'
        echo 'worktree /srv/repo'
        echo 'branch refs/heads/main'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        GitWorktreeService.sshExecutablePath = stub.path

        let service = GitWorktreeService()
        await service.refreshWorktrees(for: (1...8).map { "ssh://box/srv/repo\($0)" })

        let peak = Int(try String(contentsOf: peakFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(peak, 0, "the stub never ran")
        XCTAssertLessThanOrEqual(peak, 4, "ran \(peak) ssh processes at once")
    }
```

`apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    // MARK: - Remote projects are scanned

    /// Two gates gate this: the path list and the call site in `selectProject`.
    /// Opening only one leaves remote scanning dead with no visible symptom.
    @MainActor
    func test_remote_projects_with_a_path_are_offered_for_scanning() {
        let model = AppModel(core: MockProjectCoreClient(), terminalFactory: { _ in MockTerminalHost(session: $0) })
        model.projects = [
            ProjectSummaryViewData(id: "local", name: "local", path: "/tmp/local", transport: "local",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
            ProjectSummaryViewData(id: "remote", name: "remote", path: "ssh://jay@box/srv/repo", transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
            ProjectSummaryViewData(id: "pathless", name: "pathless", path: "ssh://box", transport: "ssh",
                                   liveSessions: 0, recentlyClosedSessions: 0,
                                   hasInterruptedSessions: false, liveSessionDetails: []),
        ]

        XCTAssertEqual(model.worktreeProjectPaths.sorted(), ["/tmp/local", "ssh://jay@box/srv/repo"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/RemoteWorktreeScanTests/test_lookups_run_no_more_than_four_at_a_time \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_remote_projects_with_a_path_are_offered_for_scanning 2>&1 | tail -20
```
Expected: 두 테스트 모두 FAIL — 경로 목록은 `["/tmp/local"]`만 내고, 동시 실행은 8까지 올라간다.

- [ ] **Step 3: Implement**

`AppModel.swift`의 `worktreeProjectPaths`를 교체:

```swift
    /// Every project the sidebar can draw worktrees for. `refreshWorktrees`
    /// prunes whatever it is not given, so each refresh has to name them all or
    /// the projects that are merely open lose their rows.
    ///
    /// A remote project qualifies once its URI says where the repository is; a
    /// bare `ssh://host` does not, and guessing would cost a connection on
    /// every poll.
    var worktreeProjectPaths: [String] {
        projects.compactMap { project in
            guard !project.path.isEmpty else { return nil }
            guard project.transport == "ssh" else { return project.path }
            guard let info = SSHConnectionInfo(uri: project.path), info.remotePath != nil else { return nil }
            return project.path
        }
    }
```

`AppModel.swift:210`의 refresh 게이트를 교체:

```swift
                if worktreeProjectPaths.contains(detail.path) {
                    gitWorktreeService.invalidateCache(for: detail.path)
                    await gitWorktreeService.refreshWorktrees(for: worktreeProjectPaths)
                    recomputeWorkspaces()
                }
```

`GitWorktreeService.swift`에 상수를 추가한다 (`remoteTimeout` 아래):

```swift
    /// A poll over several remote projects should not open one connection per
    /// project all at once.
    private static let maxConcurrentLookups = 4
```

`refreshWorktrees`의 task group을 교체:

```swift
        await withTaskGroup(of: (String, [GitWorktree]?).self) { group in
            var pending = Array(stale)
            var next = 0
            while next < pending.count && next < Self.maxConcurrentLookups {
                let path = pending[next]
                group.addTask { await Self.fetchWorktrees(at: path) }
                next += 1
            }
            for await (path, result) in group {
                cache[path] = CacheEntry(
                    worktrees: result,
                    fetchedAt: Date(),
                    ttl: result != nil ? normalTTL : failureTTL
                )
                if next < pending.count {
                    let queued = pending[next]
                    group.addTask { await Self.fetchWorktrees(at: queued) }
                    next += 1
                }
            }
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Models/AppModel.swift apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSparkTests
git commit -m "feat: scan remote projects, four connections at a time"
```

---

### Task 4: 조회에 실패해도 화면을 비우지 않는다

원격은 일상적으로 끊긴다. 이 태스크가 이 기능의 본체다.

**Files:**
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift` (`refreshWorktrees`)
- Test: `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`

**Interfaces:**
- Consumes: Task 3의 스캔
- Produces: 실패한 조회가 직전 성공 목록을 지우지 않는다

- [ ] **Step 1: Write the failing test**

`WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// A lookup that fails is not a worktree that vanished. Dropping the list
    /// regroups every tab under one workspace, and the selection — still
    /// standing on a linked worktree — then matches no row: `visibleSessions`
    /// empties and the main area goes blank while the shells are all fine.
    @MainActor
    func test_a_failed_lookup_keeps_the_worktrees_it_already_found() async {
        let service = GitWorktreeService()
        service.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo")

        // Point at a stub that always fails, and expire the cache so the next
        // refresh actually re-runs the lookup.
        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"
        service.expireCacheForTesting()

        await service.refreshWorktrees(for: ["ssh://box/srv/repo"])

        XCTAssertEqual(
            service.worktrees(for: "ssh://box/srv/repo")?.map(\.branch),
            ["main", "feat"],
            "a failed lookup discarded the rows it had"
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_a_failed_lookup_keeps_the_worktrees_it_already_found 2>&1 | tail -20
```
Expected: 컴파일 실패 — `expireCacheForTesting` 없음. 추가 후에는 FAIL — 결과가 nil.

- [ ] **Step 3: Implement**

`GitWorktreeService.swift`의 `primeCache` 아래에 추가:

```swift
    /// Ages every entry past its TTL so the next refresh re-runs the lookup.
    /// Only tests call this.
    func expireCacheForTesting() {
        cache = cache.mapValues {
            CacheEntry(worktrees: $0.worktrees, fetchedAt: .distantPast, ttl: 0)
        }
    }
```

`refreshWorktrees`의 결과 저장부를 교체 (Task 3에서 넣은 두 군데 중 `cache[path] = ...` 한 곳):

```swift
            for await (path, result) in group {
                // A failure is "we could not ask", not "the worktrees are gone".
                // Keeping the last good answer is what stops a dropped
                // connection from regrouping every tab and blanking the main
                // area for the length of the failure TTL.
                cache[path] = CacheEntry(
                    worktrees: result ?? cache[path]?.worktrees,
                    fetchedAt: Date(),
                    ttl: result != nil ? normalTTL : failureTTL
                )
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift
git commit -m "fix: a failed worktree lookup keeps the rows it already had"
```

---

### Task 5: 선택은 존재하는 워크스페이스를 가리킨다

원격 리포의 canonical 루트가 프로젝트 URI와 다를 수 있다 (`ssh://box/srv/repo/subdir`, trailing slash 등).

**Files:**
- Modify: `apps/macos/CodeSpark/Models/AppModel.swift` (`apply(detail:)` ~240-250)
- Test: `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`

**Interfaces:**
- Consumes: Task 3의 스캔
- Produces: `apply(detail:)`이 프로젝트 경로가 워크스페이스가 아닐 때 메인 워크트리로 떨어진다

- [ ] **Step 1: Write the failing test**

`WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// The project URI is where the user pointed; the worktree list is what git
    /// says. When they disagree — a URI into a subdirectory, or a trailing
    /// slash — falling back to the project path selects a workspace that does
    /// not exist, and the main area goes blank.
    @MainActor
    func test_a_project_uri_that_is_not_a_worktree_lands_on_the_main_worktree() async {
        let core = MockProjectCoreClient()
        let model = AppModel(core: core, terminalFactory: { MockTerminalHost(session: $0) })
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo/apps")

        model.apply(detail: ProjectDetailViewData(
            id: "p1",
            name: "remote",
            path: "ssh://box/srv/repo/apps",
            transport: "ssh",
            liveSessions: []
        ))

        XCTAssertEqual(model.activeWorkspacePath, "ssh://box/srv/repo")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_a_project_uri_that_is_not_a_worktree_lands_on_the_main_worktree 2>&1 | tail -20
```
Expected: FAIL — `("ssh://box/srv/repo/apps") is not equal to ("ssh://box/srv/repo")`.

Note: `apply(detail:)`가 `private`이면 `internal`로 낮춘다 (`@testable import`는 `private`을 보지 못한다).

- [ ] **Step 3: Implement**

`AppModel.swift`의 `apply(detail:)` 끝부분을 교체:

```swift
        // Reopening a project lands on the worktree it was left in. The project
        // path is only the starting point — and it is not always a worktree at
        // all: a remote URI can point inside the repository, while git names
        // the canonical root. Selecting a path no workspace has empties
        // `visibleSessions` and blanks the main area, so fall through to the
        // main worktree instead of trusting the project path.
        let remembered = projectSelectedWorkspaces[detail.id]
        if let remembered, workspaces.contains(where: { $0.path == remembered }) {
            activeWorkspacePath = remembered
        } else if workspaces.contains(where: { $0.path == detail.path }) {
            activeWorkspacePath = detail.path
        } else {
            activeWorkspacePath = workspaces.first(where: \.isMainWorktree)?.path
                ?? workspaces.first?.path
                ?? detail.path
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Models/AppModel.swift apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift
git commit -m "fix: land on the main worktree when the project path is not one"
```

---

### Task 6: 새 탭은 보고 있는 원격 워크트리에서 열린다

**Files:**
- Modify: `apps/macos/CodeSpark/Models/AppModel.swift` (`newSession`, ssh 분기 ~568-590)
- Test: `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`

**Interfaces:**
- Consumes: `SSHConnectionInfo.remotePath(fromWorkspaceURI:)` (Task 1)
- Produces: ssh 탭의 `workspacePath`가 활성 워크스페이스 URI가 된다

- [ ] **Step 1: Write the failing test**

`WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// The tab bar is scoped to one worktree, so a tab opened from it belongs
    /// there — and on a remote project that also means the shell has to start
    /// in that directory on the other machine.
    @MainActor
    func test_a_new_remote_tab_belongs_to_the_worktree_on_screen() async {
        let core = MockProjectCoreClient()
        var created: [MockTerminalHost] = []
        let model = AppModel(core: core, terminalFactory: { session in
            let host = MockTerminalHost(session: session)
            created.append(host)
            return host
        })
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo")
        model.selectedProjectID = "p1"
        model.selectedProject = ProjectDetailViewData(
            id: "p1", name: "remote", path: "ssh://box/srv/repo", transport: "ssh", liveSessions: []
        )
        model.recomputeWorkspaces()
        model.activeWorkspacePath = "ssh://box/srv/wt/feat"

        await model.newSession()

        let session = try? XCTUnwrap(model.liveSessions.last)
        XCTAssertEqual(session?.workspacePath, "ssh://box/srv/wt/feat")
        XCTAssertEqual(session?.lastCwd, "/srv/wt/feat")
        XCTAssertTrue(
            created.last?.attachedCommand?.contains("cd '/srv/wt/feat'") == true,
            "command was \(created.last?.attachedCommand ?? "nil")"
        )
    }
```

`MockTerminalHost`에 `attachedCommand`가 없으면 추가한다 (`apps/macos/CodeSparkTests/MockTerminalHost.swift`):

```swift
    private(set) var attachedCommand: String?
```
그리고 `attach(sessionID:command:initialInput:)` 본문 첫 줄에 `attachedCommand = command` 를 넣는다.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_a_new_remote_tab_belongs_to_the_worktree_on_screen 2>&1 | tail -20
```
Expected: FAIL — `workspacePath`가 `"ssh://box/srv/repo"`(프로젝트 경로)로 나온다.

- [ ] **Step 3: Implement**

`AppModel.swift`의 `newSession` ssh 분기를 교체:

```swift
        // SSH projects: use ssh command instead of local shell
        if project.transport == "ssh", var info = SSHConnectionInfo(uri: project.path) {
            // The tab belongs to the worktree the tab bar is showing. That
            // address is a URI on this same host, and its remote path is where
            // the shell has to land.
            let remoteCwd = SSHConnectionInfo.remotePath(fromWorkspaceURI: workspacePath)
            if let remoteCwd { info.remotePath = remoteCwd }
            do {
                // `cwd` is a *remote* path on purpose — see the note in
                // `restoreInterruptedTabs`. It is what the store files as this
                // tab's position, and no OSC 7 will ever refill it.
                let sessionID = try await startAndAttachSession(
                    projectID: projectID,
                    transport: "ssh",
                    targetLabel: info.displayLabel,
                    title: info.displayLabel,
                    shell: shell,
                    cwd: remoteCwd,
                    workspacePath: workspacePath,
                    command: info.sshCommand(),
                    sshInfo: info
                )
                guard selectedProjectID == projectID else { return }
                // Regroup before selecting: `activeWorkspacePath`'s observer
                // reads `workspaces`.
                recomputeWorkspaces()
                workspaceSelectedSessions[workspacePath] = sessionID
                activeWorkspacePath = workspacePath
                activeSessionID = sessionID
                pendingSSHReconnectProjectID = nil
            } catch {
                loadErrorMessage = error.localizedDescription
            }
            return
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command, then the full suite:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests 2>&1 | grep -E "Executed .* tests"
```
Expected: 신규 PASS, 기존 192개 그린 유지.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Models/AppModel.swift apps/macos/CodeSparkTests
git commit -m "feat: open remote tabs in the worktree the tab bar shows"
```

---

### Task 7: 원격 워크트리 생성

**Files:**
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift` (`addWorktree`, `makeWorktreeName`, `previewWorktreeName`)
- Modify: `apps/macos/CodeSpark/Views/AddWorktreeSheet.swift`
- Test: `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`

**Interfaces:**
- Consumes: `remoteSSHArguments`, `sshExecutablePath` (Task 2)
- Produces:
  - `static func remoteRootExpression(_ root: String) -> String`
  - `static func remoteAddWorktreeScript(repoPath:branch:root:name:) -> String`
  - `static func repoName(forProjectPath: String) -> String`
  - `static func previewWorktreePath(projectPath: String, branch: String) -> String`
  - `addWorktree(projectPath:branch:worktreeRoot:id:)`가 ssh URI를 받으면 원격에 만들고 `GitWorktreeCreation.path`에 URI를 담아 돌려준다

- [ ] **Step 1: Write the failing tests**

`RemoteWorktreeScanTests.swift`의 마지막 `}` 직전에 추가:

```swift
    // MARK: - Creating

    /// Tilde expansion does not happen inside quotes, so the root cannot simply
    /// be shell-quoted like every other remote path.
    func test_a_tilde_root_expands_on_the_remote_side() {
        XCTAssertEqual(GitWorktreeService.remoteRootExpression("~/worktrees"), "\"$HOME\"/'worktrees'")
        XCTAssertEqual(GitWorktreeService.remoteRootExpression("~"), "\"$HOME\"")
        XCTAssertEqual(GitWorktreeService.remoteRootExpression("/srv/wt"), "'/srv/wt'")
    }

    /// Where `$HOME` is, whether the name is free, and what path git actually
    /// used all have to be decided on the same side of the connection — so it
    /// is one script, and it prints the path it made.
    func test_the_create_script_reports_the_path_it_made() throws {
        let script = GitWorktreeService.remoteAddWorktreeScript(
            repoPath: "/srv/repo", branch: "feat", root: "~/worktrees", name: "repo-feat-ab12"
        )
        XCTAssertTrue(script.contains("\"$HOME\"/'worktrees'"), script)
        XCTAssertTrue(script.contains("exit 3"), script)
        XCTAssertTrue(script.contains("git -C '/srv/repo' worktree add -b 'feat'"), script)
        XCTAssertTrue(script.contains("printf"), script)
    }

    func test_creating_a_remote_worktree_returns_its_uri() async throws {
        try installStubSSH(stdout: "/home/jay/worktrees/repo-feat-ab12")

        let creation = try await GitWorktreeService.addWorktree(
            projectPath: "ssh://jay@box/srv/repo", branch: "feat", worktreeRoot: "~/worktrees", id: "ab12"
        )

        XCTAssertEqual(creation.path, "ssh://jay@box/home/jay/worktrees/repo-feat-ab12")
        XCTAssertEqual(creation.branch, "feat")
    }

    /// The directory name comes from the repository, and for a remote project
    /// the repository is named by the remote path — not by the URI.
    func test_the_directory_is_named_after_the_remote_repository() {
        XCTAssertEqual(GitWorktreeService.repoName(forProjectPath: "ssh://jay@box/srv/my-repo"), "my-repo")
        XCTAssertEqual(GitWorktreeService.repoName(forProjectPath: "/Users/jay/my-repo"), "my-repo")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests/RemoteWorktreeScanTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `remoteRootExpression` 없음.

- [ ] **Step 3: Implement**

`GitWorktreeService.swift`의 `makeWorktreeName`을 교체하고 `repoName`을 추가:

```swift
    /// The repository's own name, whichever namespace the project lives in. A
    /// remote project is addressed by URI, but it is the remote path that names
    /// the repository.
    static func repoName(forProjectPath projectPath: String) -> String {
        let path = SSHConnectionInfo.remotePath(fromWorkspaceURI: projectPath) ?? projectPath
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func makeWorktreeName(projectPath: String, branch: String, id: String) -> String {
        [sanitizeComponent(repoName(forProjectPath: projectPath)), sanitizeComponent(branch), sanitizeComponent(id)]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func previewWorktreeName(projectPath: String, branch: String) -> String {
        [
            sanitizeComponent(repoName(forProjectPath: projectPath)),
            sanitizeComponent(branch),
            "<id>",
        ].joined(separator: "-")
    }

    /// What the create sheet shows. The root setting is the same string either
    /// way — on a remote project it names a directory on the other machine.
    static func previewWorktreePath(projectPath: String, branch: String) -> String {
        "\(configuredWorktreeRoot)/\(previewWorktreeName(projectPath: projectPath, branch: branch))"
    }
```

`// MARK: - Remote git` 블록에 추가:

```swift
    /// Tilde expansion is the one thing quoting must not swallow — `'~/wt'` is
    /// a literal directory named `~`. Everything after the tilde is still
    /// quoted.
    static func remoteRootExpression(_ root: String) -> String {
        if root == "~" { return "\"$HOME\"" }
        if root.hasPrefix("~/") {
            return "\"$HOME\"/" + SSHConnectionInfo.shellQuoted(String(root.dropFirst(2)))
        }
        return SSHConnectionInfo.shellQuoted(root)
    }

    /// Creating a worktree on the other machine is one script because three
    /// facts have to agree and all three live over there: where `$HOME` is,
    /// whether the name is taken, and the absolute path git ended up using.
    /// Exit 3 means the name was taken.
    ///
    /// `git worktree add` chatters on stdout, so it is redirected — stdout
    /// carries exactly one thing, the path.
    static func remoteAddWorktreeScript(
        repoPath: String,
        branch: String,
        root: String,
        name: String
    ) -> String {
        let rootExpr = remoteRootExpression(root)
        let quotedName = SSHConnectionInfo.shellQuoted(name)
        return """
        root=\(rootExpr); p="$root"/\(quotedName); \
        if [ -e "$p" ]; then exit 3; fi; \
        mkdir -p "$root" || exit 1; \
        git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree add -b \(SSHConnectionInfo.shellQuoted(branch)) "$p" 1>&2 || exit 1; \
        printf '%s\\n' "$p"
        """
    }

    /// Runs one remote command and returns its stdout, or throws with the
    /// remote's own stderr so the failure reads like git's.
    private static func runRemote(_ info: SSHConnectionInfo, command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = remoteSSHArguments(info, remoteCommand: command)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let exitStatus: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        }
        guard exitStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote git failed"
            throw NSError(
                domain: "GitWorktree",
                code: Int(exitStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "remote git failed" : message]
            )
        }
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Exit code the create script uses for "that name is already taken".
    private static let remoteNameTakenExitCode = 3

    private static func addRemoteWorktree(
        info: SSHConnectionInfo,
        repoPath: String,
        branch: String,
        root: String,
        id: String?
    ) async throws -> GitWorktreeCreation {
        // The local existence loop cannot run over here, so the check moved into
        // the script. One retry covers a genuine collision; a second failure is
        // the user's to see.
        var attemptID = id ?? makeWorktreeID()
        for attempt in 0..<2 {
            let name = makeWorktreeName(projectPath: repoPath, branch: branch, id: attemptID)
            do {
                let created = try await runRemote(info, command: remoteAddWorktreeScript(
                    repoPath: repoPath, branch: branch, root: root, name: name
                ))
                return GitWorktreeCreation(
                    id: attemptID,
                    name: name,
                    path: info.workspaceURI(forRemotePath: created),
                    branch: branch
                )
            } catch let error as NSError where error.code == remoteNameTakenExitCode
                && attempt == 0 && id == nil {
                attemptID = makeWorktreeID()
            }
        }
        throw NSError(
            domain: "GitWorktree",
            code: remoteNameTakenExitCode,
            userInfo: [NSLocalizedDescriptionKey: "A worktree directory with that name already exists on the remote."]
        )
    }
```

`addWorktree`의 맨 앞에 분기를 넣는다:

```swift
    static func addWorktree(
        projectPath: String,
        branch: String,
        worktreeRoot: String? = nil,
        id: String? = nil
    ) async throws -> GitWorktreeCreation {
        if let info = SSHConnectionInfo(uri: projectPath), let repoPath = info.remotePath {
            return try await addRemoteWorktree(
                info: info,
                repoPath: repoPath,
                branch: branch,
                root: worktreeRoot ?? configuredWorktreeRoot,
                id: id
            )
        }
        // ... 기존 로컬 구현 그대로
```

`AddWorktreeSheet.swift`의 미리보기 줄을 교체:

```swift
                Text(GitWorktreeService.previewWorktreePath(projectPath: projectPath, branch: branchName))
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSpark/Views/AddWorktreeSheet.swift apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift
git commit -m "feat: create worktrees on the remote"
```

---

### Task 8: 원격 워크트리 삭제 + 순서 뒤집기

**Files:**
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift` (`removeWorktree`)
- Modify: `apps/macos/CodeSpark/Models/AppModel.swift` (`removeWorktree` ~765-781)
- Test: `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`, `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`

**Interfaces:**
- Consumes: `runRemote`, `SSHConnectionInfo.remotePath(fromWorkspaceURI:)`
- Produces: `removeWorktree(projectPath:worktreePath:)`가 원격을 처리하고, 실패 시 탭이 살아남는다

- [ ] **Step 1: Write the failing tests**

`RemoteWorktreeScanTests.swift`의 마지막 `}` 직전에 추가:

```swift
    // MARK: - Removing

    func test_removing_a_remote_worktree_uses_remote_paths_not_uris() async throws {
        let argvFile = try installStubSSH(stdout: "")

        try await GitWorktreeService.removeWorktree(
            projectPath: "ssh://jay@box/srv/repo",
            worktreePath: "ssh://jay@box/srv/wt/repo-feat-ab12"
        )

        let argv = try recordedArgv(argvFile)
        XCTAssertTrue(
            argv.contains("git -C '/srv/repo' worktree remove '/srv/wt/repo-feat-ab12'"),
            "argv was \(argv)"
        )
        XCTAssertFalse(argv.joined().contains("ssh://"), "a URI reached git: \(argv)")
    }
```

`WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// Closing the tabs first means a remove that fails still costs the user
    /// their terminals — and over ssh, failing is routine.
    @MainActor
    func test_a_failed_remove_leaves_the_tabs_alone() async {
        let core = MockProjectCoreClient()
        let model = AppModel(core: core, terminalFactory: { MockTerminalHost(session: $0) })
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo")
        model.selectedProjectID = "p1"
        model.selectedProject = ProjectDetailViewData(
            id: "p1", name: "remote", path: "ssh://box/srv/repo", transport: "ssh", liveSessions: []
        )
        model.recomputeWorkspaces()
        model.activeWorkspacePath = "ssh://box/srv/wt/feat"
        await model.newSession()
        XCTAssertEqual(model.liveSessions.count, 1)

        let original = GitWorktreeService.sshExecutablePath
        defer { GitWorktreeService.sshExecutablePath = original }
        GitWorktreeService.sshExecutablePath = "/usr/bin/false"

        await model.removeWorktree(path: "ssh://box/srv/wt/feat")

        XCTAssertEqual(model.liveSessions.count, 1, "the tab was closed for a remove that failed")
        XCTAssertNotNil(model.loadErrorMessage)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/RemoteWorktreeScanTests/test_removing_a_remote_worktree_uses_remote_paths_not_uris \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_a_failed_remove_leaves_the_tabs_alone 2>&1 | tail -20
```
Expected: 첫 테스트는 로컬 git이 URI를 받고 실패, 둘째는 탭이 0개로 줄어 FAIL.

- [ ] **Step 3: Implement**

`GitWorktreeService.removeWorktree`를 교체:

```swift
    static func removeWorktree(projectPath: String, worktreePath: String) async throws {
        if let info = SSHConnectionInfo(uri: projectPath),
           let repoPath = info.remotePath,
           let target = SSHConnectionInfo.remotePath(fromWorkspaceURI: worktreePath) {
            _ = try await runRemote(info, command: """
            git -C \(SSHConnectionInfo.shellQuoted(repoPath)) worktree remove \(SSHConnectionInfo.shellQuoted(target))
            """)
            return
        }
        try await runGit(["-C", projectPath, "worktree", "remove", worktreePath])
    }
```

`AppModel.removeWorktree`를 교체:

```swift
    func removeWorktree(path: String) async {
        guard let project = selectedProject, !project.path.isEmpty else { return }
        do {
            // Remove first, close after. A remove that fails must not cost the
            // user their terminals — over ssh that failure is routine.
            try await GitWorktreeService.removeWorktree(projectPath: project.path, worktreePath: path)
            // By ownership, not by where the tab is standing: a tab belongs to
            // the worktree it was opened in and keeps belonging to it after a
            // `cd`. The old cwd test let a tab that had wandered out survive the
            // directory it lived in, and shut down visitors from other
            // worktrees in its place.
            for session in liveSessions where session.belongs(to: path) {
                closeSession(id: session.id)
            }
            gitWorktreeService.invalidateCache(for: project.path)
            await gitWorktreeService.refreshWorktrees(for: worktreeProjectPaths)
            recomputeWorkspaces()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command, then the full suite:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests 2>&1 | grep -E "Executed .* tests"
```
Expected: 전부 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSpark/Models/AppModel.swift apps/macos/CodeSparkTests
git commit -m "feat: remove remote worktrees, and only close tabs once git agreed"
```

---

### Task 9: 원격 탭의 방문 브랜치

**Files:**
- Modify: `apps/macos/CodeSpark/Models/AppModel.swift` (`visitingBranch` ~1027-1037)
- Test: `apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift`

**Interfaces:**
- Consumes: `SSHConnectionInfo.workspaceURI(forRemotePath:)` (Task 1)
- Produces: 없음 (표시 전용)

- [ ] **Step 1: Write the failing test**

`WorkspaceSelectionTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// An agent that creates a worktree and cd's into it leaves the tab where
    /// it was opened — right, but silent. A remote tab reports a path on the
    /// other machine, so it has to be spelled as an address before it can be
    /// matched against one.
    @MainActor
    func test_a_remote_tab_that_wandered_names_the_branch_it_is_in() async {
        let model = AppModel(core: MockProjectCoreClient(), terminalFactory: { MockTerminalHost(session: $0) })
        model.gitWorktreeService.primeCache([
            GitWorktree(path: "ssh://box/srv/repo", branch: "main", isMainWorktree: true),
            GitWorktree(path: "ssh://box/srv/wt/feat", branch: "feat", isMainWorktree: false),
        ], for: "ssh://box/srv/repo")
        model.selectedProjectID = "p1"
        model.selectedProject = ProjectDetailViewData(
            id: "p1", name: "remote", path: "ssh://box/srv/repo", transport: "ssh", liveSessions: []
        )
        model.recomputeWorkspaces()

        let visitor = SessionViewData(
            id: "s1", title: "t", targetLabel: "box",
            lastCwd: "/srv/wt/feat/apps", workspacePath: "ssh://box/srv/repo"
        )

        XCTAssertEqual(model.visitingBranch(for: visitor), "feat")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/WorkspaceSelectionTests/test_a_remote_tab_that_wandered_names_the_branch_it_is_in 2>&1 | tail -20
```
Expected: FAIL — nil이 나온다 (ssh 가드).

- [ ] **Step 3: Implement**

`AppModel.visitingBranch`를 교체:

```swift
    /// The branch a tab is currently working in, when that is not the worktree
    /// the tab belongs to — an agent that creates a worktree and moves into it
    /// leaves the tab where it was opened, which is right, but silent.
    ///
    /// nil whenever there is nothing to say: the tab is home, it stepped outside
    /// the repo entirely, or the repo has a single worktree.
    func visitingBranch(for session: SessionViewData) -> String? {
        guard workspaces.count > 1, let cwd = session.lastCwd else { return nil }
        // A remote tab reports a directory on the other machine, while
        // workspaces are addressed as URIs. Spell it the same way before
        // comparing — and via this project's own connection, so a path can
        // never match a worktree on some other host.
        let address: String
        if selectedProject?.transport == "ssh" {
            guard let info = SSHConnectionInfo(uri: selectedProject?.path ?? "") else { return nil }
            address = info.workspaceURI(forRemotePath: cwd)
        } else {
            address = cwd
        }
        guard let current = WorkspaceViewData.containing(cwd: address, in: workspaces),
              current.path != session.workspacePath else { return nil }
        return current.branch
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Models/AppModel.swift apps/macos/CodeSparkTests/WorkspaceSelectionTests.swift
git commit -m "feat: name the branch a wandering remote tab is in"
```

---

### Task 10: 실제 ssh 왕복 통합 테스트

스텁은 argv와 파싱을 지켜주지만, 원격 셸이 실제로 그 문자열을 어떻게 해석하는지는 지켜주지 않는다 — `CLAUDE.md`가 경고하는 바로 그 자리.

**Files:**
- Modify: `apps/macos/CodeSparkTests/SSHIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 2·7·8의 원격 조회/생성/삭제
- Produces: 없음 (검증 전용)

- [ ] **Step 1: Write the failing test**

`SSHIntegrationTests.swift`의 `// MARK: - Helpers` 바로 위에 추가:

```swift
    // MARK: - Worktrees over ssh

    /// A stub can only prove the argv we built. This proves the remote shell
    /// agrees — quoting, tilde expansion, and the path git actually chose.
    func test_worktrees_scan_create_and_remove_over_a_real_connection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-ssh-wt-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("my repo")   // a space, on purpose
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runLocal("/usr/bin/git", ["-C", repo.path, "init", "-q", "-b", "main"])
        try runLocal("/usr/bin/git", ["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "init"])

        let projectURI = "ssh://localhost\(repo.path)"
        let worktreeRoot = root.appendingPathComponent("wt").path

        // Create
        let creation = try await GitWorktreeService.addWorktree(
            projectPath: projectURI, branch: "feat", worktreeRoot: worktreeRoot
        )
        XCTAssertTrue(creation.path.hasPrefix("ssh://localhost\(worktreeRoot)/"), creation.path)

        // Scan
        let service = GitWorktreeService()
        await service.refreshWorktrees(for: [projectURI])
        let found = try XCTUnwrap(service.worktrees(for: projectURI))
        XCTAssertEqual(found.count, 2, "expected the repo and its worktree, got \(found.map(\.path))")
        XCTAssertTrue(found.contains { $0.branch == "feat" && $0.path == creation.path },
                      "worktrees were \(found.map { "\($0.branch)@\($0.path)" })")

        // Remove
        try await GitWorktreeService.removeWorktree(projectPath: projectURI, worktreePath: creation.path)
        service.invalidateCache(for: projectURI)
        await service.refreshWorktrees(for: [projectURI])
        XCTAssertEqual(service.worktrees(for: projectURI)?.count, 1)
    }
```

같은 파일의 `// MARK: - Helpers` 아래에 추가:

```swift
    private func runLocal(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"])
        }
    }
```

- [ ] **Step 2: Run test to verify it fails (or skips)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests/SSHIntegrationTests 2>&1 | tail -20
```
Expected: sshd가 꺼져 있으면 SKIP — 그 경우 사용자에게 System Settings → General → Sharing → Remote Login을 켜달라고 요청한 뒤 다시 돌린다. 켜져 있는데 실패하면 그게 이 태스크가 잡으려던 버그다.

- [ ] **Step 3: Fix whatever the real connection exposed**

스텁이 통과시켰지만 실제 셸이 거부하는 것이 있다면 여기서 고친다 (`GitWorktreeService`의 인용/스크립트). 실패가 없으면 변경 없음.

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command.
Expected: PASS, 또는 sshd 미기동 시 SKIP.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSparkTests/SSHIntegrationTests.swift apps/macos/CodeSpark/Services/GitWorktreeService.swift
git commit -m "test: worktrees over a real ssh connection"
```

---

### Task 11: `isRefreshing`이 요청을 버리지 않게 한다

원격 조회가 느려지면 생성/삭제 직후의 refresh가 조용히 버려진다.

**Files:**
- Modify: `apps/macos/CodeSpark/Services/GitWorktreeService.swift` (`refreshWorktrees`)
- Test: `apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift`

**Interfaces:**
- Consumes: Task 3의 task group
- Produces: 동시 호출이 직렬화되고 버려지지 않는다

- [ ] **Step 1: Write the failing test**

`RemoteWorktreeScanTests.swift`의 마지막 `}` 직전에 추가:

```swift
    /// A refresh asked for while another is running used to be dropped on the
    /// floor. With a slow remote in the mix that is the refresh right after
    /// creating or removing a worktree — the one whose result the sidebar is
    /// waiting for.
    func test_a_refresh_during_a_refresh_is_not_dropped() async throws {
        try installStubSSH(stdout: """
        worktree /srv/repo
        branch refs/heads/main
        """)
        let service = GitWorktreeService()

        async let first: Void = service.refreshWorktrees(for: ["ssh://box/srv/one"])
        async let second: Void = service.refreshWorktrees(for: ["ssh://box/srv/one", "ssh://box/srv/two"])
        _ = await (first, second)

        XCTAssertNotNil(service.worktrees(for: "ssh://box/srv/two"), "the second refresh was dropped")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD \
  -only-testing:CodeSparkTests/RemoteWorktreeScanTests/test_a_refresh_during_a_refresh_is_not_dropped 2>&1 | tail -20
```
Expected: FAIL — `XCTAssertNotNil failed`.

- [ ] **Step 3: Implement**

`GitWorktreeService.swift`에서 `private var isRefreshing = false` 를 지우고 대신:

```swift
    /// Refreshes queue behind each other instead of being dropped. The TTL
    /// makes a queued duplicate free — it finds nothing stale and returns.
    private var inFlight: Task<Void, Never>?
```

`refreshWorktrees`를 두 함수로 나눈다:

```swift
    @MainActor
    func refreshWorktrees(for projectPaths: [String]) async {
        let previous = inFlight
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.performRefresh(for: projectPaths)
        }
        inFlight = task
        await task.value
    }

    @MainActor
    private func performRefresh(for projectPaths: [String]) async {
        // ... 기존 refreshWorktrees 본문에서 `guard !isRefreshing` / `isRefreshing = true`
        //     / `defer { isRefreshing = false }` 세 줄만 뺀 나머지 그대로
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command, then the full suite:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD -only-testing:CodeSparkTests 2>&1 | grep -E "Executed .* tests"
```
Expected: 전부 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/CodeSpark/Services/GitWorktreeService.swift apps/macos/CodeSparkTests/RemoteWorktreeScanTests.swift
git commit -m "fix: queue worktree refreshes instead of dropping them"
```

---

### Task 12: 문서 갱신 + 전체 검증

**Files:**
- Modify: `CLAUDE.md` (Worktree Scoping 절, Known Issues 절)

- [ ] **Step 1: Run the whole suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark -destination 'platform=macOS' \
  -derivedDataPath /tmp/CSWorktreeDD 2>&1 | grep -E "Executed .* tests|TEST (SUCCEEDED|FAILED)"
```
Expected: 유닛 + UI 테스트 전부 통과.

- [ ] **Step 2: Update CLAUDE.md**

`## Worktree Scoping` 절 끝에 추가:

```markdown
- **원격(ssh) 프로젝트도 워크트리를 갖는다**: 원격 워크트리의 주소는 `ssh://user@host/remote/path`
  URI다. `workspacePath`가 소속·선택·복원·삭제가 공유하는 단일 키이므로, 원격도 같은 문자열
  공간에 넣어 그 로직을 그대로 쓴다.
  - **두 네임스페이스를 섞지 말 것**: `workspacePath`는 URI, `last_cwd`와 git 인자는 원격 raw
    경로다. 변환은 `SSHConnectionInfo.workspaceURI(forRemotePath:)` / `remotePath(fromWorkspaceURI:)`
    **두 함수 밖에서 하지 않는다**. `git -C 'ssh://…'`는 조용히 실패한다.
  - **`remotePath` 없는 `ssh://host`는 스캔하지 않는다** — 리포 위치를 모르므로.
  - **게이트가 두 겹**: `worktreeProjectPaths`의 필터와 `selectProject`의 호출 조건. 하나만 열면
    원격 스캔은 아무 증상 없이 죽어 있는다.
  - **조회 실패는 워크트리 삭제가 아니다 — 화면에서도**: 실패 시 캐시가 직전 성공 목록을
    유지한다. 안 그러면 `groupSessions`가 프로젝트 하나로 재그룹핑하고, 워크트리에 서 있던
    선택이 아무것도 못 맞춰(`visibleSessions`가 빈 배열) 메인 영역이 빈다. 원격은 일상적으로
    끊기므로 이게 기본 경로다.
  - **원격 생성은 스크립트 한 번**: `$HOME` 전개·이름 충돌 확인·`git worktree add`·만들어진 경로
    출력이 모두 원격에서 한 번에 일어난다. `'~/worktrees'`는 따옴표 안에서 전개되지 않으므로
    루트만 `remoteRootExpression`이 따로 다룬다.
  - **삭제는 git이 성공한 뒤에 탭을 닫는다**. 원격은 실패가 흔해서, 순서가 반대면 삭제에
    실패해도 터미널만 잃는다.
```

`## Known Issues`의 SSH 줄 아래에 추가:

```markdown
- 원격 워크트리 스캔은 키 인증(`BatchMode=yes`)이 되는 호스트에서만 동작한다. 비밀번호를 묻는
  호스트에서는 워크트리 행이 조용히 안 나온다 — 백그라운드 폴링이 프롬프트에 매달릴 수 없기 때문.
- IPv6 리터럴 호스트는 `SSHConnectionInfo` 파서 한계로 지원하지 않는다.
```

- [ ] **Step 3: Verify the app in the real UI**

`CLAUDE.md`의 "구현 완료 후 필수 검증 절차"에 따라, 빌드 후 실행해 accessibility API로 확인한다:

```bash
xcodebuild -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark \
  -configuration Debug -derivedDataPath /tmp/CSWorktreeDD -destination 'platform=macOS' build
open /tmp/CSWorktreeDD/Build/Products/Debug/CodeSpark.app
```

localhost sshd가 켜져 있다면 `ssh://localhost<임시 리포 경로>` 프로젝트를 추가해 워크트리 행이
그려지는지 확인한다. sshd가 꺼져 있으면 이 단계는 건너뛰고 사용자에게 보고한다.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the remote worktree rules"
```

---

## Self-Review

**Spec coverage:**

| 스펙 항목 | 태스크 |
|---|---|
| URI 주소 체계 + 변환 단일 지점 + canonical | Task 1 |
| 원격 스캔, ssh 옵션, 하드 타임아웃, ControlMaster 없음 | Task 2 |
| 게이트 두 겹, 동시 실행 제한 | Task 3 |
| 실패해도 화면을 비우지 않음 | Task 4 |
| 활성 워크스페이스 폴백 | Task 5 |
| 새 탭 | Task 6 |
| 원격 생성 (틸드, 충돌, 경로 출력, repo 이름), 시트 미리보기 | Task 7 |
| 원격 삭제 + 순서 뒤집기 | Task 8 |
| `visitingBranch` | Task 9 |
| 실제 ssh 통합 테스트 | Task 10 |
| `isRefreshing` | Task 11 |
| 문서 + 전체 검증 | Task 12 |

**Placeholder scan:** 없음 — 모든 코드 단계가 실제 코드를 담고 있다. Task 10 Step 3만 "실패가 드러나면 고친다"인데, 이는 통합 테스트의 성격상 불가피하며 무엇을 어디서 고칠지(인용/스크립트, `GitWorktreeService`)를 명시했다.

**Type consistency:** `workspaceURI(forRemotePath:)`, `remotePath(fromWorkspaceURI:)`, `canonicalRemotePath(_:)`, `shellQuoted(_:)`, `sshExecutablePath`, `remoteSSHArguments(_:remoteCommand:)`, `remoteWorktreeListCommand(repoPath:)`, `remoteRootExpression(_:)`, `remoteAddWorktreeScript(repoPath:branch:root:name:)`, `runRemote(_:command:)`, `repoName(forProjectPath:)`, `previewWorktreePath(projectPath:branch:)`, `expireCacheForTesting()`, `performRefresh(for:)` — 정의 태스크와 사용 태스크에서 철자와 인자 레이블이 일치한다.
