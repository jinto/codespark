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
  - **경로는 그 워크트리인 행에 붙는다**: 펼치면 프로젝트 행은 머리말이 되므로 경로를 놓고(`showsWorktreeRows(for:)`), main 워크트리 행이 받는다(`worktreePathLine(for:)`). 접혀 있거나 워크트리가 1개면 프로젝트 행이 계속 들고 있다 — 그 행이 곧 그 워크트리이므로. 연결된 워크트리는 디렉터리명이 브랜치명을 따라가서 경로가 행 제목의 반복이라 안 붙인다.
- **펼침**: **프로젝트 행 클릭이 곧 토글이다**(`selectProjectAndToggleWorktrees`). 디스클로저 삼각형(▶/▼)은 없앴다 — 8pt짜리 과녁이라 조준이 어렵고, 있고 없고에 따라 제목이 가로로 밀렸다. 행 전체가 과녁이고 클릭은 선택 + 펼치기를 겸한다.
  - **트리 유무를 먼저 묻지 않고 토글한다.** 선택이 git으로 워크트리 목록을 새로 읽으므로 캐시가 비어 있는 첫 클릭에는 "없음"으로 보인다 — 가드를 두면 이번 세션에 처음 여는 프로젝트마다 첫 클릭을 삼킨다. 워크트리가 1개면 아무것도 안 그리는 플래그만 저장될 뿐이다.
  - `expandedProjectIDs`(UserDefaults 저장)가 기준이고 **다른 프로젝트의 선택과는 무관하다** — Cmd+1로 옮겨가도 열어둔 트리는 그대로다. 선택된 프로젝트는 `workspaces`(라이브)를, 나머지는 `liveSessionDetails`를 그룹핑해 행을 만든다.
  - **UI 테스트 주의**: 삼각형이 사라지면서 "워크트리 여러 개인 프로젝트"를 공짜로 걸러주던 수단도 사라졌다. 이제 모든 행이 클릭을 받으므로 `projectRowWithATree()`가 눌러보고 `worktreeBranch` 개수가 변하는 행을 찾는다. `worktreeDisclosure`를 찾던 옛 방식대로 두면 테스트가 **조용히 skip되며 통과**한다.
  - **캐시 주의**: `GitWorktreeService.refreshWorktrees(for:)`는 **넘기지 않은 경로의 캐시를 지운다**. 선택된 프로젝트 하나만 넘기면 나머지 프로젝트의 워크트리 행이 통째로 사라진다 — 항상 `worktreeProjectPaths`(로컬 프로젝트 전부)를 넘길 것.
- **스코프**: 탭바·`Cmd+[/]`·새 탭은 전부 `activeWorkspacePath` 기준(`visibleSessions`). 안 보이는 워크트리의 Ghostty surface는 계속 살아 있다 — `terminalContent`는 여전히 `allSessions`를 순회해야 한다.
- **순서 (중요)**: `recomputeWorkspaces()`는 **선택 대입보다 먼저** 실행해야 한다. `activeWorkspacePath`의 `didSet`이 `workspaces`를 읽기 때문에, 낡은 그룹핑이면 방금 만든 탭을 못 보고 선택을 옛 탭으로 되돌린다.
- **재귀**: `activeSessionID`와 `activeWorkspacePath`의 `didSet`이 서로를 부른다. `workspaceSelectedSessions`를 **먼저** 쓰고 부등호 가드로 끊는 순서가 종료 조건이다.
- **기억은 두 겹**: `workspaceSelectedSessions`(워크스페이스→탭)와 `projectSelectedWorkspaces`(프로젝트→워크스페이스). 돌아왔을 때 "떠난 자리"로 복귀하려면 둘 다 필요하다.
  - `apply(detail:)`는 기억된 워크트리로 열고, 그게 사라졌을 때만 프로젝트 경로로 떨어진다.
  - `attachLiveSessions()`는 **첫 탭이 아니라 기억된 탭**을 고른다. 여기서 `visibleSessions.first`를 쓰면 워크트리별 기억이 프로젝트를 오갈 때마다 덮여쓰인다.
  - 탭이 자기 워크트리를 데려오는 규칙(`activeSessionID.didSet`)은 **그 워크트리가 아직 존재할 때만** 적용된다. 사라진 워크트리 경로를 들고 사이드바를 옮기면 안 된다.
- **선택은 존재하는 워크스페이스만 가리킨다**: 없는 경로에 서 있으면 `visibleSessions`가 비고 메인 영역이 빈 화면이 된다. `recomputeWorkspaces()`가 정정하는데, 조건이 두 겹으로 좁다.
  - `worktrees`가 **nil이나 빈 배열이면 정정하지 않는다**. git 조회 실패와 "워크트리가 삭제됨"은 다르다 — 구분하지 않으면 git이 한 번 실패할 때마다 사용자를 작업 중인 워크트리에서 끌어낸다.
  - `apply(detail:)`은 recompute 전에 `activeWorkspacePath = nil`을 넣는다. 전환 중엔 선택이 아직 *이전* 프로젝트를 가리키므로, 안 비우면 정정 로직이 그걸 "사라진 워크트리"로 보고 **새 프로젝트의 기억을 읽기도 전에 덮어쓴다**.
- **메인 영역은 탭바를 따른다**: 렌더 분기는 `liveSessions`가 아니라 `visibleSessions` 기준. 프로젝트에 탭이 있어도 *지금 워크트리*에 없으면 "New Terminal"을 내밀어야 한다.
- **전환 수단**: 사이드바 행 클릭 + `Cmd+Opt+[`/`]` 순환 + `Cmd+1…9`. 사이드바를 숨기면 클릭 경로가 사라지므로 핫키가 없으면 다른 워크트리의 탭이 고립된다.
  - `Cmd+1…9`는 프로젝트가 아니라 **탭이 살아 있는 워크스페이스**(`numberedWorkspaces`)를 가리킨다. 사이드바 순서대로 매기고, 워크트리 1개짜리 프로젝트는 프로젝트 행 자체가 그 워크스페이스다. 빈 워크트리는 번호를 받지 않고, **트리 접기/펼치기는 번호를 바꾸지 않는다** — 손가락 기억이 깨지면 안 되기 때문. 열린 탭이 하나도 없으면 번호도 없다.
  - **배지는 화면에 있는 행이 대신 쓴다**(`numberedIndex(forProject:)`): 트리가 펼쳐져 있으면 워크트리 행이 자기 숫자를 달고 프로젝트 행은 비운다. 접혀 있으면 그 행들이 없으므로 **프로젝트 행이 안쪽 첫 숫자를 대신 단다** — 안 그러면 Cmd로 갈 수 있는 자리인데 화면 어디에도 번호가 안 보인다.
  - 단축키 등록 규칙은 아래 "Keyboard Shortcuts" 참고.

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
- **cwd 추적**: Ghostty `GHOSTTY_ACTION_PWD`(OSC 7) → `AppModel.sessionDidReportCwd` → `last_cwd`. 값이 실제로 바뀔 때만 store에 쓴다.
  - OSC 7은 Ghostty **shell integration이 주입돼야** 나온다. 빌드 페이즈가 `vendor/ghostty/zig-out/share/ghostty/shell-integration`을 `Contents/Resources/ghostty/`로 복사하고, `GhosttyRuntime.initialize()`가 `ghostty_init` **전에** `GHOSTTY_RESOURCES_DIR`를 거기로 설정한다. 이게 빠지면 cwd 추적이 조용히 죽는다.
  - 임베디드 surface는 `ghostty_surface_userdata()`가 nil이다. 탭 식별은 raw surface 포인터 비교로 한다.
  - `sessionDidReportCwd`는 `liveSessions`가 아니라 **`allSessions`**를 본다. 선택되지 않은 프로젝트의 탭도 셸이 살아 있어 `cd`할 수 있고(그 탭에서 도는 에이전트), 좁은 목록을 읽으면 그 보고가 버려져 스토어에 낡은 경로가 남는다.
  - SSH 탭의 `cwd`는 **원격 경로 그대로** 넘긴다. 그 인자가 Ghostty의 working directory이면서 동시에 스토어에 기록되는 탭 위치인데, 원격에는 shell integration이 없어 OSC 7으로 다시 채워지지 않는다. nil로 바꾸면 다음 복원부터 자리를 잃는다. Ghostty는 열 수 없는 working directory를 경고 로그만 남기고 무시한다(`embedded.zig`).
- **워크스페이스 소속**: 세션 행의 `workspace_path`에 생성 시점 고정. `cd`로 탭이 사이드바에서 이동하면 안 된다. 빈 값(컬럼 이전 행)만 `last_cwd` 기반 매칭으로 폴백 — 이 판정이 `SessionViewData.belongs(to:)` 하나에 모여 있고, 그룹핑과 **워크트리 삭제가 같은 걸 써야 한다**. 삭제를 cwd로 판정하면 밖으로 `cd`한 탭이 살아남고 남의 워크트리 방문객이 대신 닫힌다. 복원이 `workspaceSelectedSessions`에 쓰는 키도 **`workspace_path`다** — `last_cwd`로 쓰면 워크트리 안쪽 디렉터리에서 끝난 탭이 어떤 워크스페이스도 답하지 않는 키에 기억된다.
- **종료**: `saveAllSessionsForRestore()`는 최종 스냅샷만 저장하고 **세션을 닫지 않는다**. 행이 `live`로 남아야 다음 실행의 `reconcileInterruptedSessions()`가 `interrupted`로 전환하고, 복원은 그걸 읽는다. 여기서 닫으면 복원이 종료 타이밍에 좌우되는 복불복이 된다.
- **시작**: `load()`가 자동 복원한다. 각 탭은 자기 `last_cwd`로, SSH는 `remotePath`를 통한 `cd` 주입으로 돌아간다.
- **중복 방지 (중요)**: 복원한 `interrupted` 행은 `consumeInterruptedSession`으로 즉시 닫는다. 안 그러면 다음 실행에서 그 행이 자기 대체 세션과 **함께** 복원돼 탭이 매번 2배가 된다. 또 `reconcileInterruptedSessions`는 시작 시 남아 있던 `interrupted` 행을 먼저 폐기한다 — 그래야 복원 대상이 "직전 실행의 탭"으로 한정된다.
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
- 서명: Developer ID Application (QN9P7KSSMU)
- 산출물: `CodeSpark-v{VERSION}.dmg` (릴리즈에 자동 첨부)

## Known Issues

- SSH remote sessions: terminal state detection works via screen parsing only (no shell PID access for remote processes)
