# Intent: 숨은 탭이 GPU 메모리를 놓게 한다

- Date: 2026-10-23
- Status: draft
- Next: spec.md

## Problem
9일째 켜 둔 앱의 footprint가 3.7GB였다. 그중 3.2GB가 GPU 메모리다(IOSurface 1.6GB = 21.4MB × 78장, IOAccelerator 1.6GB). 살아 있는 탭은 19개이고, 탭당 렌더 타겟이 약 4장이다. 4K 창 기준으로 탭 하나가 약 170MB를 쓴다.
누수는 아니다. 모든 세션이 `MainContentView`의 ZStack에 상시 마운트되고, 비활성 탭은 `isHidden`만 켜진다. Ghostty 표면은 살아 있는 동안 swap chain의 렌더 타겟 3장(`FrameState.target`)을 놓지 않는다.
앱 쪽에서 쓸 수 있는 수단은 둘 다 막혀 있다.
- `set_size`로 줄이면 그리드가 바뀌어 SIGWINCH가 간다(CLAUDE.md의 0×0 사고와 같다).
- `set_occlusion`은 display link만 멈추고 버퍼는 그대로 둔다(`generic.zig` `setVisible`). 게다가 앱은 지금 이 함수를 부르지도 않는다.

## Proposed outcome
- 숨은 탭은 렌더 타겟을 1×1로 줄여 둔다. 다시 보이면 `drawFrame`의 기존 크기 검사가 원래 크기로 다시 만든다. 그리드와 pty는 건드리지 않는다.
- (a) 위 변경을 리포의 Ghostty 패치로 싣는다. 로컬 빌드(`scripts/build-ghostty.sh`)와 CI(`release.yml`)가 같은 패치를 적용한다.
- 앱은 탭을 숨기고 보일 때 `ghostty_surface_set_occlusion`을 부른다.
- (b) 같은 변경을 업스트림 Ghostty에 제안한다. 받아들여지면 (a)의 패치는 지운다.
- 성공 기준: 같은 탭 수에서 패치 전후 `footprint`의 IOSurface가 "보이는 탭 수 × 약 4장" 수준으로 줄어든다. 탭 전환 시 낡은 프레임이나 빈 화면이 보이지 않는다.

## Affected users and systems
- 탭을 많이 열어 두는 사용자, 특히 고해상도 창을 쓰는 사용자.
- `vendor/ghostty` 빌드 경로(로컬·CI), `GhosttyTerminalSurfaceView`의 숨김/표시 경로.

## Constraints
- 그리드 크기는 바뀌면 안 된다(SIGWINCH 금지).
- 패치는 `.ghostty-version` 커밋 위에 정확히 적용되어야 한다. 적용이 실패하면 빌드도 실패해야 한다(fail-closed). 조용히 패치 없는 빌드가 나오면 안 된다.
- 업스트림 Ghostty 규칙: 처음 기여하는 사람은 vouch 요청 discussion을 **본인 목소리로**(AI 작성 금지) 써서 승인받아야 PR을 열 수 있다. 승인 없이 연 PR은 자동으로 닫힌다. AI 사용은 도구와 범위를 밝혀야 하고, 제출자가 코드를 AI 없이 설명할 수 있어야 한다(`AI_POLICY.md`). 그래서 vouch 요청 글과 PR 제출은 사용자가 직접 한다. Claude는 패치, 측정 자료, 기술 설명 초안만 준비한다.

## Out of scope
- 오래 안 본 탭의 셸을 종료하고 스크롤백만 남기는 설계.
- 복원이 탭을 쌓는지(살아 있는 셸 19개)에 대한 조사. 별건이다.
- IOAccelerator 1.6GB 중 렌더 타겟과 무관한 자원(atlas 등). 측정해서 남는다면 별도로 다룬다.

## Open questions
- IOAccelerator 1.6GB가 IOSurface와 같은 메모리의 이중 집계인지, 별개 자원인지. 패치 전후 측정으로 판정한다.
- 다시 보일 때 첫 프레임이 깜빡이는지. Thread는 `drawFrame`을 `renderer.setVisible(true)`보다 먼저 부른다.
- 레이어 `contents`가 마지막 IOSurface를 붙잡고 있어서 4번째 장이 생기는지. 붙잡고 있다면 숨길 때 비울지.
