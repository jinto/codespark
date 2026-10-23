# Plan: 숨은 탭이 GPU 메모리를 놓게 한다

- Spec: spec.md (approved 2026-10-23)
- Status: draft

순서가 중요하다. 메모리 기준선(0단계)은 업그레이드 **전** 빌드로만 잴 수 있다.

## 0. 기준선 측정 (업그레이드 전)
- [ ] 현재 HEAD를 Release로 빌드한다. `vendor/ghostty`는 `ee236e9a`다. dev 앱을 띄운다.
- [ ] 같은 창 크기에서 탭 11개(보이는 탭 1, 숨은 탭 10)를 연다. `footprint -p <pid>`에서 IOSurface와 IOAccelerator를 기록한다. `sample <pid> 2`로 앱이 앞일 때와 배경일 때의 CVDisplayLink 스레드 수도 기록한다.
  → verify: 수치를 `docs/2026-10-23-hidden-tab-gpu-memory.md`에 남긴다. 숨은 탭 하나에 IOSurface 약 4장이 잡혀 있어야 한다.

## 1. zig 0.16 툴체인 (Ghostty 전, 단독으로 초록)
zig를 부르는 곳은 셋이다: Xcode 빌드 페이즈(`project.yml`과 pbxproj), `.githooks/pre-commit`, `scripts/build-ghostty.sh`. 셋 다 `command -v zig`부터 찾는다. brew의 `zig`는 이제 0.17이므로 버전이 다른 zig가 조용히 잡힌다.
- [ ] 리포 루트에 `.zig-version`(`0.16.0`) 하나를 둔다. 세 곳 모두 후보 목록 맨 앞에 `/opt/homebrew/opt/zig@0.16/bin/zig`(brew keg-only)를 두고, 실행 전에 `"$ZIG" version`이 `.zig-version`과 같은지 검사한다. 다르면 `brew install zig@0.16` 또는 `ZIG=`로 지정하라는 안내와 함께 `exit 1`.
- [ ] `release.yml`: `setup-zig`의 `version`을 0.16.0으로 바꾸고 주석 근거도 고친다.
- [ ] TDD: `ReleaseWorkflowTests`에 테스트를 먼저 추가한다. `.zig-version` = `release.yml`의 setup-zig 버전 = `libs/workspace-core/build.zig.zon`의 `minimum_zig_version`이고, 세 호출부가 `.zig-version`을 읽는지 본다. 빨간불을 확인한 뒤 고친다.
- [ ] `libs/workspace-core`: `minimum_zig_version`을 `0.16.0`으로 바꾸고, `tests/store_test.zig`를 0.16 API로 옮긴다(`std.time.nanoTimestamp` 등). 본체 `src/`는 그대로 빌드된다(실측).
  → verify: `zig build test --summary all`이 0.16에서 39개 이상 통과한다. pre-commit 훅이 통과한다. 0.15.2나 0.17로 지정하면 훅과 빌드 페이즈가 버전 메시지와 함께 실패한다.

## 2. Ghostty `b58ef1d67`로 올리기
- [ ] `vendor/ghostty`를 `b58ef1d67…`(전체 40자)로 옮기고 `.ghostty-version`을 갱신한다. `scripts/build-ghostty.sh`로 xcframework를 빌드한다.
- [ ] 앱 컴파일 에러를 고친다. `read_clipboard_cb`는 "읽지 않음"에 해당하는 enum 값을 반환한다. 동작은 바꾸지 않는다. 그 밖의 C API 변경은 컴파일러가 알려 주는 대로 최소한으로 고친다.
  → verify: Release 빌드, 유닛 전체, `AppBundleMetadataTests`(terminfo `78/xterm-ghostty`, shell-integration 번들)가 모두 초록이다.

## 3. CLAUDE.md 실측 지식 재검증 (spec §5)
- [ ] spec §5의 항목마다 새 트리에서 근거 코드와 줄 번호를 확인한다. 바뀐 줄 번호와 동작을 CLAUDE.md에 반영한다. 동작이 바뀐 항목이 나오면 멈추고 사용자에게 보고한다(우리 코드가 그 동작에 기대고 있을 수 있으므로).
  → verify: 항목별 "그대로 / 줄 번호만 / 동작 변경" 표를 docs 파일에 남긴다.

## 4. occlusion 알림 (TDD)
- [ ] **빨강**: `SurfaceVisibilityTests`를 만든다. 순수 판정 `TerminalVisibility.isVisible(hasWindow:isHiddenOrHasHiddenAncestor:windowIsVisible:)`를 표로 검사한다. 5가지 경우는 창 없음, 숨김, 조상 숨김, 가려진 창, 보임이다.
- [ ] **빨강**: 소스 게이트. `Terminal/` 밖에서도, 안에서도 `ghostty_surface_set_occlusion`을 부르는 곳은 `GhosttyTerminalSurfaceView.swift` 하나뿐이어야 한다. `SurfaceLifecycleTests`의 `test_only_the_surface_view_claims_the_keyboard`와 같은 방식이다.
- [ ] **초록**: `TerminalFocus.swift` 옆에 `TerminalVisibility` enum을 둔다. 뷰에는 `surfaceVisible = true` 미러와 `surfaceVisibilityDidChange()`(다시 계산하고, 바뀌었을 때만 `ghostty_surface_set_occlusion`)를 둔다. 호출 시점은 init 직후, `viewDidMoveToWindow`, `viewDidHide`, `viewDidUnhide`, 그리고 창의 `didChangeOcclusionStateNotification`이다. 이 알림은 기존 `windowKeyObservers` 목록에 더해 같은 생명주기로 관리한다.
  → verify: 유닛 전체가 초록이다. 미러 초기값을 `false`로 바꾸면 테스트가 실패하는지 확인한다. 실패하지 않으면 그 사실과 이유를 docs에 적는다. 유닛 환경은 표면을 못 만들기 때문이다.

## 5. 실측 검증 (spec §6)
- [ ] 0단계와 같은 조건(창 크기, 탭 11개)에서 `footprint`를 다시 잰다.
  → verify: 숨은 탭 몫의 IOSurface와 IOAccelerator가 사라진다. IOAccelerator가 남는다면 남은 양을 기록한다(intent의 열린 질문).
- [ ] 화면 오라클을 확인한다. 출력이 끝난 탭에서 다른 탭에 갔다 오기, 탭 없는 워크트리를 거쳐 돌아오기, 창 최소화 후 복원이다. 빈 화면이나 낡은 프레임이 없어야 한다. WINCH 트랩으로 크기 신호가 없음을 확인한다. 복원 재생에서 한글이 보이는지 확인한다. kitty 키보드 바이트 오라클(`printf '\e[>11u'; cat -v`)도 돌린다.
- [ ] 배터리: 앱이 배경일 때 `sample`의 CVDisplayLink 스레드가 0이어야 한다.
- [ ] XCUITest: 입력 소스는 ABC로 하고, 워크트리 재료를 준비한다. skip이 0이어야 한다.
  → verify: 결과를 docs 파일에 기록한다. 사용자 기계의 3.7GB 상황에서 기대 절감량을 계산해 적는다.

## 6. 리뷰와 마무리
- [ ] 구현 리뷰를 codex와 fable에게 병렬로 받는다. 지적을 반영한다.
- [ ] `ponytail-review`를 돌린다.
- [ ] CLAUDE.md의 Ghostty Integration 절에 occlusion 규칙을 한 단락으로 추가한다. 무엇을 위해 부르는지, 왜 `true`로 시작하는지, 판정이 포커스와 독립이라는 점이다. Release 절에는 zig 버전이 `.zig-version`을 따른다고 적는다.

## 커밋 단위
1 → 2 → 3 → 4 → 5(docs와 CLAUDE.md). 각 커밋은 pre-commit 훅을 통과해야 한다. 2와 4를 한 커밋에 섞지 않는다. 업그레이드가 회귀를 내면 occlusion과 분리해서 되돌릴 수 있어야 한다.
