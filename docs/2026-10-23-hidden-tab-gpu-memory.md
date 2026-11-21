# 숨은 탭 GPU 메모리 — 실측 기록

intent/spec/plan: `intent/2026-10-23-hidden-tab-gpu-memory/`

## 측정 방법

탭 11개(보이는 탭 1, 숨은 탭 10)를 키 입력 없이 만든다. dev 스토어를 복사해 프로젝트 하나에 `live` 세션 11개만 남기고, 앱을 `CODESPARK_STORE_PATH`로 그 사본에 붙여 띄운다(`open -n --env CODESPARK_STORE_PATH=… CodeSpark.app`). 복원이 탭 11개를 연다. 30초 뒤 `footprint -p <pid>`를 잰다. 탭은 모두 이미지 없는 idle 셸이고, 창 크기는 같다. 개발자의 진짜 스토어는 건드리지 않는다.

이 방법은 SSH에서도 돈다. 화면 캡처와 키 입력은 SSH에서 막히지만 `open`과 `footprint`는 막히지 않는다.

## 결과 (2026-11-22, 이 기계)

| 빌드 | IOSurface | IOAccelerator (graphics) | phys_footprint |
|---|---|---|---|
| 기준선 `ee236e9a` (업그레이드 전) | 35장, 678 MB | 57 MB | 1006 MB |
| 3단계까지 (`b58ef1d67` + occlusion) | 34장, 468 MB | 33 MB | 697 MB |
| 3b 포함 (숨은 동안 bounds 재그림 끔) | **4장, 62 MB** | 7.5 MB | **249 MB** |
| v1.4.0 (`83fb9562`, 2026-11-22) | 4장, 64 MB | 7.5 MB | 275 MB |

- 남은 4장은 보이는 탭 하나 몫이다. 한 번도 안 보인 숨은 탭은 0장이다.
- 창 크기를 바꾼 뒤에도 4장 그대로였다(285 MB). 3b가 막는 바로 그 경로다.
- 숨은 탭을 전부 한 번씩 보고 온 뒤에는 14장이었다. 보였다 숨은 탭이 1장씩 남은 것이다. CoreAnimation 레이어가 마지막 프레임을 쥐고 있어서, 돌아올 때 빈 화면이 깜빡이지 않는다(plan의 기대치).

### 3단계만으로 안 줄었던 이유

Ghostty는 레이어에 `needsDisplayOnBoundsChange = true`를 건다(`renderer/Metal.zig`). 그래서 bounds가 바뀔 때마다 CoreAnimation이 `display` → `drawFrame(true)`을 메인 스레드에서 부른다.

- visible 검사는 렌더 스레드 경로(`Thread.zig`의 `drawFrame`)에만 있다.
- `drawFrameLocked`는 놓았던 swap chain을 다시 만든다.
- 놓는 쪽은 `setVisible(false)` 전이 한 번뿐이다.

SwiftUI는 숨은 탭에도 프레임을 주므로, 마운트할 때와 창 리사이즈 때마다 숨은 탭이 GPU를 되찾았다. fable 리뷰가 소스로 찾았고, 위 표의 둘째 줄이 그 실측이다. 공식 Ghostty 앱은 창 단위로만 가리므로 이 경로를 밟지 않는다.

## CLAUDE.md 재검증 (2단계)

| 항목 | 결과 |
|---|---|
| `updateSize` 같은 크기 no-op | 그대로 |
| `wait-after-command` (`embedded.zig`) | 줄 번호만 (`:533` → `:572`) |
| `child_exited` 순서 (`Surface.zig`) | 줄 번호만 (`:1225` → `:1281`) |
| resourcesdir: release 채택, Debug 폴백, sentinel | 줄 번호만 (`:102-111` → `:111-120`, `:63` → `:64`) |
| `Exec.zig`의 integration 비활성 | 줄 번호만 (`:784-787` → `:791-794`) |
| OSC 7 `isLocal`, percent-decode | 그대로 |
| OSC 777 → DESKTOP_NOTIFICATION | 그대로 |
| `font-family` 반복 = fallback 추가 | 그대로 |
| `/bin/bash` 주입 거부, SharedGrid negative cache | 그대로 |

동작이 바뀐 항목은 없다.

## 화면 오라클 (사용자가 키 입력, 2026-11-22)

| 오라클 | 결과 |
|---|---|
| 창 리사이즈 후 숨은 탭들로 이동 | 통과. 새 크기로 그려졌고 빈 화면이나 낡은 프레임이 없었다 |
| `ls`를 친 탭에서 다른 탭에 갔다 오기 | 통과 |
| `Cmd+M` 최소화 후 복원 | 통과 |
| OSC 52 `한글abc` | 통과. 클립보드가 정확히 9바이트였다 |
| 선택 후 `Cmd+C` | 통과. `printf 한글abc` 그대로였다 |

## 아직 돌리지 않은 것

- 탭 없는 워크트리를 거쳐 돌아오기. 픽스처 프로젝트가 워크트리 하나뿐이었다.
- 시트를 띄운 상태에서 탭 전환
- WINCH 트랩, 복원 재생의 한글, kitty 바이트 오라클
- 배터리: 앞일 때와 배경일 때의 CVDisplayLink 스레드
- XCUITest (ABC 입력 소스, skip 0)
