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
- Project name + branch shown via `.navigationTitle` / `.navigationSubtitle` in detail column
- Sidebar hidden when no projects exist, auto-shown on first project add
- Sidebar toggle persisted via `@AppStorage(StorageKeys.isSidebarVisible)`

## Terminal State Detection

Process detection + screen parsing replaces the old hook system:
- **Level 1**: `proc_listchildpids(shellPID)` — child process = running
- **Level 2**: `extractSnapshot()` screen pattern matching — shell prompt = idle, `>` + `?` = needsInput
- 5s debounce on active session output, 10s polling for inactive sessions
- `TerminalStateDetector` is a pure-function enum for testability

## Session Restore

탭의 정체성은 "셸 프로세스"가 아니라 "일하던 자리"다. 프로세스는 앱과 함께 죽고, 자리를 복원한다.

- **cwd 추적**: Ghostty `GHOSTTY_ACTION_PWD`(OSC 7) → `AppModel.sessionDidReportCwd` → `last_cwd`. 값이 실제로 바뀔 때만 store에 쓴다.
  - OSC 7은 Ghostty **shell integration이 주입돼야** 나온다. 빌드 페이즈가 `vendor/ghostty/zig-out/share/ghostty/shell-integration`을 `Contents/Resources/ghostty/`로 복사하고, `GhosttyRuntime.initialize()`가 `ghostty_init` **전에** `GHOSTTY_RESOURCES_DIR`를 거기로 설정한다. 이게 빠지면 cwd 추적이 조용히 죽는다.
  - 임베디드 surface는 `ghostty_surface_userdata()`가 nil이다. 탭 식별은 raw surface 포인터 비교로 한다.
- **워크스페이스 소속**: 세션 행의 `workspace_path`에 생성 시점 고정. `cd`로 탭이 사이드바에서 이동하면 안 된다. 빈 값(컬럼 이전 행)만 `last_cwd` 기반 매칭으로 폴백.
- **종료**: `saveAllSessionsForRestore()`는 최종 스냅샷만 저장하고 **세션을 닫지 않는다**. 행이 `live`로 남아야 다음 실행의 `reconcileInterruptedSessions()`가 `interrupted`로 전환하고, 복원은 그걸 읽는다. 여기서 닫으면 복원이 종료 타이밍에 좌우되는 복불복이 된다.
- **시작**: `load()`가 자동 복원한다. 각 탭은 자기 `last_cwd`로, SSH는 `remotePath`를 통한 `cd` 주입으로 돌아간다.
- **중복 방지 (중요)**: 복원한 `interrupted` 행은 `consumeInterruptedSession`으로 즉시 닫는다. 안 그러면 다음 실행에서 그 행이 자기 대체 세션과 **함께** 복원돼 탭이 매번 2배가 된다. 또 `reconcileInterruptedSessions`는 시작 시 남아 있던 `interrupted` 행을 먼저 폐기한다 — 그래야 복원 대상이 "직전 실행의 탭"으로 한정된다.
- **고스트**: 종료 직전 화면을 `RestoredScreenGhost`로 흐리게 덮고 첫 키 입력에 사라진다. 실제 스크롤백이 아니라 오버레이다.

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
