# Intent: 쉬고 있는 에이전트를 재운다 (hibernation)

- Date: 2026-11-22
- Status: draft — 승인 대기 (rev 3, 2026-11-22: 리뷰와 실측 반영)
- Next: spec.md

## Problem
2026-11-20, 문제가 된 기계(13일 가동)에서 macOS 메모리 부족 다이얼로그가 CodeSpark를 11.19GB로 찍었다. 이 숫자는 자식 프로세스까지 합친 값이다. 앱 자체는 3.9GB이고(그래픽 3.5GB는 `2026-10-23-hidden-tab-gpu-memory`가 다룬다), 나머지 **7.35GB는 탭의 자손 프로세스**다. 대부분이 대화형 Claude Code(일부 codex)이고, 몇 시간에서 며칠씩 프롬프트에서 대기하고 있었다.

- 쉬는 claude 하나는 **footprint 약 218MB**다(RSS 564MB). 바쁜 claude에 MCP 하나를 달면 377MB(RSS 887MB)다(fable 실측, 2.1.330, spec §0). OOM 다이얼로그가 세는 것은 footprint이고 RSS는 그 약 2.6배다. rev 1에 적었던 RSS 수치(585MB, 618MB)는 그래서 2~3배 부풀려져 있었다. 7.35GB는 처음부터 footprint 합이다(`2026-10-23-hidden-tab-gpu-memory/spec.md` §1). 탭 27개 × 약 270MB와 같은 규모다. 탭 하나만 손으로 재우면 몇 퍼센트에 그친다. 그래서 **일괄 재우기**가 첫 조각에 들어간다.
- 앞선 조사의 결론: headless `claude -p`로 바꿔도 메모리는 줄지 않는다. 합의한 방향은 **쉬는 에이전트의 프로세스를 끝내고, 돌아왔을 때 같은 대화를 이어 붙이는 것**이다.

## 이미 있는 것
- 대화는 프로세스 밖에 산다. Claude Code는 대화를 `~/.claude/projects/<인코딩된 cwd>/<session-id>.jsonl`에 계속 덧붙이고, `claude --resume <session-id>`로 같은 대화를 다시 연다(`claude --help`, 2.1.330).
- 실행 중인 claude는 `~/.claude/sessions/<pid>.json`에 자기를 등록한다. 여기에 `status`(`idle`/`busy`/`shell`/`waiting`), `waitingFor`, `statusUpdatedAt`, `procStart`가 있다(실측. 문서화되지 않은 내부 파일이다). 탭의 프로세스가 쉬고 있는지를 claude 자신에게 묻는 길이 이것이다.
- **claude는 종료하면서 깨우는 줄을 스스로 찍는다**: `Resume this session with: claude --model haiku --resume <id>`. 원래 플래그를 보존하고 `--continue`는 id로 바꾼다(실측).
- 앱은 이미 **재시작할 때마다 모든 에이전트를 "재운다"**. 복원은 로컬 탭을 셸로만 다시 열고 마지막 화면을 재생한다(CLAUDE.md "Session Restore"). 사용자는 지금도 재시작 뒤에 `claude --resume`을 직접 친다. 이 기능은 그 일을 재시작 없이, 쉬고 있는 탭만 골라서 하는 것이다.

## Proposed outcome
1. 탭 우클릭 → **Hibernate Claude**, 그리고 메뉴 → **Hibernate Idle Agents…**(확인 창에 대상 탭과 유휴 시간이 보인다). 탭의 셸 아래에서 쉬고 있는 claude를 끝낸다. 셸은 살아 있고, 화면에는 claude가 찍은 깨우는 줄이 남는다. 입력줄에는 아무것도 넣지 않는다.
2. 사용자가 돌아와 그 줄을 실행하면 같은 대화가 원래 플래그 그대로 이어진다.
- 성공 기준:
  - (a) 재운 claude 트리의 **footprint**가 실측으로 사라진다(앱 자손 footprint 합계를 전후로 비교).
  - (b) 깨운 대화가 재우기 전 맥락을 기억한다.
  - (c) 일하는 중이거나 답을 기다리는 에이전트는 메뉴가 꺼져 있어 재울 수 없다.

## Affected users and systems
- 에이전트 탭을 여러 개 오래 열어 두는 사용자.
- `TerminalStateDetector`(Level 1 자식 PID), `GhosttyTerminalHost`(셸 PID, `runsCommand`), 앱 메뉴, `SessionTabBarView`의 컨텍스트 메뉴, `AgentSessionDiscovery`.

## Constraints
- **절대 일하는 중인 에이전트를 죽이지 않는다.** 도구를 실행 중이거나 권한·질문에 대한 답을 기다리는 에이전트는 재우지 않는다. 판정은 claude 자신의 `status`로 한다. `idle`만 허용하고, 모르는 값은 거절한다. `sessionsAwaitingAnswer`는 판정에 쓰지 않는다. OSC 777이 "1분 동안 쉬었다"에서도 울려서 쉬는 탭과 묻는 탭이 섞여 있다.
- 모르면 하지 않는다(fail closed). 등록 파일이 없거나, 형식이 다르거나, `procStart`가 그 pid의 실제 시작 시각과 다르면 메뉴를 끈다. 내부 파일에 기대는 대가다.
- 사용자 손 밖에서 아무것도 다시 띄우지 않는다. 깨우기는 사용자가 안내 줄을 실행하는 것이다. 탭을 보기만 해도(`Cmd` 숫자, `Cmd+[/]` 순환) 다시 뜬다면 토큰과 MCP 기동을 몰래 쓰는 셈이다.

## Out of scope (첫 조각)
- 자동 hibernation(설정, 유휴 임계값). 서브에이전트, 루프, 팀 피어 세션이 `idle`로 읽히는지 아직 모른다(spec §6).
- Resume 메뉴(안내 줄을 앱이 대신 실행).
- 명령 탭: New Agent Session과 New Worktree가 `config.command`로 claude를 띄운 탭이다. claude가 표면의 프로세스 자체라서 끝내면 "Press any key"가 뜨고, 그 키가 탭을 닫는다.
- codex(pid에서 세션으로 가는 등록 파일을 찾지 못했다), ssh 탭, 재시작 뒤에도 재운 상태를 기억하는 것(안내 줄은 보통 화면 재생으로 남지만, 출력이 많이 쌓이면 잘리고 cwd가 바뀌었을 수 있다. spec §4).

## Open questions
- spec의 "사용자 결정 필요" 절 참고.
