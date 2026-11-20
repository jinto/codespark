# Plan: 숨은 탭이 GPU 메모리를 놓게 한다

- Spec: spec.md (approved 2026-10-23)
- Status: approved (2026-11-20, rev 2)

순서가 중요하다. 메모리 기준선(0단계)은 업그레이드 **전** 빌드로만 잴 수 있다.

## 0. 기준선 측정 (업그레이드 전)
- [ ] 현재 HEAD를 Release로 빌드한다. `vendor/ghostty`는 `ee236e9a`다. dev 앱을 띄운다.
- [ ] 같은 창 크기에서 탭 11개(보이는 탭 1, 숨은 탭 10)를 연다. `footprint -p <pid>`에서 IOSurface(장수와 크기)와 IOAccelerator를 기록한다. `sample <pid> 2`로 앱이 앞일 때와 배경일 때의 CVDisplayLink 스레드 수도 기록한다.
  → verify: `docs/2026-10-23-hidden-tab-gpu-memory.md`에 남긴다. 숨은 탭 하나에 IOSurface 약 4장이 잡혀 있어야 한다.

## 1. zig 0.16 + Ghostty `b58ef1d67` (한 커밋)
**두 개를 나눌 수 없다.** Ghostty의 `requireZig`(`src/build/zig.zig`)는 minor 버전이 어긋나면 양쪽 방향 모두 `@compileError`를 낸다. zig 0.16으로는 `ee236e9a`를 빌드할 수 없고, 0.15로는 `b58ef1d67`을 빌드할 수 없다. 따로 커밋하면 그 사이의 커밋은 릴리즈 태그를 붙이면 CI에서 죽는다.

- [ ] **zig 찾기**: 빌드 페이즈(`project.yml`과 pbxproj), `.githooks/pre-commit`, `scripts/build-ghostty.sh` 세 곳 모두 후보 맨 앞에 `/opt/homebrew/opt/zig@0.16/bin/zig`(brew keg-only)를 둔다. `build-ghostty.sh`도 맨 `zig` 대신 `"$ZIG"`로 부른다. 런타임 버전 비교는 넣지 않는다. 버전이 틀리면 `requireZig`(Ghostty)와 `minimum_zig_version`(workspace-core)이 이미 크게 실패한다. 실패 메시지가 brew 명령을 가리키도록, 찾지 못했을 때의 안내만 `brew install zig@0.16`으로 바꾼다.
- [ ] **TDD 게이트**: 먼저 `ReleaseWorkflowTests`를 추가해 빨간불을 확인한다. 검사하는 것은 두 가지다. `release.yml`의 setup-zig 버전, `libs/workspace-core/build.zig.zon`의 `minimum_zig_version`, `vendor/ghostty`의 `build.zig.zon` `minimum_zig_version`이 모두 같은지(`.zig-version` 파일은 만들지 않는다. 기준점은 고정된 Ghostty다). 그리고 세 호출부가 keg 경로를 첫 후보로 두는지.
- [ ] workspace-core: `minimum_zig_version`을 0.16.0으로 올리고, `tests/store_test.zig`를 0.16 API로 옮긴다. `src/`는 그대로 빌드된다(실측).
- [ ] `release.yml`: setup-zig 0.16.0으로 바꾸고 주석도 고친다.
- [ ] `vendor/ghostty`를 `b58ef1d67…`(전체 40자)로 옮기고 `.ghostty-version`을 갱신한 뒤, `scripts/build-ghostty.sh`로 빌드한다.
- [ ] **C API 변경 목록**(헤더 diff로 확인. 앱이 쓰는 63개 심볼은 모두 존재한다):
  - `read_clipboard_cb`: 인자가 6개로 늘고 반환형이 `ghostty_clipboard_read_result_e`가 된다. "읽지 않음"에 해당하는 값을 반환한다. `confirm_read_clipboard_cb` 타입도 맞춘다.
  - **`ghostty_clipboard_content_s`에 `len`이 추가되고 `data`는 더 이상 NUL로 끝나지 않는다.** 필드 추가라서 **컴파일러가 잡지 못한다.** `GhosttyRuntime.swift`의 `String(cString: data)`는 버퍼를 넘어 읽는다(복사 / OSC 52). `data[0..<len]`로 문자열을 만든다.
  → verify: `zig build test`(workspace-core)와 Release 빌드, 유닛 전체, `AppBundleMetadataTests`가 초록이다. 복사(Cmd+C)와 `printf '\e]52;c;%s\a' $(printf 한글abc | base64)`로 클립보드에 정확히 `한글abc`가 들어가는지 확인한다.

## 2. CLAUDE.md 실측 지식 재검증 (spec §5)
fable이 이미 확인한 항목: `updateSize` no-op, `wait-after-command`(`:533`→`:571`), `child_exited`(`:1225`→`Surface.zig:1281`), resourcesdir, `Exec.zig` TERMINFO와 integration, `/bin/bash` 거부, SharedGrid negative cache. 동작은 그대로이고 줄 번호만 바뀌었다.
- [ ] 아직 안 읽은 고변동 파일부터 확인한다. `src/termio/stream_handler.zig`(OSC 7 `isLocal`, percent-decode, OSC 777 → DESKTOP_NOTIFICATION), `src/config/Config.zig`(`font-family` 반복이 fallback 추가로 동작하는지. 한글 글꼴 항목이 여기에 기댄다), `Surface.zig`.
- [ ] 바뀐 줄 번호를 CLAUDE.md에 반영한다. 동작이 바뀐 항목이 나오면 멈추고 사용자에게 보고한다.
  → verify: 항목별 "그대로 / 줄 번호만 / 동작 변경" 표를 docs에 남긴다.

## 3. occlusion 알림 (TDD, 별도 커밋)
- [ ] **빨강: AppKit 가정 테스트.** 진짜 근거는 AppKit에 있으므로, 표면 없이 기록하는 NSView 하위 클래스로 잰다. `AppKitResponderAssumptionTests`와 같은 방식이다.
  - (a) 창이 없는 뷰의 `isHidden`을 바꿔도 `viewDidHide`/`viewDidUnhide`가 오는가
  - (b) 조상을 숨겨도 오는가
  - (c) 창을 miniaturize하면 `didChangeOcclusionStateNotification`이 오는가. 테스트 환경에서 재지 못하면 수동 오라클로 돌리고 그 사실을 적는다.
- [ ] **빨강: 소스 게이트**(`SurfaceLifecycleTests`).
  - `ghostty_surface_set_occlusion` 호출부는 `GhosttyTerminalSurfaceView.swift` 하나뿐이어야 한다.
  - `private var surfaceVisible = true`. `test_a_surface_starts_believing_what_libghostty_believes`에 grep 한 줄을 추가한다.
- [ ] **초록**: 뷰에 `surfaceVisible` 미러와 `syncVisibility()`를 둔다. 판정은 `window != nil && !isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible)`를 인라인으로 쓴다(세 조건의 AND라 별도 타입을 만들지 않는다). 바뀌었을 때만 `ghostty_surface_set_occlusion`을 부른다. 호출 시점은 init 직후(미러는 true로 시작하고 false를 한 번 보낸다. b58의 swap chain은 lazy라서, 첫 draw 전에 숨김을 들은 탭은 렌더 타겟을 **아예 만들지 않는다**), `viewDidHide`/`viewDidUnhide`, `viewDidMoveToWindow`(**`syncSurfaceSize` 뒤에**. 그래야 즉시 그리는 첫 draw가 올바른 크기로 나간다), 창의 occlusion 알림(`windowKeyObservers` 목록에 더한다)이다.
- [ ] `updateNSView`의 `ghostty_surface_refresh`는 유지한다. visible이 되면 Thread가 즉시 `renderCallback`을 돌리므로 draw가 한 번 중복될 뿐이고, 같은 렌더 스레드의 mailbox라 경쟁도 없다(fable 확인). codex는 제거를 제안했지만, 기존 게이트 `test_a_surface_coming_back_into_view_is_told_to_paint`가 이 호출을 지키고 있고 이득이 한 프레임이라 범위 밖으로 둔다.
  → verify: 유닛 전체가 초록이다. 미러 초기값을 false로 바꾸면 게이트가 빨개진다.

## 4. 실측 검증 (spec §6)
자동화로 GPU 해제를 관측할 방법은 없다(유닛 환경은 표면을 못 만든다). 게이트는 소스 게이트와 아래 수동 오라클이다. kitty 바이트 오라클과 같은 모양이다.
- [ ] 0단계와 같은 조건에서 `footprint`를 다시 잰다.
  → **기대치를 미리 정해 둔다**: 숨은 탭마다 IOSurface 4장 중 **3장이 사라지고 1장은 남는다.** CoreAnimation 레이어 `contents`가 마지막 프레임을 쥐고 있고, 렌더러는 그걸 비우지 않는다(`IOSurfaceLayer`). 이 덕분에 다시 보일 때 빈 화면이 깜빡이지 않는다. IOAccelerator는 거의 0이어야 한다. Kitty 이미지 자원은 업스트림도 놓지 않으므로 이미지가 없는 탭으로 잰다. 사용자 기계(19탭, 4K)로 환산하면 3.2GB에서 약 0.4GB 남짓이 된다.
- [ ] 화면 오라클:
  - 출력이 끝난 탭에서 다른 탭에 갔다 오기
  - **탭 없는 워크트리를 거쳐 돌아오기**. 이때는 모든 표면의 `window`가 nil이 되므로, 이제 **보이던 탭의 GPU 상태까지** 놓았다가 다시 만든다. 가장 위험한 경로다.
  - 창 최소화 후 복원
  - 시트를 띄운 상태에서 탭 전환
  
  모두 빈 화면이나 낡은 프레임 없이 그려져야 한다. WINCH 트랩으로 크기 신호가 없음을 확인하고, 복원 재생에서 한글이 보이는지, kitty 키보드 바이트 오라클이 통과하는지 확인한다.
- [ ] 배터리: 앱이 배경일 때 `sample`의 CVDisplayLink 스레드가 0인지 본다. **오라클 문장이 바뀐다.** `6688aa072`(idle이면 display link를 멈춘다) 이후로는 앱이 앞에 있어도 idle이면 0이고, `97f57edcc` 이후로는 보이지만 포커스가 없는 탭이라도 출력 중이면 1이 될 수 있다. 회귀가 아니다.
- [ ] XCUITest: 입력 소스는 ABC로 하고 워크트리 재료를 준비한다. skip이 0이어야 한다.
  → verify: 결과를 docs에 기록한다.

## 5. 리뷰와 마무리
- [ ] 구현 리뷰를 codex와 fable에게 병렬로 받는다. 지적을 반영한다.
- [ ] `ponytail-review`를 돌린다.
- [ ] CLAUDE.md:
  - Ghostty Integration 절에 occlusion 규칙(무엇을 위해 부르는지, 왜 true로 시작하는지, 포커스와 독립이라는 점, 1장이 남는 이유)과 clipboard `len` 함정을 추가한다.
  - 배터리 오라클 문장을 고친다.
  - Release 절에 zig 버전은 고정된 Ghostty를 따른다고 적는다.

## 커밋 단위
1(zig + Ghostty + C API) → 2(CLAUDE.md 줄 번호) → 3(occlusion) → 4·5(docs). 각 커밋은 pre-commit 훅을 통과해야 한다. 1과 3을 섞지 않아서, 업그레이드가 회귀를 내면 occlusion과 따로 되돌릴 수 있게 한다.

## 리뷰에서 받지 않은 것
- codex: "occlusion의 C API 전이를 런타임으로 검사하는 테스트". 유닛 환경은 표면을 만들 수 없다. AppKit 가정 테스트, 소스 게이트, 수동 오라클로 대신한다.
- codex: `ghostty_surface_refresh` 제거. 위 3단계 참고.
- fable 대안: occlusion을 옛 Ghostty에 먼저 싣기(CPU 절감만 있다). 업그레이드가 막힐 때만 고려한다.
