# M2a: Enhanced Sidebar — Design Spec

## Context

Code Spark의 사이드바를 터미널 멀티플렉서 수준으로 강화한다. 현재 project별 aggregate count만 표시하는 사이드바를, 개별 세션 목록 + 상태 뱃지 + 이름 변경이 가능한 구조로 발전시킨다.

## Scope

| 포함 | 제외 (M2b) |
|------|-----------|
| 사이드바에 live session 목록 표시 | Project 생성/삭제/이름 변경 UI |
| 세션별 상태 뱃지 (Live/Idle/Closed) | Git 브랜치 + 경로 표시 |
| Project 자유 토글 (Finder 스타일) | 검색 (Cmd+K) |
| 세션 이름 변경 (더블클릭 inline edit) | Window state restoration |

## Design Decisions

- **사이드바 구조**: 자유 토글 (Finder 스타일) — 각 project를 독립적으로 펼치거나 접을 수 있음
- **데이터 흐름**: Summary에 세션 배열 포함 — `listProjectSummaries()`가 세션 목록도 함께 반환
- **상태 판단**: Live / Idle / Closed 3단계 — 10초 무출력 시 Idle
- **이름 변경**: 더블클릭 → inline TextField → Enter 확정 / Esc 취소

## Data Model Changes

### SessionSummary (새 타입)

```swift
struct SessionSummary: Identifiable {
    let id: String
    var title: String
    let targetLabel: String   // "local" 또는 SSH 호스트
    let lastCwd: String?
}
```

### ProjectSummaryViewData 확장

```swift
struct ProjectSummaryViewData: Identifiable {
    let id: String
    let name: String
    let liveSessions: Int
    let recentlyClosedSessions: Int
    let hasInterruptedSessions: Bool
    let liveSessionDetails: [SessionSummary]  // ← 새 필드
}
```

### Idle 상태는 Swift 레벨에서 관리

```swift
// AppModel에 추가
@Published var idleSessionIDs: Set<String> = []
```

Zig 저장소는 idle 상태를 모름. Ghostty 출력 시간 기반으로 Swift에서 판단.

## Zig C API Changes

### project_summary_t 확장

```c
typedef struct {
    const char* id;
    const char* title;
    const char* target_label;
    const char* last_cwd;       // nullable
} project_session_summary_t;

typedef struct {
    const char* id;
    const char* name;
    int32_t live_sessions;
    int32_t recently_closed_sessions;
    bool has_interrupted_sessions;
    project_session_summary_t* live_session_details;  // ← 새 필드
    int32_t live_session_detail_count;                   // ← 새 필드
} project_summary_t;
```

### 새 API: update_session_title

```c
project_status_t project_service_update_session_title(
    project_service_t service,
    const char* session_id,
    const char* new_title
);
```

### listProjectSummaries SQL 변경

기존 projects 쿼리에 sessions LEFT JOIN 추가. project별 live session을 함께 로드.

## Sidebar UI Design

### SidebarView 변경

`SidebarView`에 `@State var expandedProjectIDs: Set<String>` 추가.

```
▼ 코드스파크
    ● fix-build                    ~/spark3
    ● Terminal              idle   ~/spark3
▼ 법알고
    ● dev-server                   ~/bubalgo
▶ 마음챙김                    ○ idle
▶ 주간보고서
```

### ProjectSidebarRow 변경

- project 이름 클릭 → 펼침/접힘 토글
- 펼쳐진 상태: 하위에 `SessionSidebarRow` 렌더링
- 접힌 상태: 이름 옆에 aggregate 상태 표시

### SessionSidebarRow (새 뷰)

```swift
struct SessionSidebarRow: View {
    let session: SessionSummary
    let isActive: Bool
    let isIdle: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
}
```

- 상태 도트: 초록(live), 회색(idle)
- 제목 + lastCwd
- `isActive` 시 보라색 하이라이트
- 더블클릭 → inline TextField로 전환

## Idle State Detection

### GhosttyTerminalHost 변경

```swift
protocol TerminalHostProtocol {
    // 기존 메서드들...
    var lastOutputTime: Date? { get }  // ← 새 프로퍼티
}
```

`GhosttyTerminalHost`에서 `wakeup_cb` tick 시점에 `lastOutputTime = Date()` 업데이트.

### AppModel 타이머

```swift
// 10초마다 idle 상태 업데이트
Timer.publish(every: 10, on: .main, in: .common)
    .autoconnect()
    .sink { [weak self] _ in
        self?.updateIdleStates()
    }

func updateIdleStates() {
    let threshold = Date().addingTimeInterval(-10)
    idleSessionIDs = Set(
        hosts.compactMap { (id, host) in
            guard let lastOutput = host.lastOutputTime,
                  lastOutput < threshold else { return nil }
            return id
        }
    )
}
```

## Session Rename Flow

1. 사용자가 세션 행을 더블클릭
2. `SessionSidebarRow`가 inline `TextField`로 전환 (`@State var isEditing`)
3. Enter → `onRename(newTitle)` 호출
4. `AppModel.renameSession(id:title:)` → `core.updateSessionTitle(id:title:)`
5. `liveSessions` 및 사이드바 summary의 title 즉시 업데이트
6. `SessionTabBarView`의 탭 제목도 자동 반영 (같은 SessionViewData 참조)

## Files to Modify

| 파일 | 변경 |
|------|------|
| `libs/project-core/src/store.zig` | `listProjectSummaries` JOIN 변경, `updateSessionTitle` 추가 |
| `libs/project-core/src/c_api.zig` | `project_summary_t` 확장, `update_session_title` 추가 |
| `libs/project-core/src/models.zig` | `SessionSummary` 타입 추가 |
| `libs/project-core/include/project_core.h` | C 헤더 업데이트 |
| `libs/project-core/tests/store_test.zig` | rename 테스트 추가 |
| `apps/macos/StatefulTerminal/Bridge/ProjectCoreClient.swift` | summary 파싱 확장, updateSessionTitle 추가 |
| `apps/macos/StatefulTerminal/Models/ProjectViewData.swift` | SessionSummary 타입, ProjectSummaryViewData 확장 |
| `apps/macos/StatefulTerminal/Models/AppModel.swift` | idleSessionIDs, renameSession, idle 타이머 |
| `apps/macos/StatefulTerminal/Views/SidebarView.swift` | expandedProjectIDs, 토글, session 목록 렌더링 |
| `apps/macos/StatefulTerminal/Views/SessionSidebarRow.swift` | 새 파일 |
| `apps/macos/StatefulTerminal/Terminal/GhosttyTerminalHost.swift` | lastOutputTime 추가 |
| `apps/macos/StatefulTerminal/Terminal/TerminalHostProtocol.swift` | lastOutputTime 프로토콜 추가 |
| `apps/macos/StatefulTerminalTests/MockProjectCoreClient.swift` | updateSessionTitle mock |

## Verification

```bash
# Zig 테스트
cd libs/project-core && zig build test

# Swift 빌드 + 테스트
cd apps/macos && xcodegen generate --spec project.yml
xcodebuild test -project StatefulTerminal.xcodeproj \
  -scheme StatefulTerminal -destination 'platform=macOS'

# 수동 확인
# 1. 앱 실행 → 사이드바에 세션 목록 보이는지
# 2. project 이름 클릭 → 토글 동작
# 3. 세션 더블클릭 → 이름 변경
# 4. 10초 대기 → idle 뱃지 표시
```
