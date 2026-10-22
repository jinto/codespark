# Intent: 숨은 탭이 GPU 메모리를 놓게 한다

- Date: 2026-10-23
- Status: draft
- Next: spec.md

## Problem
9일째 켜 둔 앱의 footprint가 3.7GB였다. 그중 3.2GB가 GPU 메모리다(IOSurface 1.6GB = 21.4MB × 78장, IOAccelerator 1.6GB). 살아 있는 탭은 19개이고, 탭당 렌더 타겟이 약 4장이다. 4K 창 기준으로 탭 하나가 약 170MB를 쓴다.
누수는 아니다. 모든 세션이 `MainContentView`의 ZStack에 상시 마운트되고, 비활성 탭은 `isHidden`만 켜진다. 우리가 고정한 Ghostty(`.ghostty-version` = `ee236e9a`, 2026-04-06)는 표면이 살아 있는 동안 GPU 자원을 놓지 않는다. 앱은 숨은 탭을 Ghostty에 알리지도 않는다(`ghostty_surface_set_occlusion` 호출 0건).

## 업스트림이 이미 고쳤다
ghostty-org/ghostty#14017 "renderer: release GPU resources for hidden surfaces (macOS)"(mitchellh, 2026-08-25 머지, 머지 커밋 `683d8db6`).
- 표면이 invisible이 되면(`setVisible(false)`, 즉 occlusion) swap chain 렌더 타겟, uniform/cell 버퍼, 폰트 텍스처를 놓고 다음 draw에서 다시 만든다.
- 측정치(보이는 탭 1개 + 숨은 탭 20개): `footprint` IOSurface 309MB → 15MB, `MTLDevice.currentAllocatedSize` 393MB → 20MB, 다시 보일 때 재생성은 평균 0.43ms.
- 우리 고정 커밋보다 1,752커밋 뒤에 있다. 정식 릴리즈(v1.3.1)에는 아직 들어가지 않았고 main에만 있다.

그래서 처음에 계획한 (a) 자체 패치와 (b) 업스트림 PR은 필요 없어졌다. 같은 변경이 이미 업스트림에 있다.

## Proposed outcome
1. `.ghostty-version`을 `683d8db6` 이후 커밋으로 올린다.
2. 앱이 탭을 숨기고 보일 때 `ghostty_surface_set_occlusion(surface, visible)`을 부른다. 이 호출이 없으면 1번은 아무 효과가 없다. 업스트림 수정의 계기가 바로 occlusion이다.
- 성공 기준: 같은 탭 수에서 업그레이드 전후 `footprint`를 비교해, 숨은 탭 몫의 IOSurface와 IOAccelerator가 사라진다. 탭 전환 시 낡은 프레임이나 빈 화면이 보이지 않는다(CLAUDE.md의 "Ctrl-L로 살아나는 빈 화면" 오라클).

## Affected users and systems
- 탭을 많이 열어 두는 사용자, 특히 고해상도 창을 쓰는 사용자.
- `vendor/ghostty` 고정 버전, 로컬·CI 빌드(zig 버전), `GhosttyRuntime`(C API 콜백), `GhosttyTerminalSurfaceView`의 숨김/표시 경로.

## Constraints
- 1,752커밋을 건너뛰므로 버전 올리기 자체가 작업이다. 지금 보이는 깨짐은 다음과 같다.
  - `minimum_zig_version` 0.15.2 → 0.16.0. 로컬 zig와 `release.yml` 모두 해당한다.
  - `ghostty_runtime_read_clipboard_cb`의 반환형이 `bool`에서 `ghostty_clipboard_read_result_e`로 바뀐다(`GhosttyRuntime.swift:113`).
  - `ghostty_app_key_is_binding`이 제거된다(현재 미사용).
- CLAUDE.md의 Ghostty 관련 실측 지식(크기 no-op, 0×0, `userdata`, `wait-after-command`, 폰트 fallback, terminfo 경로, shell integration)은 업스트림 코드에 기대고 있다. 올린 뒤 각 항목의 근거 코드가 여전히 같은지 다시 확인한다.
- 숨김 알림은 포커스(`set_focus`)와 다른 질문이다. 탭이 보이는지와 키를 받는지는 따로 판정한다.

## Out of scope
- 자체 Ghostty 패치 메커니즘, 업스트림 PR.
- 오래 안 본 탭의 셸을 종료하는 설계.
- 복원이 탭을 쌓는지(살아 있는 셸 19개)에 대한 조사.

## Open questions
- 어느 커밋에 고정할지: 머지 커밋 `683d8db6` vs 그 뒤 main의 안정된 지점. #14589(SharedGrid 락 hang, mitchellh가 수정)처럼 우리 사용 패턴(에이전트 TUI 다수, 장기 가동)과 맞닿은 수정이 그 뒤에 있는지 본다.
- Kitty 이미지 자원은 업스트림도 아직 놓지 않는다고 적어 두었다. 우리 사용자에게 의미가 있는지.
