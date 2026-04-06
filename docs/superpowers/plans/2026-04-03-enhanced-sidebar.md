# M2a: Enhanced Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 터미널 멀티플렉서 수준의 사이드바 — project별 live session 목록, 상태 뱃지(Live/Idle), 자유 토글, 세션 이름 변경

**Architecture:** `project_summary_t`에 live session 배열을 추가하여 한 번의 API 호출로 사이드바 전체를 렌더링. Idle 상태는 Ghostty 출력 시간 기반으로 Swift에서 판단. 사이드바는 Finder 스타일 자유 토글로 각 project를 독립적으로 펼침/접힘.

**Tech Stack:** Zig (C API), Swift (SwiftUI), Ghostty (output tracking)

**Spec:** `docs/superpowers/specs/2026-04-03-enhanced-sidebar-design.md`

---

### Task 1: Zig — ProjectSummary에 live session 배열 추가

**Files:**
- Modify: `libs/project-core/src/models.zig:169-182`
- Modify: `libs/project-core/src/store.zig:59-91`

- [ ] **Step 1: models.zig에 live_session_details 필드 추가**

`ProjectSummary` struct에 live session 배열 필드를 추가한다.

```zig
pub const ProjectSummary = struct {
    id: []u8,
    name: []u8,
    live_sessions: i64,
    recently_closed_sessions: i64,
    has_interrupted_sessions: bool,
    updated_at: i64,
    live_session_details: []SessionSummary,  // ← 새 필드

    pub fn deinit(self: *ProjectSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        for (self.live_session_details) |*session| session.deinit(allocator);
        allocator.free(self.live_session_details);
        self.* = undefined;
    }
};
```

- [ ] **Step 2: store.zig listProjectSummaries에 세션 로드 추가**

기존 aggregate 쿼리 이후, 각 project의 live session을 별도 쿼리로 로드한다. 기존 `liveSessionsForProject` 패턴을 재사용한다.

```zig
pub fn listProjectSummaries(self: *Store, allocator: std.mem.Allocator) StoreError![]models.ProjectSummary {
    // 기존 aggregate 쿼리 (변경 없음)
    var stmt = try Statement.init(self.db,
        "select w.id, w.name, w.updated_at," ++
        " coalesce(sum(case when s.state = 'live' then 1 else 0 end), 0)," ++
        " coalesce(sum(case when s.state in ('closed','exited','lost','crashed') then 1 else 0 end), 0)," ++
        " coalesce(max(case when s.state = 'interrupted' then 1 else 0 end), 0)" ++
        " from projects w left join sessions s on s.project_id = w.id" ++
        " group by w.id, w.name, w.updated_at order by w.updated_at desc, w.rowid desc",
    );
    defer stmt.deinit();

    var items: std.ArrayList(models.ProjectSummary) = .empty;
    defer items.deinit(allocator);

    while (try stmt.step()) {
        const ws_id = try stmt.columnOwnedText(allocator, 0);
        errdefer allocator.free(ws_id);

        const live_details = try self.liveSessionsForProject(allocator, ws_id);

        try items.append(allocator, .{
            .id = ws_id,
            .name = try stmt.columnOwnedText(allocator, 1),
            .updated_at = stmt.columnInt64(2),
            .live_sessions = stmt.columnInt64(3),
            .recently_closed_sessions = stmt.columnInt64(4),
            .has_interrupted_sessions = stmt.columnInt64(5) != 0,
            .live_session_details = live_details,
        });
    }

    return items.toOwnedSlice(allocator);
}
```

참고: `liveSessionsForProject`는 `projectDetail` 내부에서 이미 사용하는 패턴이다. store.zig에서 해당 함수를 확인하고 재사용한다.

- [ ] **Step 3: Zig 테스트 실행**

Run: `cd libs/project-core && zig build test`
Expected: PASS (기존 테스트가 새 필드에 적응)

- [ ] **Step 4: 커밋**

```bash
git add libs/project-core/src/models.zig libs/project-core/src/store.zig
git commit -m "feat(zig): add live_session_details to ProjectSummary"
```

---

### Task 2: Zig — updateSessionTitle API 추가

**Files:**
- Modify: `libs/project-core/src/store.zig`
- Modify: `libs/project-core/tests/store_test.zig`

- [ ] **Step 1: store_test.zig에 rename 테스트 추가**

```zig
test "updateSessionTitle changes the session title" {
    var store = try TestStore.init();
    defer store.deinit();

    const ws_id = try store.store.createProject(std.testing.allocator, "test-ws");
    defer std.testing.allocator.free(ws_id);

    const session_id = try store.store.startSession(std.testing.allocator, .{
        .project_id = ws_id,
        .transport = .local,
        .target_label = "local",
        .title = "Original",
        .shell = "/bin/zsh",
        .initial_cwd = null,
    });
    defer std.testing.allocator.free(session_id);

    try store.store.updateSessionTitle(session_id, "Renamed");

    const detail = try store.store.projectDetail(std.testing.allocator, ws_id);
    defer {
        var d = detail;
        d.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("Renamed", detail.live_sessions[0].title);
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `cd libs/project-core && zig build test`
Expected: FAIL — `updateSessionTitle` not found

- [ ] **Step 3: store.zig에 updateSessionTitle 구현**

```zig
pub fn updateSessionTitle(self: *Store, session_id: []const u8, new_title: []const u8) StoreError!void {
    var stmt = try Statement.init(
        self.db,
        "update sessions set title = ?2, updated_at = ?3 where id = ?1",
    );
    defer stmt.deinit();
    try stmt.bindText(1, session_id);
    try stmt.bindText(2, new_title);
    try stmt.bindInt64(3, now());
    try stmt.expectDone();
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `cd libs/project-core && zig build test`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add libs/project-core/src/store.zig libs/project-core/tests/store_test.zig
git commit -m "feat(zig): add updateSessionTitle to store"
```

---

### Task 3: Zig C API — summary 확장 + updateSessionTitle 노출

**Files:**
- Modify: `libs/project-core/src/c_api.zig:70-77`
- Modify: `libs/project-core/include/project_core.h:76-83,156-159`

- [ ] **Step 1: c_api.zig project_summary_t에 live_session_details 추가**

```zig
pub const project_summary_t = extern struct {
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    live_sessions: i64,
    recently_closed_sessions: i64,
    has_interrupted_sessions: bool,
    updated_at: i64,
    live_session_details: ?[*]project_session_summary_t,  // ← 새 필드
    live_session_detail_count: i32,                          // ← 새 필드
};
```

- [ ] **Step 2: listProjectSummaries C API 함수에서 세션 배열 복사**

`project_service_list_project_summaries` 함수 내부에서 `live_session_details`를 C 배열로 변환한다. 기존 `project_service_project_detail`의 live session 변환 패턴을 참고한다.

- [ ] **Step 3: project_free_summaries에서 세션 배열 해제 추가**

`project_free_summaries` 함수에서 각 summary의 `live_session_details` 배열을 해제한다.

- [ ] **Step 4: update_session_title C API 함수 추가**

```zig
export fn project_service_update_session_title(
    ptr: ?*project_service,
    session_id: ?[*:0]const u8,
    new_title: ?[*:0]const u8,
) project_status_t {
    const svc = ptr orelse return .WORKSPACE_STATUS_POISONED_STATE;
    svc.mutex.lock();
    defer svc.mutex.unlock();

    const sid = spanOrNull(session_id) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    const title = spanOrNull(new_title) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;

    svc.store.updateSessionTitle(sid, title) catch return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    return .WORKSPACE_STATUS_OK;
}
```

- [ ] **Step 5: project_core.h 헤더 업데이트**

`project_summary_t`에 새 필드 추가:

```c
typedef struct project_summary_t {
    char *id;
    char *name;
    int64_t live_sessions;
    int64_t recently_closed_sessions;
    bool has_interrupted_sessions;
    int64_t updated_at;
    project_session_summary_t *live_session_details;  /* 새 필드 */
    int32_t live_session_detail_count;                   /* 새 필드 */
} project_summary_t;
```

새 API 함수 선언 추가:

```c
project_status_t project_service_update_session_title(
    project_service_t *service,
    const char *session_id,
    const char *new_title
);
```

- [ ] **Step 6: Zig 빌드 확인**

Run: `cd libs/project-core && zig build`
Expected: 빌드 성공

- [ ] **Step 7: 커밋**

```bash
git add libs/project-core/src/c_api.zig libs/project-core/include/project_core.h
git commit -m "feat(zig): expose live_session_details in summary and add update_session_title C API"
```

---

### Task 4: Swift — ProjectSummaryViewData 확장 + protocol 추가

**Files:**
- Modify: `apps/macos/StatefulTerminal/Models/ProjectViewData.swift:3-9`
- Modify: `apps/macos/StatefulTerminal/Bridge/ProjectCoreClient.swift`
- Modify: `apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift`
- Modify: `apps/macos/StatefulTerminalTests/MockProjectCoreClient.swift`

- [ ] **Step 1: ProjectViewData.swift에 liveSessionDetails 필드 추가**

```swift
struct ProjectSummaryViewData: Identifiable, Equatable {
    let id: String
    let name: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
    let liveSessionDetails: [SessionSummary]  // ← 새 필드
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let targetLabel: String
    let lastCwd: String?
}
```

- [ ] **Step 2: ProjectCoreClientProtocol에 updateSessionTitle 추가**

```swift
protocol ProjectCoreClientProtocol {
    // 기존 메서드들...
    func updateSessionTitle(sessionId: String, newTitle: String) async throws
}
```

- [ ] **Step 3: LiveProjectCoreClient.listProjectSummaries()에서 세션 배열 파싱**

```swift
func listProjectSummaries() async throws -> [ProjectSummaryViewData] {
    var summaries: UnsafeMutablePointer<project_summary_t>?
    var count: Int32 = 0
    let status = project_service_list_project_summaries(service, &summaries, &count)
    guard status == WORKSPACE_STATUS_OK else { throw projectError(status) }
    defer { project_free_summaries(summaries, count) }

    return (0..<Int(count)).map { i in
        let s = summaries![i]
        let details = (0..<Int(s.live_session_detail_count)).map { j in
            let d = s.live_session_details![j]
            return SessionSummary(
                id: String(cString: d.id),
                title: String(cString: d.title),
                targetLabel: String(cString: d.target_label),
                lastCwd: d.last_cwd != nil ? String(cString: d.last_cwd) : nil
            )
        }
        return ProjectSummaryViewData(
            id: String(cString: s.id),
            name: String(cString: s.name),
            liveSessions: Int(s.live_sessions),
            recentlyClosedSessions: Int(s.recently_closed_sessions),
            hasInterruptedSessions: s.has_interrupted_sessions,
            liveSessionDetails: details
        )
    }
}
```

- [ ] **Step 4: LiveProjectCoreClient.updateSessionTitle() 구현**

```swift
func updateSessionTitle(sessionId: String, newTitle: String) async throws {
    let status = sessionId.withCString { idPtr in
        newTitle.withCString { titlePtr in
            project_service_update_session_title(service, idPtr, titlePtr)
        }
    }
    guard status == WORKSPACE_STATUS_OK else { throw projectError(status) }
}
```

- [ ] **Step 5: TerminalHostProtocol에 lastOutputTime 추가**

```swift
protocol TerminalHostProtocol: AnyObject {
    var delegate: (any TerminalHostDelegate)? { get set }
    var lastOutputTime: Date? { get }  // ← 새 프로퍼티
    func attach(sessionID: String)
    func close(sessionID: String)
}
```

- [ ] **Step 6: MockProjectCoreClient 업데이트**

```swift
func updateSessionTitle(sessionId: String, newTitle: String) async throws {
    // no-op for tests
}
```

기존 `ProjectSummaryViewData` 생성 코드에 `liveSessionDetails: []` 추가.

- [ ] **Step 7: 빌드 확인**

Run: `cd apps/macos && xcodegen generate --spec project.yml && xcodebuild build ...`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: 커밋**

```bash
git add apps/macos/StatefulTerminal/Models/ProjectViewData.swift \
  apps/macos/StatefulTerminal/Bridge/ProjectCoreClient.swift \
  apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift \
  apps/macos/StatefulTerminalTests/MockProjectCoreClient.swift
git commit -m "feat(swift): extend summary with session details, add updateSessionTitle"
```

---

### Task 5: Swift — AppModel idle 타이머 + renameSession

**Files:**
- Modify: `apps/macos/StatefulTerminal/Models/AppModel.swift`

- [ ] **Step 1: AppModel에 idleSessionIDs와 타이머 추가**

```swift
@Published var idleSessionIDs: Set<String> = []
private var idleTimer: AnyCancellable?
```

init에서 타이머 시작:

```swift
init(core: ProjectCoreClientProtocol, terminalFactory: ...) {
    self.core = core
    self.terminalFactory = terminalFactory
    idleTimer = Timer.publish(every: 10, on: .main, in: .common)
        .autoconnect()
        .sink { [weak self] _ in
            self?.updateIdleStates()
        }
}

private func updateIdleStates() {
    let threshold = Date().addingTimeInterval(-10)
    idleSessionIDs = Set(
        hosts.compactMap { (id, host) in
            guard let lastOutput = host.lastOutputTime else { return id }
            return lastOutput < threshold ? id : nil
        }
    )
}
```

- [ ] **Step 2: renameSession 메서드 추가**

```swift
func renameSession(id: String, title: String) async {
    // Update local state immediately
    if let index = liveSessions.firstIndex(where: { $0.id == id }) {
        liveSessions[index] = SessionViewData(
            id: liveSessions[index].id,
            title: title,
            targetLabel: liveSessions[index].targetLabel,
            lastCwd: liveSessions[index].lastCwd,
            restoreRecipe: liveSessions[index].restoreRecipe
        )
    }
    // Persist to store
    try? await core.updateSessionTitle(sessionId: id, newTitle: title)
}
```

- [ ] **Step 3: 테스트 실행**

Run: `xcodebuild test ...`
Expected: PASS

- [ ] **Step 4: 커밋**

```bash
git add apps/macos/StatefulTerminal/Models/AppModel.swift
git commit -m "feat(swift): add idle timer and renameSession to AppModel"
```

---

### Task 6: Swift — SessionSidebarRow 뷰 생성

**Files:**
- Create: `apps/macos/StatefulTerminal/Views/SessionSidebarRow.swift`

- [ ] **Step 1: SessionSidebarRow 구현**

```swift
import SwiftUI

struct SessionSidebarRow: View {
    let session: SessionSummary
    let isActive: Bool
    let isIdle: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isIdle ? Color.gray.opacity(0.4) : Color.green)
                .frame(width: 6, height: 6)

            if isEditing {
                TextField("", text: $editTitle, onCommit: {
                    if !editTitle.isEmpty { onRename(editTitle) }
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(.caption, weight: .medium))
                .onExitCommand { isEditing = false }
            } else {
                Text(session.title)
                    .font(.system(.caption, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(1)
            }

            Spacer()

            if isIdle {
                Text("idle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            }

            if let cwd = session.lastCwd {
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2) {
            editTitle = session.title
            isEditing = true
        }
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `xcodegen generate && xcodebuild build ...`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 커밋**

```bash
git add apps/macos/StatefulTerminal/Views/SessionSidebarRow.swift
git commit -m "feat(swift): add SessionSidebarRow with inline rename"
```

---

### Task 7: Swift — SidebarView에 세션 목록 + 토글 연동

**Files:**
- Modify: `apps/macos/StatefulTerminal/Views/SidebarView.swift`

- [ ] **Step 1: SidebarView에 expandedProjectIDs state 추가**

```swift
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var expandedProjectIDs: Set<String> = []
```

- [ ] **Step 2: ProjectSidebarRow를 토글 가능하게 변경**

project 이름 클릭 → 펼침/접힘 토글. 세션 행 클릭 → 해당 세션 활성화 + project 선택.

```swift
ForEach(model.projects) { project in
    VStack(alignment: .leading, spacing: 0) {
        // Project header — 클릭하면 토글
        ProjectSidebarRow(
            project: project,
            isSelected: model.selectedProjectID == project.id,
            isExpanded: expandedProjectIDs.contains(project.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if expandedProjectIDs.contains(project.id) {
                expandedProjectIDs.remove(project.id)
            } else {
                expandedProjectIDs.insert(project.id)
            }
            Task { await model.selectProject(id: project.id) }
        }

        // Session rows — 펼쳐진 경우만
        if expandedProjectIDs.contains(project.id) {
            ForEach(project.liveSessionDetails) { session in
                SessionSidebarRow(
                    session: session,
                    isActive: model.activeSessionID == session.id,
                    isIdle: model.idleSessionIDs.contains(session.id),
                    onSelect: {
                        model.activeSessionID = session.id
                        Task { await model.selectProject(id: project.id) }
                    },
                    onRename: { newTitle in
                        Task { await model.renameSession(id: session.id, title: newTitle) }
                    }
                )
                .padding(.leading, 18)
            }
        }
    }
}
```

- [ ] **Step 3: ProjectSidebarRow에 isExpanded 파라미터 추가**

disclosure indicator(▼/▶)를 표시하기 위해 `isExpanded: Bool` 파라미터를 추가한다. 기존 status circle 자리를 disclosure triangle로 교체한다.

```swift
struct ProjectSidebarRow: View {
    let project: ProjectSummaryViewData
    let isSelected: Bool
    let isExpanded: Bool  // ← 새 파라미터

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            // ... 나머지 기존 코드
```

- [ ] **Step 4: 선택된 project 자동 펼침**

`load()` 완료 후 첫 project를 자동으로 펼치도록 한다:

```swift
// SidebarView.swift
.onAppear {
    if let first = model.projects.first {
        expandedProjectIDs.insert(first.id)
    }
}
```

- [ ] **Step 5: 빌드 + 테스트**

Run: `xcodegen generate && xcodebuild test ...`
Expected: BUILD SUCCEEDED, all tests PASS

- [ ] **Step 6: 커밋**

```bash
git add apps/macos/StatefulTerminal/Views/SidebarView.swift
git commit -m "feat(swift): project toggle with live session list in sidebar"
```

---

### Task 8: GhosttyTerminalHost — lastOutputTime 추적

**Files:**
- Modify: `apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift`
- Modify: `apps/macos/StatefulTerminal/Terminal/NoOpTerminalHost.swift`

- [ ] **Step 1: GhosttyTerminalHost에 lastOutputTime 추가**

```swift
final class GhosttyTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    private(set) var lastOutputTime: Date? = nil
    // ... 기존 코드
```

`attach` 시점에 초기화:

```swift
func attach(sessionID: String) {
    lastOutputTime = Date()
    // ... 기존 surface 생성 코드
}
```

Ghostty의 `wakeup_cb` tick에서 업데이트 — `GhosttyRuntime.initialize()`의 wakeup callback에서 현재 active host의 lastOutputTime을 갱신한다. 또는 더 간단하게: surface의 render cycle에서 업데이트.

간단한 접근: `GhosttyTerminalSurfaceView.setFrameSize`가 호출될 때마다 (Ghostty가 content를 업데이트할 때) host에 알린다. 하지만 이건 resize에서만 동작한다.

가장 실용적인 접근: `wakeup_cb`에서 `lastOutputTime`을 업데이트한다. wakeup은 Ghostty가 화면에 새 내용을 그릴 때마다 호출된다.

- [ ] **Step 2: NoOpTerminalHost에 lastOutputTime 추가**

```swift
final class NoOpTerminalHost: TerminalHostProtocol {
    weak var delegate: (any TerminalHostDelegate)?
    var lastOutputTime: Date? { nil }
    // ... 기존 코드
}
```

- [ ] **Step 3: 빌드 + 테스트**

Run: `xcodebuild test ...`
Expected: PASS

- [ ] **Step 4: 커밋**

```bash
git add apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift \
  apps/macos/StatefulTerminal/Terminal/NoOpTerminalHost.swift
git commit -m "feat(swift): track lastOutputTime in GhosttyTerminalHost for idle detection"
```

---

### Task 9: 통합 테스트 + 수동 검증

- [ ] **Step 1: 전체 Zig 테스트**

Run: `cd libs/project-core && zig build test`
Expected: PASS

- [ ] **Step 2: 전체 Swift 테스트**

Run: `cd apps/macos && xcodegen generate --spec project.yml && xcodebuild test -project StatefulTerminal.xcodeproj -scheme StatefulTerminal -destination 'platform=macOS' -derivedDataPath /tmp/StatefulTerminalDerivedData COMPILER_INDEX_STORE_ENABLE=NO`
Expected: PASS

- [ ] **Step 3: 앱 실행 수동 검증**

```bash
open /tmp/StatefulTerminalDerivedData/Build/Products/Debug/StatefulTerminal.app
```

확인 항목:
1. 사이드바에 project 이름 + disclosure triangle 표시
2. project 클릭 → 펼침/접힘 동작
3. 펼쳐진 project 아래에 live session 목록 표시
4. 세션 클릭 → 해당 세션으로 전환
5. 세션 더블클릭 → 이름 변경 가능
6. 10초 대기 → idle 뱃지 표시
7. 탭 바의 세션 이름도 변경 반영

- [ ] **Step 4: 최종 커밋 (필요시)**

```bash
git add -A && git commit -m "fix: integration adjustments for enhanced sidebar"
```
