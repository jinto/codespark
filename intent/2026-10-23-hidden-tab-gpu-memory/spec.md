# Spec: 숨은 탭이 GPU 메모리를 놓게 한다

- Intent: intent.md (approved 2026-10-23)
- Status: approved (2026-10-23)

## 1. Ghostty 고정 커밋: `b58ef1d67` (main, 2026-10-20)

| 후보 | zig | 비고 |
|---|---|---|
| `683d8db6` (#14017 머지) | 0.16.0 | 최소한. 그 뒤의 렌더러 수정이 빠진다 |
| **`b58ef1d67`** | **0.16.0** | **0.16으로 빌드되는 마지막 main 커밋** |
| `f54340ad` (현재 main) | 0.17.0 | 0.17 이전 직후라 이틀밖에 안 됐다 |

`b58ef1d67`을 고르는 이유: #14017 이후 머지된 렌더러 수정 중 우리 사용 패턴과 맞닿은 것이 들어 있다.
- `6688aa072` park DisplayLink while idle: 배터리. `docs/2026-09-15-idle-tab-battery-drain.md`와 같은 계열이다.
- `97f57edcc` vsync unfocused surfaces while dirty
- `72cf50855` never stop the display link while holding the draw mutex: 교착 방지
- `ffaaf5d7a` only start and stop the CVDisplayLink on the main thread
- `140feb86a` always release shaders when the render thread exits

#14589(SharedGrid 락 때문에 앱 전체가 멈춤, 에이전트 TUI 다수·장기 가동)은 mitchellh에 따르면 Zig 0.16 이전으로 고쳐졌다. 이 수정은 두 후보 모두에 있다.

## 2. zig 0.15.2 → 0.16.0
- `release.yml`의 `setup-zig` 버전, 그리고 그 위 주석의 근거 문장.
- 로컬 개발 기계: brew는 현재 stable로 0.17.0을 준다. 그래서 `scripts/build-ghostty.sh`가 버전이 맞지 않으면 실패하고, 받을 경로를 알려 준다. 빌드는 fail-closed로 한다. 틀린 zig로 빌드한 결과물이 조용히 나오면 안 된다.
- `libs/workspace-core`: 라이브러리 본체는 0.16에서 수정 없이 빌드된다(실측). 다만 `tests/store_test.zig`가 0.16에서 사라진 API(`std.time.nanoTimestamp` 등)를 써서 테스트 빌드가 실패한다. 이 테스트를 0.16으로 옮기고 `build.zig.zon`의 `minimum_zig_version`도 올린다. 하나의 zig로 두 트리를 빌드하는 지금 구조를 유지한다.

## 3. C API 변경 대응 (`ee236e9a` → `b58ef1d67`)
- `ghostty_runtime_read_clipboard_cb`의 반환형이 `bool`에서 `ghostty_clipboard_read_result_e`로 바뀐다. `GhosttyRuntime.swift`는 지금처럼 "읽지 않음"에 해당하는 값을 반환한다. 동작은 바꾸지 않는다.
- 그 밖의 시그니처 변경은 컴파일러가 알려 주는 대로 고친다. 새로 생긴 API(`foreground_pid`, `tty_name`, `paste_text` 등)는 이 작업에서 쓰지 않는다.

## 4. 앱: 표면이 화면에 보이는지를 Ghostty에 알린다

`GhosttyTerminalSurfaceView`가 스스로 계산하고, 바뀔 때만 알린다. focus 미러(`surfaceFocused`)와 같은 모양이다.

- **visible** = `window != nil` && `!isHiddenOrHasHiddenAncestor` && `window.occlusionState.contains(.visible)`
- 미러 `surfaceVisible`는 libghostty처럼 `true`로 시작한다(`Thread.zig`의 `visible: bool = true`). 생성 직후 한 번 다시 계산한다. 이 시점엔 창이 없으므로 false가 간다. 프로젝트를 열 때 한꺼번에 만들어지는 탭들이 visible 상태로 남지 않게 하기 위해서다. focus에서 한 번 겪은 함정과 같다.
- 다시 계산하는 시점: `viewDidMoveToWindow`, `viewDidHide`, `viewDidUnhide`, 창의 `didChangeOcclusionStateNotification`(창 최소화, 다른 Space, 완전히 가려짐). occlusion 옵저버는 기존 `followWindowKey` 옵저버 목록과 같은 생명주기를 따른다.
- 판정은 순수 함수로 둔다(`TerminalFocus` 옆, 이름은 plan에서 정한다). 뷰를 띄우지 않고 표로 테스트할 수 있게 하기 위해서다.
- `updateNSView`의 `ghostty_surface_refresh`는 유지한다. visible 알림이 이제 draw를 걸어 주지만, refresh를 지우는 것은 이 작업의 범위가 아니다. 지운다면 측정으로 근거를 확인한 뒤에 따로 한다.
- 포커스와는 독립적이다. 보이지만 키보드가 없는 탭(다른 앱이 앞에 있는데 창은 보임)은 visible=true, focused=false다.

## 5. CLAUDE.md에 적힌 Ghostty 실측 지식 재검증
새 트리에서 근거 코드가 그대로인지 확인한다. 바뀐 것은 CLAUDE.md를 고친다.
- `embedded.zig`: 크기가 같으면 `updateSize`가 no-op인지, `command` 설정 시 `wait-after-command`가 켜지는지(`:533`), `.shell = cmd`로 실행하는지
- `GridSize.update`의 `@max(1, …)`, `Surface.zig`의 `child_exited` 순서(`:1225`)
- `close_surface_cb`가 `userdata`를 넘기는지
- `resourcesdir.zig`(`:63` sentinel, `:102-111`), `Exec.zig`의 TERMINFO 계산과 `:784-787`
- `shell_integration.zig`가 Apple `/bin/bash`를 거부하는지
- `SharedGrid.getIndex`가 negative match를 캐시하는지. 한글 fallback 항목이 여기에 기대고 있다. #14311/#14312(getIndex 캐시) 계열이 이 부분을 바꿨을 수 있다.
- OSC 7 처리(`stream_handler.zig`의 `isLocal`, percent-decode), OSC 777 → `DESKTOP_NOTIFICATION` 매핑, 렌더러가 `focused`로 생성되는지

## 6. 검증
- **유닛**: visible 판정 표(창 없음 / 숨김 / 조상 숨김 / 가려진 창 / 보임). 소스 게이트: `ghostty_surface_set_occlusion`을 부르는 곳이 이 뷰 하나뿐인지 확인한다(`test_only_the_surface_view_claims_the_keyboard`와 같은 방식).
- **workspace-core**: `zig build test`가 0.16에서 통과해야 한다(CI 단계와 같은 명령).
- **메모리 오라클(수동, 실측)**: 같은 창 크기에서 탭 N개(보이는 탭 1)를 열고 `footprint -p <pid>`의 IOSurface와 IOAccelerator를 업그레이드 전후로 비교한다. 성공 기준은 숨은 탭 몫이 사라지는 것이다. #14017의 수치(숨은 탭 20개 기준 IOSurface 309MB → 15MB)를 기준으로 본다.
- **화면 오라클**: 출력이 끝난 탭에서 다른 탭에 갔다 오기, 탭 없는 워크트리를 거쳐 돌아오기, 창 최소화 후 복원. 셋 모두 빈 화면이나 낡은 프레임 없이 그려져야 한다. CLAUDE.md의 WINCH 오라클로 크기가 변하지 않음도 확인한다(occlusion은 그리드를 건드리지 않아야 한다).
- **기존 게이트**: 유닛 전체, XCUITest(ABC 자판, 워크트리 재료 준비, skip 0), `AppBundleMetadataTests`(terminfo, shell-integration 번들), 한글 렌더(복원 재생에서 한글이 보이는지).
- **배터리 회귀 없음**: `sample <pid> 2`에서 앱이 배경일 때 `CVDisplayLink` 스레드가 0인지 확인한다.

## Out of scope
- 자체 Ghostty 패치, 업스트림 PR.
- Kitty 이미지 자원 해제(업스트림도 미완).
- Ghostty 새 API 활용(`foreground_pid` 등. 상태 감지의 Level 1을 대체할 수 있을지도 모르지만 별건이다).
