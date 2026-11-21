# Plan: Ghostty v1.4.0 + zig 0.17, OSC 7 제어 바이트 제거

- Spec: spec.md (approved 2026-11-22, rev 2)
- Status: approved (2026-11-22) · codex·fable 리뷰 반영

커밋 순서: A(workspace-core 이식, zig 0.16에서) → B(OSC 7 리포터) → C(고정점 + zig 0.17) → D(CLAUDE.md). A와 B는 지금 zig로 pre-commit을 통과한다. C가 실패하면 C만 되돌린다.

**전제**: A·B는 `/opt/homebrew/opt/zig@0.16/bin/zig`(이 기계에 있다, 2026-11-20 설치)를 pre-commit이 먼저 잡는 데 기댄다. 시작 전에 `"$(…)" version`이 0.16.0인지 확인한다.
**"유닛 전체"의 뜻**: pre-commit은 `CodeSparkUITests`와 `SSHIntegrationTests`를 건너뛴다. 이 plan에서 "유닛"은 그 둘을 뺀 집합이다. 결과를 보고할 때 그렇게 적는다.

## A. workspace-core를 translate-c로 (zig 0.16에서 커밋)
- [x] `src/sqlite3_c.h` 추가. `build.zig`에 `addTranslateC` 모듈 `sqlite3_c`를 만들어 lib·test 모듈에 import한다. `store.zig`·`store_test.zig`의 `@cImport`를 `@import("sqlite3_c")`로 바꾼다.
- [x] `dupeZ(u8, x)` → `dupeSentinel(u8, x, 0)`: `store.zig` 3곳, `c_api.zig` 1곳, `store_test.zig` 8곳(합 12, fable 정정).
  → verify: zig 0.16 `zig build test` 39개 통과. scratch의 zig 0.17.1(`scratchpad/zig17/…/zig`)로도 39개 통과. Xcode Debug 빌드가 translate-c 캐시를 쓰는지 두 번째 빌드 시간으로 확인한다. pre-commit 통과.

## B. OSC 7 리포터의 제어 바이트 제거 (TDD)
- [x] **하네스 확장**: 지금 도우미(`LocalCwdReporterTests`·`SSHConnectionInfoTests`)는 출력을 `String`으로 바꿔 OSC 7로 쪼개고 percent-decode한다. 경로는 보지만 바이트는 안 본다. `Data` 그대로 `ESC]7;file://localhost…BEL` 프레임을 세고 꺼내는 도우미를 추가하고, 셸의 `terminationStatus == 0`도 단언한다. 기존 테스트는 그대로 둔다.
- [x] **빨강**: 진짜 셸 테스트를 먼저 쓴다.
  - 각 테스트는 임시 디렉터리 안에 이름에 `BEL`, `ESC]52;c;SGk=`, `CAN`, `LF`가 든 디렉터리를 만든다(`FileManager.createDirectory`가 받는다, fable 확인).
  - **stdin으로 `cd '<dir>'`를 치는 기존 방식은 쓰지 않는다**: 대화형 bash 3.2는 파이프 stdin에도 readline을 돌려 BEL·ESC·CAN을 먹고, `LANG`이 없는 하네스 환경에선 한글도 먹는다 — `cd`가 안 일어나 리포터와 무관한 이유로 빨개진다(fable 실측). 대신:
    - **원격(zsh·fish·bash)**: 셸을 그 디렉터리에서 시작한다 — `runRemoteScript(remotePath: dir, …)`(`RemoteShell.quoted`로 홑따옴표), stdin엔 `exit`만. 그러면 stdout 전체가 프레임 하나와 정확히 같다.
    - **로컬 Apple bash**: `runAppleBash`엔 cwd 인자가 없고, `currentDirectoryURL`을 주면 bash는 `/private/var/folders/…`를, `resolvingSymlinksInPath`는 `/var/folders/…`를 말한다. 디렉터리를 환경변수(`CS_D`)로 넘기고 `cd "$CS_D"`를 친다(bash 3.2에서 확인). 보고는 두 번(홈, 대상) 나오므로 **마지막 프레임**을 단언한다.
  - 출력이 `ESC]7;file://localhost<지우고 인코딩한 경로>BEL`과 정확히 같아야 한다(원격은 한 번만). 비교는 `Data`(또는 `.utf8` 바이트)로 한다 — Swift `String ==`은 정준 동치라 한글의 NFC/NFD 차이를 숨긴다.
  - 정상 경로 케이스(공백, `#?%`, 한글)를 같은 형식으로 추가하고, 지금 코드에서 통과하는지 먼저 본다. 회귀 기준선이다.
  - 지금 코드에서 hostile 케이스가 빨간지 확인한다. fish는 줄바꿈 케이스에서 OSC 7이 두 번 나오는 것까지 본다.
- [x] **초록**: 세 문자열에서 percent-encode 전에 제어 바이트를 지운다. bash·zsh는 `${PWD//[[:cntrl:]]}`, fish는 `string replace -ra "[[:cntrl:]]" "" -- $PWD`(겹따옴표, spec §6).
  → verify: 새 테스트와 기존 리포터 테스트 전부 초록. 새 fish 케이스는 `XCTUnwrap(installedFish)`로 명시한다 — fish가 없으면 **실패**한다(기존 루프 테스트처럼 `?? []`로 조용히 빠지지 않는다). 테스트 로그에 fish 케이스가 실행된 줄이 있는지 본다. pre-commit 통과.

## C. 고정점 v1.4.0 + zig 0.17 (한 커밋)
- [x] **옛 빌드 보관**: b58 Release 산출물을 `scratchpad/baseline/CodeSpark-b58.app`에 보관했다(2026-11-22, 번들 zsh integration이 수정 전 코드임을 확인). E.1의 빨간불이 여기에 기댄다.
- [x] **개발 기계**: `brew upgrade zig` → 0.17.1. 이 기계의 `zig`는 0.15.2다. `/opt/homebrew/opt/zig@0.17`(별칭 링크)이 생기는지 확인한다. 시스템 도구를 바꾸는 일이라 실행 직전에 사용자에게 한 줄로 알린다.
- [x] **빨강(커밋하지 않는 중간 상태)**: `vendor/ghostty`를 `83fb9562…`로 옮기고 `.ghostty-version`을 갱신한다. **그 테스트 하나만** 돌려(`-only-testing:CodeSparkTests/ReleaseWorkflowTests/test_every_zig_consumer_agrees_with_the_pinned_ghostty`) 빨개지는지 본다. zon, yml, 네 keg 경로가 모두 0.16을 가리키기 때문이다. 바로 이어서 아래 편집을 마치고, pre-commit은 완성된 C 커밋에서 한 번 돈다.
- [x] **Ghostty 내부 재검증(spec §5, 멈춤 규칙)**: v1.4.0 소스에서 직접 읽는다. 대상은 `embedded.zig`(wait-after-command, `updateSize` no-op, `.shell`), `Surface.zig`(`child_exited` 순서), `resourcesdir.zig`, `Exec.zig`(TERMINFO, integration 비활성), `shell_integration.zig`(Apple bash 거부), `stream_handler.zig`(OSC 7·777), 렌더러(`Metal.zig`의 `needsDisplayOnBoundsChange`, `generic.zig`의 `setVisible`·`drawFrameLocked`)다. spec §4에 적은 세 변화 말고 동작이 바뀐 것이 나오면 **멈추고 보고한다**. 줄 번호는 D에서 고친다.
- [x] **초록**:
  - 네 호출부의 keg를 `zig@0.17`로 바꾸고, 안내를 `brew install zig@0.17`로 바꾼다. 대상은 pre-commit, `build-ghostty.sh`, `project.yml`, pbxproj다.
  - workspace-core `minimum_zig_version = "0.17.0"`.
  - `release.yml` `version: 0.17.0`과 주석.
- [x] **번들 게이트(빨강→초록)**:
  - `AppBundleMetadataTests`에 번들 zsh와 bash 검사를 추가한다. zsh는 **주석이 아닌 줄 중 `kitty-shell-cwd://`와 `${PWD//[[:cntrl:]]}`를 둘 다 담은 줄**이 있는지 본다. `print -rnu`는 b58 제목 줄에도 있어 영원히 초록이고, `${PWD//[[:cntrl:]]}`는 주석(`:245`)에도 있다(fable 확인). bash는 `${PWD//[[:cntrl:]]/}` 줄(`:201`).
  - 옛 `zig-out`에서 빨간 것을 확인한다.
  - `scripts/build-ghostty.sh`로 GhosttyKit을 다시 빌드한다(Metal Toolchain 필요, 이미 있다). 빌드한 앱에서 초록이 되는지 본다.
- [x] **두 프로젝트 파일이 같은지**: `project.yml`과 pbxproj의 workspace-core 페이즈가 같은 keg 경로를 쓰고 `ZIG_GLOBAL_CACHE_DIR`·`ZIG_LOCAL_CACHE_DIR`을 유지하는지 diff로 본다. xcodegen으로 다시 생성해도 pbxproj의 페이즈가 같은지 확인한다(생성본은 버린다). `.zig-cache`·`.zig-global-cache`가 git에 안 잡히는지 `git status`로 본다.
  → verify: Release 빌드, 유닛(pre-commit, 위 정의), workspace-core 39개(0.17.1).

## D. CLAUDE.md
- [x] 줄 번호를 고친다(fable 재확인값): `Surface.zig:1281`→`:1299`, `Exec.zig:791-794`→`:796-799`. `embedded.zig:572`, `resourcesdir.zig:64`·`:111-120`은 그대로다. 고치기 전에 각 줄을 직접 읽어 확인한다.
- [x] Build 절(`CLAUDE.md:9`)의 zig 0.16·`brew install zig@0.16` 문장을 0.17로.
- [x] Ghostty Integration 절에 추가한다.
  - **OSC 7 hostname 검증**: v1.4.0부터 RFC 1123에 맞지 않는 hostname은 버려진다. 그런 hostname의 Mac에서는 로컬 cwd 추적이 조용히 죽는다. 판별은 `scutil --get LocalHostName`. 우리 리포터는 `localhost`라 해당이 없다.
  - **OSC 7 리포터의 제어 바이트 규칙**: 지운 다음 인코딩한다. fish는 겹따옴표. 이 수정은 리포터까지만 막는다. bash 프롬프트의 `\w`와 번들 bash integration의 제목은 막지 못한다.
- [x] Release 절의 zig 문장: `zig@0.17`은 brew `zig`의 별칭이고, 다음 minor가 나오면 brew가 떼어 낸다.
  → verify: 문서 커밋. pre-commit 통과.

## E. 검증
- [x] **CI와 같은 zig로 한 번(태그 전에 필수)**: 공식 `zig-aarch64-macos-0.17.0` tarball을 scratch에 받는다. Ghostty xcframework(`-Dxcframework-target=native`)와 workspace-core 테스트를 돌린다.
- [x] **숨은 탭 실측**: 탭 11개 픽스처(`CODESPARK_STORE_PATH`)에서 `footprint`로 잰다. IOSurface 4장 근처면 통과다. SSH에서도 된다.
- [x] **수동 오라클**(화면 필요, 사용자 키 입력):
  1. **옛 빌드에서 빨간불**: 보관한 업그레이드 전 빌드(b58)를 띄우고, 로컬 zsh 탭에서 spec §7 각본을 돌린다. 클립보드가 `Hello`로 바뀌어야 각본이 유효하다.
     - 옛 빌드가 없으면 지금 Release 산출물을 C 전에 따로 보관해 둔다.
  2. **새 빌드**: 같은 각본에서 클립보드가 `SENTINEL` 그대로여야 한다. 클립보드는 SSH에서 `pbpaste`로 내가 확인한다.
  3. **원격 탭**: `PS1='$ '`로 같은 각본을 돈다(localhost ssh 프로젝트면 충분하다).
  4. **지난번 오라클**:
     - OSC 52와 Cmd+C로 한글이 정확히 복사되는지
     - 창 리사이즈와 탭 전환 화면
     - 이미지 스모크는 도구가 있으면 하고, 없으면 생략했다고 적는다.
- [x] codex·fable 구현 리뷰를 병렬로 받는다. `ponytail-review`를 돌린다. 지적을 반영한다.
- [x] docs: `docs/2026-10-23-hidden-tab-gpu-memory.md`에 v1.4.0 실측 한 줄을 남긴다. 오라클 결과도 이 plan 아래에 기록한다.

## F. 릴리즈
- [x] main push(pre-push). 버전은 사용자에게 묻는다. 태그 push 후 CI를 끝까지 본다(zig 0.17.0, 공증, DMG).

## 실행 기록 (2026-11-22)
- 커밋: A `1ff202e`, B `e467574`, C `1c5df23`, D `d84c49a`, 리뷰 반영 `8673dcc`. 모두 pre-commit(유닛, UITests·SSHIntegrationTests 제외) 통과.
- 빨간불 확인: B의 새 테스트(hostile 이름) 셸 4종 모두 빨강 → 수정 후 초록. C의 zig 게이트·번들 게이트 빨강 → 초록.
- xcodegen 2.48.0 재생성: 빌드 페이즈 스크립트가 pbxproj와 한 글자도 다르지 않다.
- zig 0.17.0(CI 버전) tarball: Ghostty xcframework 빌드 성공, workspace-core 39/39.
- 숨은 탭 픽스처(화면 잠금 해제): IOSurface 4장 64MB, phys_footprint 275MB(b58: 4장 62MB, 249MB). 잠긴 화면에서는 1장 128KB — 창 전체가 occluded라 보이는 탭도 놓는다(예상 동작).
- 클립보드 주입 오라클(로컬 zsh, `x<BEL><ESC>]52;c;SGVsbG8=<BEL>`로 cd): b58 빌드는 클립보드가 `Hello`로 바뀌었다(각본 유효). v1.4.0 빌드는 바뀌지 않았다.
- OSC 52 `한글abc`: 정확히 9바이트.
- 생략: 원격 탭 오라클(리포터는 실제 셸 테스트가 바이트 단위로 덮는다), 이미지 스모크(도구 없음).
- 리뷰: codex·fable 구현 리뷰 모두 결함 없음. fable이 189회(셸 3 × 로케일 3 × 이름 21) 돌려 누출 0. 범위 밖 기존 문제: 원격 경로에 `'`가 있고 원격 셸이 fish면 탭이 rc 127로 죽는다.
