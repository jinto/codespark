# CodeSpark

macOS terminal multiplexer powered by [Ghostty](https://ghostty.org) engine.

## Build

```bash
# 1. Build GhosttyKit (ReleaseFast required — debug build has 100x slower allocator)
cd vendor/ghostty
zig build -Doptimize=ReleaseFast -Demit-xcframework=true

# 2. Build CodeSpark
xcodebuild -project apps/macos/CodeSpark.xcodeproj -scheme CodeSpark \
  -configuration Release -derivedDataPath /tmp/CodeSparkDerivedData \
  -destination 'platform=macOS' build
```

## Ghostty Integration

Reference implementation: `vendor/ghostty/macos/Sources/Ghostty/`

When modifying terminal code, always check the official Ghostty source first:
- **Key input**: `NSEvent+Extension.swift` (`ghosttyCharacters`, `ghosttyKeyEvent`)
- **Surface sizing**: `SurfaceView_AppKit.swift` (`sizeDidChange`, `convertToBacking`)
- **Wakeup/tick**: `Ghostty.App.swift` (`wakeup`, `appTick`)
- **Scroll view**: `SurfaceScrollView.swift` (layout, synchronization)

Key patterns:
- `ghostty_surface_set_size` expects **physical pixels** (use `convertToBacking`)
- Control characters (< 0x20) must be sent as original char + Ctrl modifier, not raw control code
- Ghostty manages its own Metal layer — do NOT set `wantsLayer = true`
- `close_surface_cb` receives **surface's NSView userdata** (not runtime userdata) + `processAlive` bool
- One surface per session — host owns it, `TerminalSurfaceHostView` borrows via `surfaceNSView`
- `config.command`은 **`/bin/sh -c`로 실행된다** (`embedded.zig`의 `.{ .shell = cmd }`). 즉 명령 문자열은 만들 때가 아니라 **로컬 셸이 파싱한 뒤**의 argv가 진짜다. `&&`, `;`, `$VAR`를 따옴표 없이 넣으면 원격이 아니라 여기서 해석된다 — 명령 문자열만 비교하는 테스트로는 절대 안 보인다(`SSHConnectionInfoTests`의 stub `ssh` argv 테스트 참고)

## Architecture

```
apps/macos/CodeSpark/
  App/          — CodeSparkApp entry point, AppDelegate, window
  Models/       — AppModel (state), view data types
  Views/        — SwiftUI views (Sidebar, MainContent, Settings, Onboarding)
  Terminal/     — Ghostty integration (Runtime, SurfaceView, Host, Protocol)
  Bridge/       — workspace-core C FFI bridge
  Services/     — GitBranchService, GitWorktreeService, TerminalFontSettings, TerminalStateDetector
  Theme/        — AppTheme colors
```

## Window Layout

Uses `NavigationSplitView` with `.windowToolbarStyle(.unifiedCompact)`:
- Sidebar icons (toggle, +) placed via `.toolbar` in sidebar column
- Project name via `.navigationTitle`; `.navigationSubtitle` shows `activeBranchLabel` — the **활성 워크트리의** 브랜치, 프로젝트 경로의 브랜치가 아니다
- Sidebar hidden when no projects exist, auto-shown on first project add
- Sidebar toggle persisted via `@AppStorage(StorageKeys.isSidebarVisible)`

### 선택은 색으로만 말한다

클릭으로 상태가 바뀌는 행의 라벨은 **글꼴 두께를 고정한다**. 선택은 배경과 글자색이 말하고, 두께는 관여하지 않는다.

- **왜**: `weight: isSelected ? .semibold : .regular`은 글자 폭까지 바꾼다. 누른 행의 글자들이 커서 밑에서 제자리 리플로우되고, 클릭이 딸깍이 아니라 덜컹으로 읽힌다. 색만 바뀌면 폭은 그대로다.
- **게이트**: `test_no_row_label_reweights_itself_when_selected`가 `Views/`를 훑어 `weight: is… ?` 패턴을 거부한다. 뷰를 렌더해 값을 읽는 테스트로는 안 보이는 종류라 소스에서 막는다.

## Worktree Scoping

탭은 워크트리 소속이다. 사이드바가 계층, 탭바가 그 안의 탭이다.

- **표시**: 워크트리가 2개 이상일 때만 `sidebarWorktrees(for:)`가 자식 행을 낸다. 1개면 평면 — 프로젝트 행이 곧 그 워크트리고, 모든 프로젝트에 "main" 한 줄이 붙는 건 노이즈다.
  - **경로는 그 워크트리인 행에 붙는다**: 펼치면 프로젝트 행은 머리말이 되므로 경로는 main 워크트리 행이 받는다(`worktreePathLine(for:)`). 접혀 있거나 워크트리가 1개면 프로젝트 행이 계속 들고 있다 — 그 행이 곧 그 워크트리이므로. 연결된 워크트리는 디렉터리명이 브랜치명을 따라가서 경로가 행 제목의 반복이라 안 붙인다.
  - **프로젝트 행의 부제는 비지 않는다**(`projectInfoLine(for:)`). 상태마다 *다른 사실*을 말한다: 접히면 정체(`main`/`non-git`/원격은 `main on emac`)에 규모를 덧붙이고(`main · 3 worktrees`), 펼치면 규모만 말한다(`3 worktrees`) — 정체는 바로 아래 main 행이 이어받으므로. 개수를 아직 모르면(캐시 콜드) 정체만, `non-git`을 조회 전에 말하지 않는 것과 같은 규칙이다.
    - **왜**: 예전엔 펼쳤을 때 이 줄을 `.opacity(0)`으로 감추고 자리만 남겼다. 그런데 자식이 전부 접히는 상태(아래 "탭 없는 워크트리는 접힌다")가 겹치면 이름 밑에 설명 없는 빈 줄만 남아 렌더 오류로 읽힌다. 게다가 `expandedProjectIDs`는 UserDefaults에 남고 "전부 보기"는 메모리라, 그게 **재실행 때마다의 기본 상태**였다.
    - 접힌 행의 개수는 **클릭하면 트리가 열린다는 유일한 예고**이기도 하다. 삼각형을 없앤 뒤로 펼침 여부를 말하는 것은 이 줄뿐이다.
    - **원격 행도 브랜치로 시작한다**(`main on emac`). 호스트만 말하면 한 상자에 프로젝트가 여럿일 때 사이드바를 내려가며 같은 단어만 반복되고, 정작 행마다 다른 것은 안 보인다. 브랜치가 앞이고 호스트가 뒤인 이유: 다른 것이 앞에 와야 눈이 훑는다. 그러면 로컬 행과도 줄이 맞는다 — 모든 프로젝트의 부제가 브랜치로 시작한다.
      - 브랜치의 출처는 **워크트리 스캔의 main 워크트리**다. `gitBranches`는 로컬 전용이고(`git -C`는 이쪽에서 돈다) 원격 경로를 넣으면 안 되므로. 스캔 전이거나 `remotePath` 없는 `ssh://host`면 호스트만 말한다 — 안 물어보고 브랜치를 말하는 건 `non-git`을 조회 전에 말하는 것과 같은 추측이다.
    - 개수의 출처는 `worktreeCount(for:)` = `gitWorktreeService.worktrees(for:)`. `sidebarWorktrees(for:)`를 쓰면 안 된다 — 그건 선택된 프로젝트만 라이브 그룹핑을 읽어서, 클릭 한 번에 숫자가 변한다.
- **펼침**: **프로젝트 행 클릭이 곧 토글이다**(`selectProjectAndToggleWorktrees`). 디스클로저 삼각형(▶/▼)은 없앴다 — 8pt짜리 과녁이라 조준이 어렵고, 있고 없고에 따라 제목이 가로로 밀렸다. 행 전체가 과녁이고 클릭은 선택 + 펼치기를 겸한다.
  - **트리 유무를 먼저 묻지 않고 토글한다.** 선택이 git으로 워크트리 목록을 새로 읽으므로 캐시가 비어 있는 첫 클릭에는 "없음"으로 보인다 — 가드를 두면 이번 세션에 처음 여는 프로젝트마다 첫 클릭을 삼킨다. 워크트리가 1개면 아무것도 안 그리는 플래그만 저장될 뿐이다.
  - `expandedProjectIDs`(UserDefaults 저장)가 기준이고 **다른 프로젝트의 선택과는 무관하다** — Cmd+1로 옮겨가도 열어둔 트리는 그대로다. detail이 도착한 프로젝트는 `workspaces`(라이브)를, 나머지는 `liveSessionDetails`를 그룹핑해 행을 만든다(아래 `selectedProject` 항목).
  - **UI 테스트 주의**: 삼각형이 사라지면서 "워크트리 여러 개인 프로젝트"를 공짜로 걸러주던 수단도 사라졌다. 이제 모든 행이 클릭을 받으므로 `projectRowWithATree()`가 눌러보고 `worktreeBranch` 개수가 변하는 행을 찾는다. `worktreeDisclosure`를 찾던 옛 방식대로 두면 테스트가 **조용히 skip되며 통과**한다.
  - **탭 없는 워크트리는 접힌다**(`sidebarWorktreeRows(for:)`, `·· N more`). 접히지 않는 것 셋: 탭이 있는 것(= `Cmd` 숫자가 가리키는 곳), **`projectSelectedWorkspaces`에 기록된 마지막으로 서 있던 워크트리**, 그리고 **`main`은 언제나**. 앞의 둘을 "지금 선택된 워크트리"로 판정하면 선택이 행 개수를 바꾼다 — 클릭 한 번에 `2 more`가 `1 more`가 되고 화면엔 다른 변화가 없다. main이 예외인 이유는 위와 같다: 펼친 트리는 최소 한 줄의 실체를 보여야 한다.
  - **`prunable`은 이유를 달고 온다**: git은 `prunable <reason>`을 찍지 `prunable` 한 단어를 찍지 않는다. 완전 일치로 비교하던 동안 **prunable 워크트리가 한 번도 걸러지지 않았고**, 디렉터리가 사라진 워크트리가 사이드바에 남아 클릭하면 없는 경로에 서게 됐다.
    - 걸러낼 때 **"첫 번째" 표시를 지우면 안 된다**: 그 플래그는 "우리가 남기는 것 중 첫 번째"라는 뜻이다. 지우면 첫 stanza가 prunable일 때 **main 워크트리가 하나도 없는 목록**이 나오고, `projectIdentityLine`의 `.first(where: \.isMainWorktree)?.branch`가 nil이 되어 원격 행이 조용히 브랜치를 잃는다.
  - **밖에서 만든 워크트리는 폴링으로만 발견된다**: 앱이 만든 것(`addWorktree`)은 즉시 반영되지만, 에이전트가 탭 안에서 만든 것이나 다른 체크아웃의 것은 10초 타이머가 찾는다. 타이머는 `NSApp.isActive`일 때만 돌고 TTL은 30초(실패 60초)라 최대 ~40초. **앱이 배경에 있으면 아예 돌지 않으므로** 활성화되는 순간(`didBecomeActiveNotification`) 한 번 더 묻는다 — 안 그러면 몇 시간 자리를 비운 뒤 돌아와도 다음 tick까지 낡은 목록을 본다.
  - **조회 실패는 로그로 남긴다**: 실패하면 그 프로젝트의 워크트리 행이 조용히 하나로 접힌다. stderr를 버리던 동안에는 왜 그런지 알아낼 방법이 아무 데도 없었다.
  - **캐시 주의**: `GitWorktreeService.refreshWorktrees(for:)`는 **넘기지 않은 경로의 캐시를 지운다**. 선택된 프로젝트 하나만 넘기면 나머지 프로젝트의 워크트리 행이 통째로 사라진다 — 항상 `worktreeProjectPaths`(워크트리를 가질 수 있는 프로젝트 전부, 원격 포함)를 넘길 것.
- **스코프**: 탭바·`Cmd+[/]`·새 탭은 전부 `activeWorkspacePath` 기준(`visibleSessions`). 안 보이는 워크트리의 Ghostty surface는 계속 살아 있다 — `terminalContent`는 여전히 `allSessions`를 순회해야 한다.
- **`workspaces`는 `selectedProject`의 것이다 — `selectedProjectID`의 것이 아니다**. ID는 클릭/숫자를 누른 즉시 움직이고 detail은 git 왕복 뒤에 온다. 그 사이 `workspaces`는 **떠나온 프로젝트**를 설명하므로, `workspaces(for:)`가 ID로 판정하면 두 행이 동시에 거짓말한다 — 펼쳐둔 트리가 한 프레임 접혔다 펴지고(`showsWorktreeRows`가 빈 목록을 보므로), 워크트리가 없는 프로젝트가 남의 워크트리 네 줄을 잠깐 입는다(숫자가 들어오는 길에 트리를 열어두므로). 배지도 같은 그룹핑을 읽으니 `Cmd`를 누른 채로 번호가 출렁인다. detail이 도착하기 전까지 프로젝트는 **자기 요약**이다 — 선택 안 된 행들이 이미 읽는 그것.
  - 눈으로만 보이는 한 프레임이라 테스트는 왕복 중간에 들여다본다(`modelWithASlowLookup`). 끝난 뒤 상태를 보는 테스트로는 한 개도 안 잡힌다.
- **순서 (중요)**: `recomputeWorkspaces()`는 **선택 대입보다 먼저** 실행해야 한다. `activeWorkspacePath`의 `didSet`이 `workspaces`를 읽기 때문에, 낡은 그룹핑이면 방금 만든 탭을 못 보고 선택을 옛 탭으로 되돌린다.
  - **탭을 만들었으면 그 자리에서 다시 그룹핑한다**: 탭바는 `visibleSessions`를 거쳐 그룹핑을 읽으므로, `liveSessions`에만 넣고 recompute를 안 하면 **아무도 못 보는 탭**이 된다. `startAndAttachSession`이 직접 하는 이유다 — 예전엔 `newSession`만 따로 부르고 복원 경로는 안 불러서, 복원된 탭이 cwd 보고 같은 엉뚱한 계기가 지나갈 때까지 안 보였다.
- **재귀**: `activeSessionID`와 `activeWorkspacePath`의 `didSet`이 서로를 부른다. `workspaceSelectedSessions`를 **먼저** 쓰고 부등호 가드로 끊는 순서가 종료 조건이다.
- **기억은 두 겹**: `workspaceSelectedSessions`(워크스페이스→탭)와 `projectSelectedWorkspaces`(프로젝트→워크스페이스). 돌아왔을 때 "떠난 자리"로 복귀하려면 둘 다 필요하다.
  - `apply(detail:)`는 기억된 워크트리로 열고, 그게 사라졌을 때만 프로젝트 경로로 떨어진다.
  - `attachLiveSessions()`는 **첫 탭이 아니라 기억된 탭**을 고른다. 여기서 `visibleSessions.first`를 쓰면 워크트리별 기억이 프로젝트를 오갈 때마다 덮여쓰인다.
  - 탭이 자기 워크트리를 데려오는 규칙(`activeSessionID.didSet`)은 **그 워크트리가 아직 존재할 때만** 적용된다. 사라진 워크트리 경로를 들고 사이드바를 옮기면 안 된다.
- **선택은 존재하는 워크스페이스만 가리킨다**: 없는 경로에 서 있으면 `visibleSessions`가 비고 메인 영역이 빈 화면이 된다. `recomputeWorkspaces()`가 정정하는데, 조건이 두 겹으로 좁다.
  - `worktrees`가 **nil이나 빈 배열이면 정정하지 않는다**. git 조회 실패와 "워크트리가 삭제됨"은 다르다 — 구분하지 않으면 git이 한 번 실패할 때마다 사용자를 작업 중인 워크트리에서 끌어낸다.
  - `apply(detail:)`은 recompute 전에 `activeWorkspacePath = nil`을 넣는다. 전환 중엔 선택이 아직 *이전* 프로젝트를 가리키므로, 안 비우면 정정 로직이 그걸 "사라진 워크트리"로 보고 **새 프로젝트의 기억을 읽기도 전에 덮어쓴다**.
- **메인 영역은 탭바를 따른다**: 렌더 분기는 `liveSessions`가 아니라 `visibleSessions` 기준. 프로젝트에 탭이 있어도 *지금 워크트리*에 없으면 "New Terminal"을 내밀어야 한다.
  - 그 판단은 **`AppModel.mainAreaContent`** 한 곳에 있다(`sshReconnect` / `restoring` / `empty` / `terminals`). 뷰에서 조건을 다시 늘어놓지 말 것 — 어느 화면이 뜨는지는 앱을 띄워야만 보이는 종류라, 모델에 두어야 테스트가 본다. 실제로 그 덕에 "이미 돌아와 쓸 수 있는 터미널을 진행 화면이 덮는" 순서 실수가 잡혔다.
- **전환 수단**: 사이드바 행 클릭 + `Cmd+Opt+[`/`]` 순환 + `Cmd+1…9`. 사이드바를 숨기면 클릭 경로가 사라지므로 핫키가 없으면 다른 워크트리의 탭이 고립된다.
  - `Cmd+1…9`는 **탭이 있는 자리**를 가리킨다(`numberedPlaces`, 사이드바 순서). 자리는 프로젝트이거나 그 안의 워크트리다(`NumberedPlace`).
    - 워크트리가 여럿인 리포에서는 **탭이 있는 워크트리들이** 각각 번호를 받는다. 일이 벌어지는 곳이 그 워크트리이므로. 빈 워크트리는 받지 않는다 — 뛰어들 데가 아니다.
    - 워크트리가 전부 비었으면 **프로젝트가 자기 이름으로** 번호를 받는다. 탭이 하나도 없는 프로젝트도 마찬가지다 — 탭이 없는 프로젝트야말로 탭을 열러 가는 곳이다.
  - **접힘은 번호를 바꾸지 않는다.** `numberedPlaces`는 `expandedProjectIDs`를 보지 않는다. 워크트리 사이를 걸어다녀도 마찬가지 — 배지가 두 행 사이를 왔다갔다하면 안 되므로 `projectSelectedWorkspaces`도 보지 않는다. 대신 **탭을 열고 닫으면 아래 번호들이 밀린다**; 손가락 기억보다 "일하는 자리로 한 번에"를 택한 거래다.
  - **배지는 한 번에 계산한다**(`numberedBadges`). 행마다 묻는 함수는 **지웠다** — 있으면 매 행이 전체 번호매김을 다시 만들어 사이드바가 프로젝트 수의 제곱만큼 그룹핑을 돌았고, `@Published`가 바뀔 때마다(= 셸이 프롬프트마다 보내는 cwd 보고마다) 그랬다. 뷰는 바디당 한 번 `let`으로 잡는다 — 컴퓨티드 프로퍼티를 행마다 읽으면 같은 제곱이다.
  - **배지만 화면을 따라간다**: 자기 이름으로 번호를 받은 프로젝트 행은 언제나 자기 배지를 단다. 번호가 워크트리 행에 있는 프로젝트는 **펼치면 배지를 놓고**(그 행이 화면에 있으므로), **접히면 자기 안의 첫 번호를 대신 단다** — 접힌 상태에서 그 숫자가 가리킬 수 있는 유일한 행이 그것이다.
  - **숫자는 데려다 준다**: 선택 + 트리 **열기** + 워크트리 번호면 **그 워크트리에 서기**. 프로젝트 번호는 **떠났던 워크트리로 복귀**한다(`projectSelectedWorkspaces`를 `apply(detail:)`이 읽는다). 클릭은 겨냥한 행을 토글하지만 숫자는 "거기로 가 줘"라서, **접지는 않는다** — 두 번 누르면 트리가 펄럭이고, 숫자는 보지 않고 누르라고 있는 것이다.
  - 단축키 등록 규칙은 아래 "Keyboard Shortcuts" 참고.
- **원격(ssh) 프로젝트도 워크트리를 갖는다**: 원격 워크트리의 주소는 `ssh://user@host/remote/path` URI다. `workspacePath`가 소속·선택·복원·삭제가 공유하는 단일 키이므로, 원격도 같은 문자열 공간에 넣어 그 로직을 그대로 쓴다.
  - **두 네임스페이스를 섞지 말 것**: `workspacePath`는 URI, `last_cwd`와 git 인자는 원격 raw 경로다. 변환은 `SSHConnectionInfo.workspaceURI(forRemotePath:)` / `remotePath(fromWorkspaceURI:)` **두 함수 밖에서 하지 않는다**. `git -C 'ssh://…'`는 `cannot change to`로 죽는다.
  - **주소는 git이 부르는 대로 쓴다**: 워크트리를 만든 뒤 경로를 우리가 조립하면 안 된다. git은 심링크가 해소된 경로를 기록하므로(macOS의 `/var` → `/private/var`), 생성 스크립트가 `pwd -P`로 찍어준 걸 그대로 받는다. 철자가 둘이면 워크스페이스가 둘이고, 그중 하나는 아무 탭도 안 가리킨다 — 스텁 테스트로는 안 보이고 실제 ssh 왕복에서만 드러난다.
  - **`remotePath` 없는 `ssh://host`는 스캔하지 않는다** — 리포 위치를 모르므로.
  - **게이트가 두 겹**: `worktreeProjectPaths`의 필터와 `selectProject`의 호출 조건. 하나만 열면 원격 스캔은 아무 증상 없이 죽어 있는다. 그래서 호출부가 `worktreeProjectPaths.contains(...)`로 **같은 질문**을 한다.
  - **조회 실패는 워크트리 삭제가 아니다 — 화면에서도**: 실패해도 캐시가 직전 성공 목록을 유지하고, "지금 다시 읽어라"는 `invalidateCache`가 아니라 **`expireCache`**다. 엔트리를 지워버리면 이어지는 조회가 실패했을 때 남는 게 없고, `groupSessions`가 프로젝트 하나로 재그룹핑해서 워크트리에 서 있던 선택이 아무것도 못 맞춘다(`visibleSessions`가 빈 배열) — 메인 영역이 빈다. 원격은 일상적으로 끊기므로 이게 기본 경로다.
  - **원격 생성은 스크립트 한 번**: `$HOME` 전개·이름 충돌 확인(exit 3)·`git worktree add`·만들어진 경로 출력이 모두 원격에서 한 번에 일어난다. `'~/worktrees'`는 따옴표 안에서 전개되지 않으므로 루트만 `remoteRootExpression`이 따로 다룬다.
  - **삭제는 git이 성공한 뒤에 탭을 닫는다**(로컬도 동일). 순서가 반대면 삭제에 실패해도 터미널만 잃는다. 그래서 삭제 테스트는 `/tmp`의 가짜 경로가 아니라 **진짜 git 워크트리** 위에서 돈다 — 가짜 경로에서는 git이 실패해 테스트가 아무것도 검증하지 못한다.
  - **동시 ssh는 4개까지**, `ControlMaster`는 쓰지 않는다(고아 마스터·소켓 경로 길이·dead socket 재사용을 들이는 대가가 지연시간 절약보다 크다). refresh는 겹치면 버리지 않고 **줄을 선다** — 버리면 워크트리 생성/삭제 직후의 refresh가 사라진다.

## Keyboard Shortcuts

앱 단축키는 **반드시 `AppShortcuts.swift`의 `AppShortcut`에 케이스로 선언**하고 `.keyboardShortcut(.그케이스)`로 쓴다. 시트 안의 `.defaultAction`/`.cancelAction`은 메뉴 단축키가 아니므로 예외다.

- **왜**: 터미널이 메뉴보다 먼저 키를 본다. `KeyEventRouter`가 `forwardToKeyDown`으로 보내는 조합은 메뉴 아이템이 **아예 안 눌리고** 터미널에 raw 이스케이프만 찍힌다. 액션 함수 테스트로는 절대 안 보인다 — `Cmd+Ctrl+S`가 그래서 오래 죽어 있었다.
- **라우터 기준**: Ctrl 단독은 셸, Cmd+Ctrl은 메뉴.
- **게이트 2겹**:
  - `test_every_app_shortcut_reaches_the_menu` — 선언된 모든 조합이 `.delegateToSuper`인지 검사하고 실패 시 어느 단축키인지 이름을 찍는다. 충돌 검사도 함께.
  - pre-commit 훅이 인라인 `keyboardShortcut("…"`을 거부한다. 표를 우회하면 테스트가 볼 수 없기 때문.
- **3겹째 (pre-push, XCUITest)**: `test_cmd_ctrl_s_toggles_the_sidebar_with_a_terminal_open`이 실제 앱에서 조합을 눌러 동작까지 확인하고, `test_declared_commands_are_wired_to_menu_items`가 선언만 하고 Button에 안 붙인 경우를 잡는다.
  - **터미널이 열려 있어야 재현된다.** `performKeyEquivalent`는 윈도우 뷰 트리를 훑으므로 세션이 없으면 가로챌 Ghostty surface가 없어 버그가 숨는다. 이 조건을 빼먹으면 테스트가 통과하면서 아무것도 못 잡는다.
  - UI 테스트는 앱을 띄우고 포커스를 뺏어서 pre-commit이 아니라 **pre-push**에 있다.
  - `testmanagerd`가 오래 떠 있으면 "Timed out while enabling automation mode"로 러너가 안 뜬다. `kill $(pgrep -x testmanagerd)`로 내리면 launchd가 다시 만든다(SIP 때문에 `launchctl kickstart`는 막힌다).

## Terminal State Detection

Process detection + screen parsing replaces the old hook system:
- **Level 1**: `proc_listchildpids(shellPID)` — child process = running
- **Level 2**: `extractSnapshot()` screen pattern matching — shell prompt = idle, `>` + `?` = needsInput
- 5s debounce on active session output, 10s polling for inactive sessions
- `TerminalStateDetector` is a pure-function enum for testability

## Session Restore

탭의 정체성은 "셸 프로세스"가 아니라 "일하던 자리"다. 프로세스는 앱과 함께 죽고, 자리를 복원한다.

- **순서는 연 순서다**: `store.zig`의 `sessionsForProject`가 내주는 배열이 곧 탭바의 왼쪽→오른쪽이고, 복원도 그 순서로 다시 연다. 그래서 `order by created_at asc`다 — `updated_at`으로 정렬하면 rename이나 `cd` 한 번에 탭이 자리를 옮기고, 실행 중엔 오른쪽에 붙던 새 탭이 프로젝트를 다시 읽는 순간 맨 왼쪽으로 튄다. 인메모리 `liveSessions`는 append(오른쪽)이므로 스토어가 내림차순이면 둘이 어긋난다.
- **탭을 닫으면 왼쪽 이웃으로 간다**(`terminalHostDidClose`). 눈이 이미 거기 있으므로. 예전엔 "남은 것 중 첫 번째"라서 어느 탭을 닫든 맨 왼쪽으로 튀었다 — 일하던 탭을 닫으면 탭바 반대편으로 던져지고 걸어 돌아와야 했다. 맨 왼쪽 탭은 왼쪽이 없으니 오른쪽에게 넘긴다.
  - **테스트는 세 번째 탭을 닫아야 한다**. 두 번째를 닫으면 "맨 왼쪽"이 곧 "왼쪽 이웃"이라 옛 코드로도 통과한다.
- **cwd 추적**: Ghostty `GHOSTTY_ACTION_PWD`(OSC 7) → `AppModel.sessionDidReportCwd` → `last_cwd`. 값이 실제로 바뀔 때만 store에 쓴다.
  - OSC 7은 Ghostty **shell integration이 주입돼야** 나온다. 빌드 페이즈가 `vendor/ghostty/zig-out/share/ghostty/shell-integration`을 `Contents/Resources/ghostty/`로 복사하고, `GhosttyRuntime.initialize()`가 `ghostty_init` **전에** `GHOSTTY_RESOURCES_DIR`를 거기로 설정한다. 이게 빠지면 cwd 추적이 조용히 죽는다.
  - 임베디드 surface는 `ghostty_surface_userdata()`가 nil이다. 탭 식별은 raw surface 포인터 비교로 한다.
  - `sessionDidReportCwd`는 `liveSessions`가 아니라 **`allSessions`**를 본다. 선택되지 않은 프로젝트의 탭도 셸이 살아 있어 `cd`할 수 있고(그 탭에서 도는 에이전트), 좁은 목록을 읽으면 그 보고가 버려져 스토어에 낡은 경로가 남는다.
  - SSH 탭의 `cwd`는 **원격 경로 그대로** 넘긴다. 그 인자가 Ghostty의 working directory이면서 동시에 스토어에 기록되는 탭 위치다. nil로 바꾸면 다음 복원부터 자리를 잃는다. Ghostty는 열 수 없는 working directory를 경고 로그만 남기고 무시한다(`embedded.zig`).
  - **원격도 OSC 7을 보낸다 — 우리가 심어서**(`RemoteCwdReporter`). 예전엔 원격에 shell integration이 없어 `last_cwd`가 탭을 연 순간에 얼어붙었고, 원격에서 `cd`한 자리는 복원 때마다 사라졌다. 이제 접속 스크립트가 원격 셸의 시작 파일을 하나 놔두고 프롬프트마다 OSC 7을 찍게 한다.
    - **payload는 URI다 — `$PWD`를 percent-encoding 해야 한다.** Ghostty는 OSC 7을 `std.Uri`로 파싱하고 경로를 **percent-decode** 한다(`termio/stream_handler.zig`). 날것으로 찍으면 `a%20b`라는 디렉터리가 `a b`로 돌아오고, 이름에 `#`나 `?`가 있으면 **거기서 잘린다**(각각 fragment·query 구분자라서). 탭의 cwd가 조용히 다른 디렉터리가 되고 다음 복원이 그리로 간다. Ghostty 자신의 통합은 인코딩한다 — 우리 재구현만 안 했다.
      - 패턴은 대괄호로 쓴다(`${p//[#]/%23}`): `\#`는 Swift raw string(`#"…"#`)에서 이스케이프로 읽히고, `?`는 셸 글로브 와일드카드라 어차피 감싸야 한다.
    - **hostname은 반드시 `localhost`다.** Ghostty는 local이 아닌 host의 OSC 7을 **버린다**(`termio/stream_handler.zig`의 `hostname.isLocal`). 원격 셸이 자기 `$HOST`를 찍으면 로그 한 줄 남기고 사라진다 — Ghostty 자신의 zsh 통합을 그대로 원격에 갖다 놔도 안 되는 이유이고, 이 한 글자가 기능 전체를 좌우한다.
    - **셸마다 주입 지점이 다르다**: zsh는 `ZDOTDIR`, bash는 `PROMPT_COMMAND`(환경변수), fish는 `-C`. 함수는 `exec`을 건너지 못하므로 zsh·fish는 시작 파일/초기 명령이라야 하지만, bash의 `PROMPT_COMMAND`는 문자열이라 환경변수로 건너간다 — 그게 bash를 로그인 셸로 만들 수 있는 유일한 이유다(아래). 모르는 셸은 그냥 셸을 연다 — 최악이 예전 동작이어야 한다.
    - **fish는 `fish_prompt`가 아니라 `--on-variable PWD`**다. `fish_prompt` 이벤트는 tty가 없으면 아예 안 뜨고, 어차피 우리가 알고 싶은 건 디렉터리가 바뀌는 순간이다.
    - **`/etc/zshrc`가 우리 두 파일 사이에서 돈다**: 그때의 `ZDOTDIR`로 `HISTFILE`을 잡으므로, 우리 `.zshrc`가 되돌려놓지 않으면 **원격 셸의 히스토리가 우리 캐시로 옮겨간다**. `.zshenv`는 반대로 되돌리면 안 된다 — zsh가 우리 `.zshrc`를 못 찾는다.
    - 시작 파일은 `~/.cache/codespark/shell`에 **고정 경로**로 둔다. `mktemp -d`는 그걸 읽은 셸만 지울 수 있어서, 프롬프트까지 못 간 접속마다 원격에 쓰레기가 쌓인다.
    - **테스트는 진짜 셸에 물린다**(`SSHConnectionInfoTests`). 이 기능의 실패는 전부 셸 시작 순서에 있고, 명령 문자열을 비교하는 테스트로는 한 개도 안 보인다 — 위의 HISTFILE 이동도 그렇게 잡혔다.
    - **알려진 대가**: Ghostty는 이 보고를 로컬 surface의 pwd로도 받으므로, ssh 탭의 proxy icon이 이 기계에 없는 경로를 가리킨다.
  - **원격 셸은 로그인 셸이다**(`exec $SHELL -l -i`). macOS의 기본 PATH는 `/usr/libexec/path_helper`가 만들고 그걸 부르는 건 `/etc/zprofile` 한 곳뿐이라, 로그인이 아니면 `/etc/paths.d/*`를 아예 안 읽는다 — `.zshrc`는 돌아서 `vi`가 `nvim`으로 별칭되는데 `nvim`은 PATH에 없는 상태가 된다. `~/.zprofile`·`~/.bash_profile`에 넣어둔 것(Homebrew 공식 안내 위치)도 전부 같이 사라진다. Ghostty가 로컬 셸을 `login(1)`으로 여는 게 정확히 이 이유이므로(`termio/Exec.zig`), 원격만 아니면 한 앱의 두 반쪽이 서로 다른 기계가 된다.
    - **`-l`은 셸마다 주입 지점과 다르게 충돌한다. 셋 다 재봤다**:
      - **zsh**: `.zprofile`과 `.zlogin`도 `$ZDOTDIR`에서 읽는다 — 우리 것. `.zprofile`은 `.zshenv`와 같은 왕복을 하는 시임을 하나 더 놔야 한다. **`.zlogin`은 필요 없다** — 우리 `.zshrc`가 이미 `ZDOTDIR`를 사용자에게 돌려준 뒤라 사용자 것이 그대로 잡힌다.
      - **bash**: 로그인 셸이 되는 순간 **`--rcfile`이 무시된다**. 그래서 훅을 환경으로 넘긴다. 대가: 시작 파일이 `PROMPT_COMMAND`를 이어붙이지 않고 **대입**하면 리포터가 죽는다(셸은 멀쩡, cwd만 멈춤). 그리고 로그인 bash는 `.bashrc`가 아니라 `.bash_profile`을 읽는다 — 이 기계의 다른 모든 터미널과 같은 동작이다.
      - **fish**: 충돌 없음. `-C`가 `-l` 아래서 그대로 돈다.
    - **모르는 셸에는 `-l`을 붙이지 않는다**: `dash`는 `-l`을 거부하고, `exec`이 실패하면 사용자가 터미널을 잃는다.
  - **원격 cwd를 로컬 git에 넘기지 말 것**: `git -C`는 이쪽에서 도는데 원격 경로는 저쪽 것이라, 이름이 같은 로컬 디렉터리가 대신 답한다. `gitBranchQueryPaths`가 걸러낸다 — 원격이 이제 `cd`마다 보고하므로 안 거르면 상시로 들어온다.
- **워크스페이스 소속**: 세션 행의 `workspace_path`에 생성 시점 고정. `cd`로 탭이 사이드바에서 이동하면 안 된다. 빈 값(컬럼 이전 행)만 `last_cwd` 기반 매칭으로 폴백 — 이 판정이 `SessionViewData.belongs(to:)` 하나에 모여 있고, 그룹핑과 **워크트리 삭제가 같은 걸 써야 한다**. 삭제를 cwd로 판정하면 밖으로 `cd`한 탭이 살아남고 남의 워크트리 방문객이 대신 닫힌다. 복원이 `workspaceSelectedSessions`에 쓰는 키도 **`workspace_path`다** — `last_cwd`로 쓰면 워크트리 안쪽 디렉터리에서 끝난 탭이 어떤 워크스페이스도 답하지 않는 키에 기억된다.
- **종료**: `saveAllSessionsForRestore()`는 최종 스냅샷만 저장하고 **세션을 닫지 않는다**. 행이 `live`로 남아야 다음 실행의 `reconcileInterruptedSessions()`가 `interrupted`로 전환하고, 복원은 그걸 읽는다. 여기서 닫으면 복원이 종료 타이밍에 좌우되는 복불복이 된다.
- **시작**: `load()`가 자동 복원한다. 각 탭은 자기 `last_cwd`로, SSH는 `remotePath`를 통한 `cd` 주입으로 돌아간다.
- **폐기는 한 세대 뒤에**: `reconcileInterruptedSessions`가 시작 시 남아 있던 `interrupted` 행을 폐기하는데, **전부가 아니라 최신 세대를 뺀 나머지**다. 한 번의 reconcile이 `now()` 하나로 그 실행의 탭 전부를 찍으므로 `updated_at`이 곧 세대 번호다.
  - **왜**: 복원은 탭마다 왕복 하나(원격이면 접속까지)라 느리고, 행은 하나씩 `interrupted`에서 빠진다. 중간에 죽으면 나머지가 남는데, 예전에는 다음 실행이 **읽기 전에 전부 닫았다** — 아직 안 돌아온 탭이 조용히 영구 삭제됐다. "복원 안 한 것"과 "복원 중에 죽은 것"은 데이터상 구분되지 않으므로, 추측으로 지우는 대신 한 세대 더 남긴다.
  - **대가**: 다시 안 여는 프로젝트는 탭을 한 번 더 제안받는다. 누적은 여전히 **두 세대로 경계**가 있다.
- **중복 방지 (중요)**: 복원한 `interrupted` 행은 `consumeInterruptedSession`으로 즉시 닫는다. 안 그러면 다음 실행에서 그 행이 자기 대체 세션과 **함께** 복원돼 탭이 매번 2배가 된다. 폐기 규칙은 위 "폐기는 한 세대 뒤에" 참고.
- **복원은 진행을 말한다**: 탭마다 왕복이 한 번이고 ssh면 그 위에 원격 접속이 얹히므로, 복원은 눈에 보일 만큼 걸린다. `AppModel.restoreProgress`(nil = 복원 중 아님)가 `completed`/`total`을 들고, 아직 아무것도 못 돌려놨으면 화면 전체가, 첫 탭이 돌아온 뒤에는 터미널 위의 띠가 그걸 말한다(`restoreBannerProgress`). 로컬·원격 구분이 없다 — 루프가 구분하지 않으므로.
  - **돌아온 탭이 자리를 갖는다**: 진행 화면이 복원 끝까지 터미널을 덮으면 안 된다. 쓸 수 있게 된 탭은 즉시 화면을 갖고, 남은 것은 띠로 밀려난다.
  - **`ProgressView(value:)`를 쓰지 말 것**: 자기 값을 향해 애니메이션하는데 카운트마다 뷰가 다시 만들어져 **끝내 도달하지 못한다**. 화면에는 "5 of 6" 옆에 텅 빈 바가 떴다. 채워진 길이만큼 직접 그린다(`progressBar`). 숫자를 검사하는 테스트로는 안 보인다 — 숫자는 내내 옳았다.
  - **알려진 한계**: ssh 탭은 세션이 *시작*되면 완료로 센다. 원격 접속이 끝나기를 기다리지 않으므로 마지막 탭에서 바가 100%인데 화면은 아직 연결 중일 수 있다.
- **이전 화면 재생**: 종료 직전 화면은 오버레이가 아니라 **진짜 스크롤백**으로 돌아온다. `RestoredScreenReplay`가 화면을 임시 파일에 담고, 그걸 `cat`하는 명령을 Ghostty `initial_input`(= pty 입력)으로 주입한다. 페이로드가 `ESC[2J`로 시작해 주입 명령의 에코를 지우므로, 흐린 이전 화면 아래에 새 프롬프트가 찍힌다.
  - Ghostty에는 화면에 직접 쓰는 API가 없고, `sh -c '…; exec $SHELL'` 래핑은 `shell_integration.zig`의 shell 검출에 걸려 integration이 아예 주입되지 않는다(→ cwd 추적 사망). 그래서 셸에게 시키는 우회가 유일한 길이다.
  - **알려진 대가**: 주입 명령이 셸 히스토리에 남는다. 복원된 탭에서 Up을 누르면 `cat /var/folders/…`가 뜬다.
  - **SSH 탭은 다른 길**: `initial_input`은 pty로 들어가므로 원격 셸이 그걸 읽는다 — 로컬 임시 파일 경로를 원격에 타이핑하는 꼴이라 `No such file or directory`만 남는다. 그래서 SSH는 payload를 `RestoredScreenReplay.inlineCommand`(= `printf '%b' '…'`)로 만들어 **ssh 원격 명령 안에** 실어 보낸다. pty에 아무것도 타이핑하지 않으니 에코도 히스토리 오염도 없다.

## Remote Folder Picker

SSH 프로젝트의 **기본 폴더는 URI의 경로 부분**이다(`ssh://user@host:port/경로`). New SSH Project 시트의 `Browse…`가 원격을 훑어 그 칸을 채우면 나머지는 기존 길을 그대로 탄다 — `createProject`가 URI로 저장하고, `startSession`이 `ssh -t 'cd 경로 && exec $SHELL'`로 연다. `RemoteDirectoryLister`가 목록을, `RemoteFolderPickerSheet`/`RemoteFolderPickerModel`이 화면을 맡는다.

- **원격 셸이 한 번 더 파싱한다**: ssh는 뒤따르는 인자를 공백으로 이어 붙여 원격 *로그인 셸*에 넘긴다. 그래서 스크립트를 `/bin/sh -c '<script>'` **한 단어로 감싸서** 보낸다. 안 감싸면 `;`와 `$e`가 저쪽에서 먹힌다 — `config.command`가 로컬 `/bin/sh`를 거치는 것과 같은 함정의 원격판.
- **`~`만 원격에 맡긴다**: `remoteExpression(for:)`이 선행 `~`만 `"$HOME"`으로 남기고 나머지는 통째로 따옴표에 넣는다. 경로를 그냥 노출하면 `$(...)`가 원격에서 실행된다.
- **마커 뒤부터가 답이다**: 수다스러운 `.bashrc`는 우리 스크립트보다 먼저 찍는다. `__CODESPARK_LS__` 줄 다음이 payload고, 마커가 없으면 `malformedOutput` — 첫 줄을 경로로 믿으면 "Welcome to prod!"에 들어가 앉는다.
- **BatchMode 고정**: 비밀번호를 묻는 호스트에서 피커가 멈추면 안 된다. 못 열면 배너만 띄우고 **경로 입력창은 그대로 살려둔다** — 브라우징 실패가 프로젝트 생성을 막지 않는 게 설계다.
- **stdout/stderr를 동시에 비운다**: 배너가 긴 호스트에서 stderr 파이프가 차면, stdout부터 끝까지 읽는 코드는 교착한다.
- **`Process.waitUntilExit()`를 async 안에서 부르지 말 것**: 이 함수는 **부르는 스레드의 런루프**를 돈다. `await` 뒤에는 cooperative 풀의 다른 스레드에서 재개될 수 있고, 그 런루프는 종료 통지를 못 받아 **ssh가 죽은 지 한참 뒤에도 영원히 매달린다**. `run()` **전에** `terminationHandler`를 걸고 continuation으로 받는다(`exitStatus(of:)`). 단독 실행에선 잘 통과하다가 전체 스위트에서만 걸리는 종류라, `test_listing_returns_every_time_instead_of_hanging`이 라운드 사이에 MainActor 홉을 끼워 강제로 재현한다.
- **실패해도 서 있던 자리는 지킨다**: `RemoteFolderPickerModel.move(to:)`는 호스트가 답한 경로만 반영한다. 못 여는 폴더를 눌러도 목록은 그대로고 배너만 바뀐다.
- **마지막에 요청한 사람이 답을 갖는다**: 클릭 하나가 `Task` 하나라 왕복 두 개가 동시에 날아다닐 수 있다. 모든 왕복은 `beginRequest()`로 세대 번호를 받고, 응답이 돌아왔을 때 그 번호가 아직 최신일 때만 상태를 쓴다. 안 그러면 느린 응답이 나중에 도착해 **사용자를 방금 떠난 폴더로 되돌린다**. **목록뿐 아니라 `createFolder()`도 포함**이다 — mkdir 왕복 중에 다른 폴더로 옮기면, 늦게 온 생성 결과가 사용자를 새 폴더로 끌고 간다.
- **선택은 화면에 있는 것만 가리킨다**: 숨김 폴더를 고른 뒤 토글을 끄면 `Choose`가 화면에 없는 경로를 내놓는다. `showsHiddenFolders`의 `didSet`이 안 보이게 된 선택을 버린다.

## Testing

**TDD**: 중요 기능은 반드시 실패하는 테스트를 먼저 작성한 후 구현한다 (red → green → refactor).

테스트 수준:
- **Unit tests**: 모델 로직, 서비스, 프로토콜 준수 (`ProjectFlowTests` 등)
- **Integration tests**: 화면 캡처(`screencapture`)로 렌더링 검증, 키보드 이벤트 시뮬레이션(`CGEvent`)으로 입력 경로 검증

```bash
# Unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project apps/macos/CodeSpark.xcodeproj \
  -scheme CodeSpark -destination 'platform=macOS'
```

**구현 완료 후 필수 검증 절차:**
1. 유닛 테스트 전체 통과 확인
2. 앱 빌드 후 실행하여 accessibility API (`osascript`)로 UI 요소 존재 확인:
   - 사이드바 toolbar 버튼들 (sidebar toggle, + 버튼)
   - 프로젝트/워크스페이스 행 표시
   - Cmd 홀드 시 핫키 overlay 표시
3. 모든 검증 통과 후에만 완료 보고

## Release

태그 push만으로 CI가 빌드 → 서명 → 공증 → DMG → GitHub Release를 자동 생성한다.

```bash
# 1. 최근 태그 확인
git tag --sort=-v:refname | head -5

# 2. 새 태그 생성 + push (이것만 하면 끝)
git tag v{VERSION}
git push origin v{VERSION}

# gh release create는 하지 말 것 — CI가 자동 생성
```

- CI: `.github/workflows/release.yml` (`on: push: tags: ['v*']`)
- **ghostty는 `.ghostty-version`의 커밋에 고정된다**: `vendor/`는 gitignore라 CI가 직접 받아온다. 예전엔 `main`을 clone해서 **릴리즈가 업스트림과 경주했다** — 우리 쪽 변경이 없어도 어느 날 깨진다(v1.1.4: `read_clipboard_cb`의 인자가 3개에서 6개로 늘었다). 올릴 때는 `vendor/ghostty`를 그 커밋으로 옮기고 `git -C vendor/ghostty rev-parse HEAD > .ghostty-version`, zig 버전도 같이 본다(`build.zig.zon`의 `minimum_zig_version`).
  - `git clone`은 커밋을 못 가리키고 shallow fetch는 **전체 40자 SHA**만 받는다. `ReleaseWorkflowTests`가 이 두 가지를 지킨다 — 유닛 테스트로는 안 보이고 릴리즈가 죽어야만 드러나는 종류라 워크플로 파일을 직접 검사한다.
  - **캐시는 적중한 적이 없다**: 캐시는 ref 단위로 격리되는데 릴리즈는 매번 새 태그에서 돈다. `ghosttykit-relfast-*`는 쓰이기만 하고 읽히지 않는다.
- 서명: Developer ID Application (QN9P7KSSMU)
- 산출물: `CodeSpark-v{VERSION}.dmg` (릴리즈에 자동 첨부)

## Known Issues

- SSH remote sessions: terminal state detection works via screen parsing only (no shell PID access for remote processes)
- 원격 워크트리 스캔은 키 인증(`BatchMode=yes`)이 되는 호스트에서만 동작한다. 비밀번호를 묻는 호스트에서는 워크트리 행이 조용히 안 나온다 — 백그라운드 폴링이 프롬프트에 매달릴 수 없기 때문. 사용자가 직접 누르는 생성/삭제는 실패 시 `loadErrorMessage`에 뜬다.
- IPv6 리터럴 호스트는 `SSHConnectionInfo` 파서(`lastIndex(of: ":")`) 한계로 지원하지 않는다. 원격 워크트리 주소가 이 파서 위에 서 있으므로, 고칠 때 함께 봐야 한다.
