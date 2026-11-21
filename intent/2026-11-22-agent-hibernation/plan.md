# Plan: 쉬고 있는 에이전트를 재운다 (hibernation)

- Spec: spec.md (draft, rev 2)
- Status: 만들지 않음 (2026-11-22 사용자 결정) — 조사 기록으로 남긴다

0단계 (a)가 설계를 막을 수 있다. 통과하기 전에는 코드를 쓰지 않는다.

## 0. 실측 (코드 없음, 버리는 claude로만)
fable이 이미 잰 것(spec §0): SIGTERM, 메모리, `/clear`, status 값, 쓰다 만 글, 종료 안내, `-p` resume. 이것들을 `docs/2026-11-22-agent-hibernation.md`에 옮겨 적는다.
- [ ] (a) **진짜 Ghostty/CodeSpark 탭**에서 SIGTERM 뒤의 터미널 모드를 본다. kitty 플래그 조회, Shift 바이트 오라클, bracketed paste 꺼짐, 백스페이스. zsh와 bash 둘 다 한다. GUI가 필요하므로 사용자 기계에서 한다.
- [ ] (b) MCP 서버를 단 세션: 재우기 전 자손 전체 → 재운 뒤 분류(종료됨 / 재부모됨 / 실행 중). broker 트리가 살아남는 원인도 본다.
- [ ] (c) 서브에이전트(fable 표본은 결론 없음), (d) `/loop`나 예약 깨우기, (e) 팀 피어나 팀원 세션의 `status`. (e)는 fable이 "← 2 agents" 세션에서 idle을 봤으므로 실제로 풀어야 할 질문이다.
- [ ] (f) 대화형 `claude --resume <id>`를 다른 cwd에서 실행. 재시작 뒤 `last_cwd`가 달라진 탭에서 안내 줄을 실행하는 경우다(spec §4).
  → verify: docs에 표로 남긴다.
  - (a)가 실패하면 **멈추고 보고한다**.
  - (b)에서 고아가 나오면 spec §4의 "pid 하나"를 다시 정한다.
  - (c)~(e)가 idle로 읽히면 spec §6에 따라 자동 hibernation의 전제 조건으로 기록한다(이번 조각은 그대로 진행).
  - 결과가 spec과 다르면 spec부터 고친다.

## 1. 등록 파일 읽기 (TDD)
- [ ] **빨강**: `ClaudeSessionRegistryTests`(임시 디렉터리의 `sessions/<pid>.json` 픽스처)
  - idle / busy / shell / waiting / 모르는 status → 각각 그대로 읽힌다(판정은 2단계 몫이다)
  - 깨진 JSON, `kind != "interactive"`, 파일 속 pid ≠ 파일명 pid → nil
  - `procStart`(문자열 `"Sat Nov 21 16:25:03 2026"`)가 주입한 시작 시각(초)과 같으면 record, 다르면 nil. **한 자리 일 픽스처**(`"Tue Nov  3 04:41:04 2026"`, 두 칸 공백)도 넣는다. 파싱할 수 없는 문자열이면 nil
  - 파일 없음 → nil
- [ ] **초록**: `AgentSessionDiscovery.swift`에 다음을 더한다.
  - `ClaudeSessionRecord`(Decodable. 필드는 `pid`, `procStart`, `kind`, `status`, `waitingFor`, `statusUpdatedAt`이고 `sessionId`는 읽지 않는다)
  - `static func liveClaude(pid:, claudeHome:, startTime:) -> ClaudeSessionRecord?`. `startTime` 기본값은 `kp_proc.p_starttime.tv_sec`이고 테스트가 주입한다. `GhosttyTerminalHost.swift:26`의 `KERN_PROC_PID` sysctl을 작은 함수로 꺼내 같이 쓴다. `procStart`는 `DateFormatter`(`en_US_POSIX`, UTC, `"EEE MMM d HH:mm:ss yyyy"`)로 우리 쪽에서 초로 바꾼다.
  → verify: 새 테스트 초록, 기존 `WorkspaceSelectionTests` 초록.

## 2. 판정 (TDD)
- [ ] **빨강**: `AgentHibernationTests`에 `verdict` 표를 둔다.
  - allowed: idle, 로컬, 명령 없음. `idleFor`가 `now - statusUpdatedAt`인지 본다.
  - allowed: `targetLabel == "claude"`인 셸 탭(복원된 에이전트 탭). verdict는 targetLabel을 받지 않으므로 통합 테스트에서 확인한다.
  - refused와 고정된 이유 문자열: busy, shell, waiting, 모르는 status, `isLocal == false`, `hostRunsCommand == true`, idle인데 `waitingFor`가 있음.
- [ ] **초록**: `Services/AgentHibernation.swift`의 `enum AgentHibernation { static func verdict(...) }`. `sessionsAwaitingAnswer`는 인자로 받지 않는다.
  → verify: 표 전부 초록.

## 3. 재우기 흐름 (TDD)
- [ ] `TerminalHostProtocol`에 `runsCommand: Bool`을 더한다. `GhosttyTerminalHost`는 attach의 `command != nil`을 기억하고, `NoOpTerminalHost`는 false다. `MockTerminalHost`는 attach에서 기억하고, `shellPID`를 주입할 수 있게 한다.
- [ ] **빨강**: `AppModelTests`. 주입점은 `claudeLookup: (pid_t) -> ClaudeSessionRecord?`, `childPIDs: (pid_t) -> [pid_t]`, `processSignaller: (pid_t) async -> Bool`(신호 + 최대 5초, 끝났으면 true)이다.
  - idle → 재확인 → 신호가 그 pid에 정확히 1회 → 성공 → `sessionStates[id] == .idle`
  - 재확인에서 busy → 신호 0회
  - 타임아웃 → `loadErrorMessage` 설정. 신호 함수는 한 번만 불렸다(재시도·SIGKILL 없음)
  - 성공 후 `sessionStates[id] == .idle`(선기록, 보험이다. 알림은 원래 needsInput→idle에서 안 뜬다. spec §4)
  - 원격 프로젝트의 탭 → 신호 0회(`isLocal`이 프로젝트에서 온다)
  - 일괄: 탭 3개(allowed / busy / 원격) → 신호 1회, 요약에 건너뛴 2개와 이유
  - 일괄은 병렬이다: allowed 탭 2개에 각각 지연 스텁을 걸면, 두 신호가 서로를 기다리지 않고 나간다(`withTaskGroup`)
  - 지연 스텁은 `Task.detached`로 만든다(CLAUDE.md "스텁 지연은 취소를 견뎌야 한다")
- [ ] **초록**: `AppModel.hibernateAgent(sessionID:)`, `hibernateIdleAgents()`, `hibernationVerdict(sessionID:)`(메뉴용). 진짜 `processSignaller`는 `DispatchSource.makeProcessSource(.exit)`를 먼저 등록한 뒤 `kill(pid, SIGTERM)`을 보내고 continuation으로 기다린다.
- [ ] **소스 게이트**(보조): `test_only_hibernation_signals_a_process`. 패턴은 `kill(`, `killpg(`, `SIGTERM`, `SIGKILL`, `SIGINT`, `SIGHUP`이고, 허용하는 곳은 hibernation 파일 하나다. 지금 걸리는 곳은 0곳이다. `Process.terminate()`는 패턴에 걸리지 않는다.
  → verify: 유닛 전체 초록. 재확인 줄을 지우면 busy 테스트가 빨개진다. 게이트는 `//` 주석 줄을 빼고 센다(지금 오탐 0).

## 4. 메뉴
- [ ] `SessionTabBarView`에 `hibernation: (SessionViewData) -> AgentHibernation.Verdict?`(nil = claude 없음, 항목 숨김)와 `onHibernate`를 더한다. 메뉴가 열릴 때 묻는다(`moveTargets`와 같다). 라벨에 유휴 시간을 넣고, refused면 이유를 보이며 disabled로 둔다.
- [ ] 앱 메뉴에 **Hibernate Idle Agents…**를 둔다. 확인 창에 대상 탭(프로젝트·탭 이름·유휴 시간)과 건너뛸 탭(이유)을 보여 주고, 도는 동안 진행 상황(n/N), 끝나면 요약을 보인다. 단축키는 없으므로 `AppShortcut`도 없다. `test_declared_commands_are_wired_to_menu_items`는 선언된 단축키만 보므로 영향이 없다.
  → verify: 빌드, 유닛 전체. UI는 5단계에서 손으로 확인한다. 돌고 있는 claude라는 재료가 필요해 XCUITest로 묶지 않는다.

## 5. 실측 검증 (사용자 기계, 수동)
- [ ] spec §8의 수동 체크리스트 전부. zsh와 bash, 숨은 탭과 포커스 없는 탭, 세 가지 refused 상태, 재시작 후 안내 줄, 재운 직후 키보드 오라클.
- [ ] 메모리: 쉬는 claude N개를 일괄로 재우기 전후에 앱 자손 **footprint** 합계를 잰다. RSS도 함께 적되 기준은 footprint다.
  → verify: docs에 결과를 남긴다.

## 6. 리뷰와 마무리
- [ ] 구현 리뷰를 codex와 fable에게 병렬로 받고 반영한다. `ponytail-review`를 돌린다.
- [ ] CLAUDE.md에 절을 하나 더한다.
  - 대상의 출처(`~/.claude/sessions/<pid>.json` + `procStart`, 내부 파일이라 fail closed)
  - status 4종과 모르는 값의 처리
  - `sessionsAwaitingAnswer`를 쓰지 않는 이유
  - 입력줄을 채우지 않는 이유(붙여넣기가 이어 붙는다, 플래그 보존, 감지)
  - SIGKILL이 없는 이유
  - 알림이 몰리지 않는 진짜 이유(needsInput→idle은 알리지 않는다)
  - `procStart`의 형식과 비교 방법
  - 오라클

## 커밋 단위
0(docs) → 1+2(순수) → 3(흐름 + 게이트) → 4(메뉴) → 5·6(docs, CLAUDE.md). 각 커밋은 pre-commit 훅을 통과해야 한다.

## 미룬 것
- Resume 메뉴(화면의 안내 줄을 읽어 실행. 입력줄이 비었는지 판정이 전제다).
- 자동 hibernation(설정 기본 off, `statusUpdatedAt` 기준 유휴 N시간, 보이지 않는 탭만. 0단계 (c)~(e)를 구분하는 것이 전제다).
- 명령 탭(spec §7), codex(pid에서 세션으로 가는 등록 파일이 없다. `codex resume <id>`는 있다), ssh.
- `discoverClaude`의 경로 인코딩 버그.

## 리뷰에서 받지 않은 것
spec의 같은 절을 본다. plan에만 해당하는 것:
- codex: "Ghostty 통합 테스트". 유닛 환경은 표면을 만들 수 없다(`2026-10-23` plan과 같은 한계). 입력줄을 채우지 않게 되면서 `ghostty_surface_text`가 이 기능에서 빠졌으므로, 남은 실제 위험(터미널 모드)은 0단계 (a)와 5단계의 수동 체크리스트가 맡는다.
