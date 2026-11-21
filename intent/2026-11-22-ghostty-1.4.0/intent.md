# Intent: Ghostty v1.4.0 + zig 0.17로 올리고, OSC 7 주입 구멍을 막는다

- Date: 2026-11-22
- Status: approved (2026-11-22)
- Next: spec.md

## Problem
우리가 고정한 Ghostty는 `b58ef1d67`(2026-10-20)이다. 정식 릴리즈 v1.4.0(`83fb9562`, 2026-10-27)의 바로 조상이고, 그 사이는 172커밋이다. 1.4.0의 큰 기능(숨은 탭 GPU 해제, 스크롤백 압축, 새 설정들)은 이미 `b58`에 있다. 빠진 것은 보안 수정 몇 개와 zig 0.17 이전이다.

1. **zsh shell integration의 클립보드 주입(GHSA-2r63-vmw6-3m3c).** OSC 7을 찍는 `_ghostty_report_pwd`가 `$PWD`를 그대로 내보낸다. 디렉터리 이름에 진짜 BEL·ESC 바이트가 있으면 OSC 7이 거기서 끝나고, 이름의 나머지가 새 시퀀스가 된다. 예를 들어 `x<BEL><ESC>]52;c;SGVsbG8=<BEL>`이라는 디렉터리에 `cd`하면 클립보드에 "Hello"가 써진다. 우리 앱은 `b58`의 integration 파일을 번들하므로 **이 구멍이 그대로 있다**. v1.4.0은 `print -r`과 `${PWD//[[:cntrl:]]}`로 막았다(`ebd44999`). 같은 커밋이 bash integration도 고쳤고, fish는 원래 경로를 percent-encode해서 안전했다.
2. **우리가 직접 만든 OSC 7 리포터도 같은 구멍이 있다.** 원격 탭(zsh·bash·fish)과 로컬 Apple `/bin/bash`용 `PROMPT_COMMAND`(`SSHConnectionInfo.swift:293, 354, 369`)가 `%`·`#`·`?`는 인코딩하지만 제어 바이트는 거르지 않는다. Ghostty가 고친 것과 같은 종류다. 원격 탭에서는 남의 서버에 있는 디렉터리 이름이 이 Mac의 클립보드에 쓰게 된다.
3. **그 밖의 수정**: tmux control mode가 크기 0이나 과대한 pane을 거부(`bf14ea1f`), `scrollClear` 뒤 커서 스타일·하이퍼링크 유효성(`1c2ea722`), Kitty placement 정리 등. 우리 앱과 맞닿는 건 터미널 코어 쪽뿐이다.
4. **고정점이 정식 릴리즈가 아니다.** 앞으로 올릴 때 기준을 릴리즈 태그로 잡는 편이 추적하기 쉽다.

## 왜 지난번엔 v1.4.0을 피했나, 이제는 왜 되나
2026-11-20 숨은 탭 작업 때 v1.4.0을 기각했다(그 spec의 후보 표). zig 0.17이 `@cImport`를 없애서 workspace-core가 빌드되지 않았고, 그 작업과 무관한 일이었기 때문이다.

이번에 실측했다(zig 0.17.1, workspace-core 사본).
- 깨지는 곳은 세 군데다. `src/store.zig`와 `tests/store_test.zig`의 `@cImport`, 그리고 `Allocator.dupeZ` 제거.
- `@cImport`는 빌드의 `addTranslateC`(`#include <sqlite3.h>` 한 줄짜리 헤더)로, `dupeZ(u8, x)`는 `dupeSentinel(u8, x, 0)`으로 옮기면 **39개 테스트가 전부 통과한다.**
- Ghostty의 임베더 C API(`include/ghostty.h`)는 `b58`과 v1.4.0 사이에 **바뀌지 않았다**. 앱의 Swift 쪽은 손댈 곳이 거의 없을 것으로 본다.

## Proposed outcome
1. `.ghostty-version`을 v1.4.0(`83fb95624b0439ee660c2679b43b38c8b63769cd`)으로 올리고, zig를 0.17로 옮긴다. workspace-core도 함께 옮긴다. Ghostty의 `requireZig`가 minor 불일치를 양방향으로 거부하므로 한 커밋이어야 한다(지난번과 같은 이유).
2. 우리 OSC 7 리포터가 경로의 제어 바이트를 지운다(bash·zsh·fish, 로컬 bash 포함). 1번과 독립이라 따로 커밋한다.
- 성공 기준:
  - 이름에 BEL·ESC가 든 디렉터리에 들어가도 클립보드가 바뀌지 않는다. 우리 리포터는 진짜 셸로 돌리는 테스트로, 번들된 zsh integration은 앱에서 수동 오라클로 확인한다.
  - workspace-core 39개, 앱 유닛 전체, Release 빌드, 릴리즈 CI가 초록이다.
  - 숨은 탭 GPU 실측이 그대로다(탭 11개 픽스처에서 IOSurface 4장).
  - CLAUDE.md의 Ghostty 실측 지식이 여전히 맞다. 줄 번호가 바뀌면 고친다.

## Affected users and systems
- 모든 사용자(보안 수정). 특히 원격 서버에서 작업하는 사용자.
- `vendor/ghostty` 고정, zig를 찾는 네 곳(pre-commit, `build-ghostty.sh`, Xcode 빌드 페이즈의 `project.yml`과 pbxproj), `release.yml`, workspace-core 빌드, `SSHConnectionInfo`의 리포터 문자열.

## Constraints
- (spec 리뷰에서 정정: `zig@0.17`은 brew `zig`의 별칭으로 **있다**. 아래 문단은 그 전의 판단이다.)
- **brew에 `zig@0.17`이 없다.** `zig` formula 자체가 0.17.1이다. 지난번에 "PATH의 zig는 brew가 올리는 대로 움직이니 버전이 박힌 keg를 먼저 본다"고 정했는데(`ReleaseWorkflowTests`가 `zig@X.Y` 경로를 요구한다), 0.17에는 그런 keg가 없다. 어떻게 찾을지 spec에서 정한다.
- 리포터 수정은 OSC 7 동작을 바꾸면 안 된다. 정상 경로(공백, `#`, `?`, `%`, 한글)는 지금과 같은 바이트가 나가야 한다. cwd 추적이 조용히 죽는 종류라(CLAUDE.md) 진짜 셸 테스트가 필요하다.
- 제어 바이트를 지운 경로는 실제 디렉터리와 다르다. 그 탭의 `last_cwd`가 틀린 경로가 되고 복원이 프로젝트 폴더로 떨어진다. 그런 이름은 드물고, 주입보다 낫다. Ghostty도 같은 선택을 했다.

## Out of scope
- 1.4.0의 새 기능을 앱에 노출하기(`copy-on-select` 값, `ghostty +ssh`, 새 키바인딩 등). 임베더인 우리는 대부분 해당이 없다.
- 탭 메모리 목록, 에이전트 hibernation(2026-11-22 만들지 않기로 함).

## Open questions
- zig 0.17을 어떻게 고정할지: brew `zig`(지금 0.17.1, 다음 minor가 나오면 움직인다), 공식 tarball을 받는 스크립트, 또는 `zig` keg 경로 + 버전 확인. spec에서 하나를 고른다.
