# Intent: 어느 탭이 메모리를 먹는지 보이게 한다

- Date: 2026-11-22
- Status: draft — 승인 대기 (rev 2: codex·fable 리뷰 반영)
- Next: spec.md

## Problem
2026-11-20, 13일 가동한 사용자 기계에 macOS 메모리 부족 다이얼로그가 떴고 CodeSpark가 11.19GB로 찍혔다. 앱 자체 footprint는 3.9GB였고(대부분 숨은 탭 GPU, v1.6.0에서 해결 — `intent/2026-10-23-hidden-tab-gpu-memory`), 나머지 7.35GB는 자손 프로세스였다. 5일째 돌던 잊힌 `node test.mjs` 하나가 2GB, 나머지는 탭 27개에 흩어진 claude·codex 에이전트였다(fable 리뷰의 추정은 각 수백 MB. 탭별 실측 기록은 없다).

macOS는 이 전부를 CodeSpark 몫으로 센다. Activity Monitor에서도 프로세스 이름(node, claude)만 보이고 **어느 탭의 것인지는 안 보인다**. 사용자는 범인을 못 찾고, 앱을 통째로 재시작하는 게 유일한 처방이 된다.

## Proposed outcome
**탭을 메모리 순으로 늘어놓은 목록 하나.** 한 행이 한 탭이다: 그 탭 프로세스들의 footprint 합, 가장 큰 프로세스의 이름, 프로젝트/워크트리/탭 제목. 행을 누르면 그 탭으로 간다. 맨 위에는 탭 전체 합계.
- 목록이어야 하는 이유: 범인은 대개 지금 안 보는 프로젝트에 있고, 접힌 그룹·shelf(실행마다 닫힌 채 시작한다)·접힌 워크트리 안에 있을 수도 있다. 사이드바 행에 숫자를 다는 방식은 그 행이 그려질 때만 보인다. 그리고 7.35GB의 대부분이 기준치(예: 1GB)에 못 미치는 에이전트들이라면, 기준치 배지는 문제의 일부만 보여 준다.
- 성공 기준: 사용자 기계의 상황(다른 프로젝트 탭의 잊힌 2GB node)에서 목록을 열면 그 탭이 맨 위에 `node`라는 이름과 함께 있고, 누르면 그 탭에 선다.
- 숫자는 "그 탭 프로세스들의 footprint 합"이다. 각 프로세스의 값은 `footprint -p <pid>`와 같지만(fable 확인), 합이 Activity Monitor나 다이얼로그 숫자와 같다고는 약속하지 않는다.

## Affected users and systems
- 에이전트·dev 서버를 여러 탭에 오래 띄워 두는 사용자.
- `TerminalStateDetector`(프로세스 헬퍼), Ghostty C API(`ghostty_surface_tty_name`), 메뉴 명령, 새 시트 하나.

## Constraints
- **고아 문제가 이 기능의 크기를 정한다.** macOS는 responsible process로 묶는다. 고아는 생각보다 흔하다. 에이전트의 Bash 도구 셸에는 제어 터미널이 없다(`/bin/zsh ppid=claude tty=??`). 거기서 띄운 백그라운드 작업(`&`, `nohup`, dev 서버)은 도구 호출이 돌아오는 순간 launchd로 입양된다. 에이전트가 살아 있어도 그렇다(실측: `(sleep 41 &)` → 곧바로 `ppid=1 tty=??`). 이 프로세스들은 여전히 CodeSpark 몫이지만 어느 탭의 tty에도, 어느 탭의 자손에도 없다. 잊힌 `node test.mjs`가 바로 그것일 공산이 크다. 공개 API로는 responsible pid를 못 읽는다. 그래서 **코드보다 먼저 사용자 기계에서 고아를 들여다본다**(plan 0단계). 가장 큰 범인들이 고아라면 "탭 밖" 행이 이 기능의 본체가 되고, 이 문서를 고쳐 다시 승인받는다.
- root 소유 프로세스는 못 잰다(`proc_pid_rusage` → EPERM, 실측). 탭의 `login(1)`이 그렇고 `sudo` 아래 자식도 그렇다.
- ssh 탭의 원격 프로세스는 이 Mac의 메모리를 쓰지 않는다. 목록에는 로컬 ssh 클라이언트 몇 MB로 나온다 — 거짓이 아니다.
- 배경 배터리를 쓰지 않는다. 목록을 열 때만 잰다.

## Out of scope
- 프로세스를 죽이는 버튼. 탭을 닫는다고 메모리가 풀린다고도 약속하지 않는다 — 백그라운드·`nohup` 작업은 SIGHUP을 견딘다.
- 상시 표시(사이드바·탭바 배지), 폴링, 알림, 기준치.
- 앱 자체 footprint와 앱 전체 합계. Activity Monitor가 준다.
- 원격 메모리, CPU, 그래프.

## Open questions
- 고아 행: 0단계 결과(가장 큰 범인들이 고아인가)를 보고 정한다. 넣는다면 비공개 SPI(`responsibility_get_pid_responsible_for_pid`)가 필요하다. 넣지 않으면 시트가 "탭에서 떨어져 나간 프로세스는 보이지 않는다"고 말해야 한다. 안 그러면 합계가 조용히 적게 말한다.
- 목록을 여는 곳: 메뉴 항목(제안) vs 툴바 버튼. 메모리 부족 다이얼로그를 본 사용자가 찾아올 자리여야 한다.
- 무거운 탭(예: 1GB 이상)에 탭바 알약도 달 것인가. 제안: 안 한다 — 폴링과 상시 상태가 따라온다.
