# Spec: Ghostty v1.4.0 + zig 0.17, OSC 7 제어 바이트 제거

- Intent: intent.md (approved 2026-11-22)
- Status: approved (2026-11-22, rev 2)

## 1. 고정점
- `.ghostty-version` = `83fb95624b0439ee660c2679b43b38c8b63769cd`(태그 v1.4.0, 전체 40자). `vendor/ghostty`를 그 커밋으로 옮긴다.
- `b58ef1d67`은 v1.4.0의 조상이다(`git merge-base --is-ancestor` 확인). 사이는 172커밋이다.
- 임베더 C API(`include/ghostty.h`)는 두 커밋 사이에 diff가 없다. 바뀐 헤더는 `include/ghostty/vt/*`(libghostty-vt)뿐이고 앱은 그걸 쓰지 않는다.
- 빌드 산출물의 배치는 그대로다(실측): `zig-out/share/ghostty/shell-integration`, `zig-out/share/terminfo/78/xterm-ghostty`. Xcode의 리소스 복사 페이즈는 손대지 않는다.

## 2. zig 0.17
- **대상 버전**: v1.4.0의 `minimum_zig_version`은 `0.17.0`이다. `requireZig`는 minor만 본다. 로컬 실측은 0.17.1로 했다.
- **찾는 순서**는 지난번 구조를 그대로 두고 버전만 바꾼다. 네 호출부(`.githooks/pre-commit`, `scripts/build-ghostty.sh`, `apps/macos/project.yml`, pbxproj)가 `/opt/homebrew/opt/zig@0.17/bin/zig`를 맨 앞에 두고, 그다음 PATH의 `zig`다.
  - **`zig@0.17`은 지금도 있다** — brew `zig` formula(0.17.1)의 별칭이다(`brew info --json=v2 zig`의 `aliases: ["zig@0.17"]`, fable 확인). 이 기계의 `opt/zig@0.15`도 같은 식의 별칭 링크다. 그래서 `brew upgrade zig` 뒤에는 keg 경로가 바로 잡힌다. intent의 "brew에 `zig@0.17`이 없다"는 틀렸고, 그 Open question은 해소됐다.
  - 못 찾았을 때의 안내: 네 곳 모두 `brew install zig@0.17`.
  - **런타임 버전 비교는 넣지 않는다**(지난번 결정 유지). 다만 안전망은 Ghostty의 `requireZig` 하나뿐이다. workspace-core의 `minimum_zig_version`은 하한일 뿐이라 0.16으로도 이식본이 빌드되고 39개가 통과한다(fable 실측). pre-commit과 Xcode 페이즈는 workspace-core만 빌드하므로, 거기서 틀린 zig가 잡혀도 조용하다. keg 우선 순서가 그걸 막는다.
- **workspace-core** `build.zig.zon`: `minimum_zig_version = "0.17.0"`.
- **release.yml**: `setup-zig` `version: 0.17.0`. 위 주석의 근거 문장도 고친다.
- **게이트는 그대로 둔다**. `ReleaseWorkflowTests.test_every_zig_consumer_agrees_with_the_pinned_ghostty`는 기준을 vendor의 `build.zig.zon`에서 읽고 keg 경로를 `zig@<major.minor>`로 만든다. 그래서 테스트 코드는 바뀌지 않고, vendor를 옮기는 순간 네 호출부와 zon·yml이 빨개진다. 이게 1단계의 빨간불이다.
- **개발 기계 준비**: `brew upgrade zig`(이 기계의 `zig`는 0.15.2다). 이건 사용자 기계의 상태를 바꾸는 일이라, 실행 전에 말한다.

## 3. workspace-core를 0.17로
실측(zig 0.17.1, 사본)에서 깨지는 곳은 세 군데였고, 아래로 고치면 39개 테스트가 통과했다. **이 이식은 0.16에서도 빌드되고 통과한다**(fable 실측). 그래서 고정점 이동과 떼어 **먼저 따로 커밋한다** — 지금 zig(0.16)로 pre-commit을 통과하고, 고정점 커밋은 zon·yml·keg 경로와 vendor만 움직인다.
- **`@cImport` 제거** → 빌드의 translate-c.
  - `src/sqlite3_c.h`: `#include <sqlite3.h>` 한 줄.
  - `build.zig`: `b.addTranslateC(.{ .root_source_file = b.path("src/sqlite3_c.h"), .target, .optimize, .link_libc = true }).createModule()`을 `sqlite3_c`라는 이름으로 `lib_module`과 `test_module`에 `addImport`한다. `linkSystemLibrary("sqlite3")`는 그대로다.
  - `src/store.zig`, `tests/store_test.zig`: `const sqlite = @import("sqlite3_c");`.
- **`Allocator.dupeZ` 제거** → `dupeSentinel(u8, x, 0)`. 호출부는 `store.zig` 3곳, `c_api.zig` 1곳, `store_test.zig` 8곳이다(합 12). 반환형(`[:0]u8`)은 같다.
- translate-c는 처음 한 번 약 20초 걸리고, 이후엔 `.zig-cache`에서 나온다. Xcode 빌드 페이즈는 매 빌드마다 돈다("Based on dependency analysis" 꺼짐). 캐시가 있으면 비용은 무시할 수준이다. 1단계에서 확인한다.

## 4. 앱
- C API가 같으므로 Swift 변경은 없을 것으로 본다. 빌드가 깨지면 그 자리에서 고치고 여기에 적는다.
- **받아들이는 업스트림 동작 변화**(리뷰가 찾았다):
  - **OSC 7이 RFC 1123에 맞지 않는 hostname을 버린다.** `stream_handler.zig`가 `std.Io.net.HostName.fromUri`로 검증하고, `InvalidHostName`·`NameTooLong`이면 로그만 남기고 `isLocal` 전에 돌아간다. zig 0.16은 `my_mac.local`·`mac-.local`·`한글.local`을 받았고 0.17.1은 셋 다 거부한다(fable, std 수준 재현). Ghostty의 zsh·bash integration은 `$HOST`를 실으므로, 그런 hostname의 Mac에서는 **로컬 탭의 cwd 추적이 조용히 죽는다**. 우리 리포터(원격, 로컬 Apple bash)는 `localhost`를 실으므로 영향이 없다. 이 기계(`m3-enuma.local`)는 괜찮다. 업스트림 동작이라 받아들이고 CLAUDE.md에 증상과 판별법(`scutil --get LocalHostName`)을 적는다.
  - **모드 2031(색상 테마) 즉시 보고 제거**(메일박스가 차면 교착하던 것). 앱은 쓰지 않는다.
  - **Kitty 그래픽 렌더 경로 재작성**(placement를 RenderState로, 애니메이션, `images_rebuilt`가 redraw 판단에 들어감). 앱에는 이미지 코드가 없다(`kitty`가 나오는 앱 파일 셋은 키보드·클립보드 프로토콜이다). 숨은 탭 수정이 기대는 `needsDisplayOnBoundsChange`(`Metal.zig:129`)와 visible 판정은 그대로다(fable 확인). 이미지 표시는 수동 스모크 하나로 본다(가능하면 `icat` 류, 없으면 생략하고 그 사실을 적는다).
- 숨은 탭 GPU 해제(`syncVisibility`, `needsDisplayOnBoundsChange`)가 기대는 렌더러 코드(`renderer/Metal.zig`의 `needsDisplayOnBoundsChange`, `generic.zig`의 `setVisible`·`drawFrameLocked`)가 v1.4.0에서도 같은지 확인한다. 실측 오라클은 같은 픽스처에서 IOSurface 4장이다.

## 5. CLAUDE.md 실측 지식 재검증
172커밋 중 `src/termio/Exec.zig`(132줄 변경), `shell_integration.zig`, `stream_handler.zig`, `Surface.zig`가 바뀌었다. 지난번(2026-11-20)과 같은 항목을 다시 본다.
- `embedded.zig`의 `wait-after-command`(`:572`), `updateSize` no-op, `.shell = cmd`
- `Surface.zig`의 `child_exited` 순서(`:1281`)
- `resourcesdir.zig`(`:64` sentinel, `:111-120`), `Exec.zig`의 TERMINFO 계산과 integration 비활성(`:791-794`)
- `shell_integration.zig`의 Apple `/bin/bash` 거부
- `stream_handler.zig`의 OSC 7 `isLocal`과 percent-decode, OSC 777 매핑
- `font-family` 반복이 fallback 추가인지
- 렌더러 `needsDisplayOnBoundsChange`(위 4)

동작이 바뀐 항목이 나오면 멈추고 보고한다. 줄 번호만 바뀌면 고친다.

## 6. OSC 7 리포터의 제어 바이트 제거
- **대상**: `SSHConnectionInfo.swift`의 세 문자열.
  - `bashPromptCommand`(`:293`): 원격 bash와 로컬 Apple `/bin/bash`가 같이 쓴다.
  - zsh 시작 파일의 `p=…`(`:354`)
  - fish `-C` 함수(`:369`)
- **규칙**: percent-encode **전에** 제어 바이트를 지운다. bash·zsh는 `${PWD//[[:cntrl:]]}`, fish는 `string replace -ra '[[:cntrl:]]' '' -- $PWD`. 그다음 기존 `%`→`%25`, `#`→`%23`, `?`→`%3F` 순서는 그대로다.
- **실측**:
  - 세 셸 모두 `a<ESC>]52;c;SGk=<BEL>b`를 `a]52;c;SGk=b`로 만든다. 남은 글자는 ESC가 없어서 시퀀스가 아니다.
  - `/tmp/한글 a#?%`는 세 셸, 두 로케일(en_US.UTF-8, C) 모두에서 그대로 남는다. Apple bash 3.2.57도 포함이다.
- **fish는 따옴표가 다르다.** fish 코드는 `-C '…'` 안에 있으므로 패턴을 홑따옴표로 쓰면 바깥 따옴표가 닫힌다. 그대로 넣으면 경로가 빈 OSC 7이 나갔다(fable 실측). `string replace -ra "[[:cntrl:]]" "" -- $PWD`로 쓴다.
- **줄바꿈도 이걸로 해결된다.** 지금 fish 코드는 `set p (string replace …)`의 명령 치환이 줄바꿈에서 쪼개져, 이름에 줄바꿈이 있으면 OSC 7이 두 번 나간다. 제어 바이트를 먼저 지우면 한 줄이 된다.
- **같은 대가**: 지운 경로는 실제 디렉터리와 다르다. 그 탭의 `last_cwd`가 틀린 경로가 된다. 대개는 존재하지 않아 로컬 탭은 복원이 프로젝트 폴더로 떨어지고, ssh 탭은 `cd … || exit`라 탭이 종료된다(고치기 전의 잘린 경로도 같았다 — 회귀가 아니다, fable 확인). 또는 `/tmp/a<LF>b` → `/tmp/ab`처럼 우연히 있는 다른 디렉터리일 수도 있다. Ghostty integration도 같은 선택을 했다.
- **보안상 `[[:cntrl:]]`로 충분하다**: v1.4.0의 `parse_table.zig`에서 OSC 문자열 상태는 0x20–0xFF를 payload로 받으므로 끊는 것은 C0뿐이다(fable 확인). CAN(0x18)·SUB(0x1A)도 C0라 같이 지워진다.
- **알려진 한계**: 원격이 Linux이고 glibc의 단일 바이트 로케일(예: ISO-8859-1)이면 `[[:cntrl:]]`가 0x80–0x9F를 제어로 볼 수 있다. 그러면 UTF-8 한글의 연속 바이트가 지워져 경로가 깨진다. UTF-8·C 로케일에서는 맞다(macOS 실측). 단일 바이트 로케일 서버는 드물어서 받아들인다.
- **테스트**: 기존 진짜 셸 테스트(`LocalCwdReporterTests`는 bash 3.2, `SSHConnectionInfoTests`는 zsh·fish) 옆에 둔다. 실제 파일시스템에 이름에 BEL·ESC·CAN·줄바꿈이 든 디렉터리를 만들고 `cd`한 뒤, 리포터가 낸 바이트를 본다.
  - **정확한 바이트로 단언한다**: 출력 = `ESC ]7;file://localhost` + (제어 바이트를 지우고 인코딩한 경로) + `BEL`, 한 번. "사이에 ESC가 없다" 같은 느슨한 단언은 쓰지 않는다.
  - 정상 경로(공백, `#?%`, 한글)는 지금과 바이트가 같아야 한다.
  - fish가 없는 기계에서는 기존 방식대로 건너뛴다. 이 기계에는 fish가 있으므로(`/opt/homebrew/bin/fish`) pre-commit에서 실제로 돈다 — skip 수를 확인한다.
- **이 수정이 약속하는 범위**: "우리 리포터는 더 이상 주입하지 않는다"까지다. **bash 프롬프트의 `\w`는 디렉터리 이름을 날것으로 찍는다**. `/bin/bash` 3.2에서 `PS1='[\w]$ '`로 같은 디렉터리에 들어가면 OSC 52가 프롬프트를 통해 그대로 나간다(fable 실측). Debian 기본 `PS1`이 `\w`를 쓴다. v1.4.0의 번들 bash integration도 제목을 `\w`로 설정한다(`bash/ghostty.bash:171`). 사용자의 프롬프트는 우리가 고칠 수 없으므로 범위 밖이고, CLAUDE.md에 적는다. zsh의 `%~`는 제어 바이트를 `^G^[`로 찍어 안전하다.

## 7. 번들 zsh·bash integration
- vendor를 v1.4.0으로 옮기면 번들되는 `shell-integration/zsh/ghostty-integration`과 `bash/ghostty.bash`가 수정본이 된다. 따로 할 일은 없다.
- **게이트**: `AppBundleMetadataTests`가 번들의 **zsh와 bash 두 파일**을 본다. 주석에도 같은 문자열이 있으므로 코드 줄을 맞춘다(zsh는 `print -rnu`가 있는 OSC 7 줄, bash는 `${PWD//[[:cntrl:]]/}`를 쓰는 줄). vendor가 옛 커밋으로 돌아가거나 복사 페이즈가 stale `zig-out`을 실으면 빨개진다. 파일 내용 grep이라 약한 게이트지만, 이 수정이 조용히 빠지는 경로는 정확히 그 둘이다.
- **수동 오라클은 먼저 옛 빌드에서 빨간불을 본다**: 같은 각본을 지금 빌드(b58)에서 돌려 클립보드가 `Hello`로 바뀌는 것을 확인한다. 안 바뀌면 각본이 아무것도 증명하지 못한다.
- **수동 오라클**(앱): 로컬 zsh 탭에서 다음을 실행한다. 클립보드가 `SENTINEL` 그대로여야 한다.
  ```
  printf SENTINEL | pbcopy
  d=$(printf 'x\a\e]52;c;SGVsbG8=\a'); mkdir "/tmp/$d"; cd "/tmp/$d"
  pbpaste
  ```
  원격 탭에서는 프롬프트가 `\w`를 찍지 않게 한 상태(`PS1='$ '`)로 같은 각본을 돈다. 그쪽은 우리 리포터가 막는다. 프롬프트가 `\w`를 쓰면 위 범위 밖 경로로 주입되므로 오라클이 성립하지 않는다.

## 8. 검증 요약
- workspace-core `zig build test` 39개(0.17)
- Release 빌드, 유닛 전체(pre-commit)
- 숨은 탭 픽스처: IOSurface 4장(`docs/2026-10-23-hidden-tab-gpu-memory.md`의 방법)
- 위 수동 오라클(로컬 zsh, 원격), 클립보드 OSC 52·Cmd+C 한글(지난번 오라클)
- **CI와 같은 zig 0.17.0으로 한 번 빌드한다.** 게이트가 `release.yml`을 `0.17.0`으로 고정하는데 로컬 실측은 전부 0.17.1이었다. 공식 0.17.0 tarball로 Ghostty xcframework와 workspace-core 테스트를 미리 돌려, 첫 실행이 태그 push가 되지 않게 한다.
- 릴리즈 CI(zig 0.17.0, 공증까지). **CI는 앱 유닛 테스트를 돌리지 않는다**(workspace-core만). 앱 유닛은 로컬 pre-commit·pre-push가 맡는다.

## Out of scope
- 1.4.0의 새 설정·키바인딩·`ghostty +ssh`를 앱에 노출하기.
- zig를 공식 tarball로 받는 스크립트. brew가 이전 minor를 `zig@X.Y`로 떼어 내는 한 필요 없다.

## 리뷰에서 받지 않은 것
- codex: "릴리즈 CI에 앱 유닛 테스트를 넣는다". 이번 범위가 아니다. 앱 유닛은 pre-commit이 매 커밋 돌리고, 성공 기준을 "로컬 pre-commit·pre-push + CI의 workspace-core·빌드·공증"으로 낮춰 적었다(§8).
- codex: "Kitty 이미지·애니메이션 스모크 테스트 필수". 앱에 이미지 코드가 없고, 숨은 탭 수정이 기대는 렌더러 판정은 그대로다(§4). 수동 스모크 하나로 낮춘다.
- fable: Linux 단일 바이트 로케일 대비로 `[[:cntrl:]]` 대신 명시적 C0 목록 쓰기. bash에서 범위식은 로케일 정렬에 따라 달라지고, 32글자를 늘어놓으면 세 셸의 문자열이 읽기 어려워진다. 드문 환경이라 한계로 적는다(§6).
