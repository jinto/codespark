# Spec: 쉬고 있는 에이전트를 재운다 (hibernation)

- Intent: intent.md (draft)
- Status: 만들지 않음 (2026-11-22 사용자 결정) — 조사 기록으로 남긴다

## 0. 실측으로 이미 정해진 것 (fable, Claude Code 2.1.330)
tmux 안에서 버리는 haiku 세션으로 쟀다. 기록은 `docs/2026-11-22-agent-hibernation.md`에 옮긴다(plan 0단계).

| 질문 | 결과 |
|---|---|
| pid에 SIGTERM | 3초 안에 종료, 코드 143. 등록 파일이 지워지고, 고아 프로세스는 0개. 돌던 `run_in_background` sleep도 거둬졌다 |
| 메모리 | 쉬는 claude: RSS 564MB / **footprint 218MB**. 바쁜 claude + MCP 1개: RSS 887MB / footprint 377MB. RSS가 footprint의 약 2.6배다. OOM 다이얼로그가 보는 것은 footprint다 |
| `/clear` | 등록 파일의 `sessionId`가 새 id로 따라 바뀐다 |
| `status` 값 | `idle`, `busy`, `shell`(백그라운드 셸이 도는 중), `waiting`(`waitingFor: "permission prompt"`) |
| 입력창에 쓰다 만 글 | `status`는 `idle`로 남는다. 재우면 그 글은 사라진다 |
| 종료 시 안내 | claude가 스스로 `Resume this session with: claude --model haiku --resume <id>`를 찍는다. **원래 플래그를 보존하고, `--continue`는 id로 바꿔서** 찍는다(바이너리 문자열 `Resume this session with:`도 확인) |
| `--resume` | 다른 cwd에서 `claude --resume <id> -p`가 동작했고, 맥락이 복원됐으며, resume 뒤에도 `sessionId`가 같았다. 대화형 모드에서는 아직 확인하지 않았다 |

남은 것은 plan 0단계에 있다. 무엇보다 **진짜 Ghostty 탭에서의 터미널 모드 복구**가 남았다. tmux는 kitty keyboard 플래그를 대신 받으므로 이 질문에 답하지 못한다.

## 1. 범위: 셸 탭 안의 로컬 claude, 손으로, 하나 또는 전부

탭이 claude를 품는 모양은 두 가지다.

| 모양 | 어떻게 생기나 | claude를 끝내면 |
|---|---|---|
| **셸 탭** | 사용자가 셸에 `claude`를 친다. 복원된 탭은 전부 이 모양이다 | 셸이 프롬프트로 돌아온다. 탭은 남는다 |
| 명령 탭 | `newAgentSession`, New Worktree가 `config.command`로 띄운다 | `wait-after-command`가 "Press any key"를 띄우고, 그 키가 탭을 닫는다(CLAUDE.md) |

첫 조각은 셸 탭만 다룬다.
- dev 스토어의 세션 1,577개 가운데 `target_label = 'claude'`인 행은 0개다(읽기 전용 실측). 명령 탭은 한 번도 만들어진 적이 없다는 뜻이다.
- 명령 탭까지 넓히려면 호스트 없는 탭이 필요하다(§7).

동작은 두 개다. 둘 다 같은 판정(§3)과 같은 흐름(§4)을 쓴다.
- 탭 우클릭 → **Hibernate Claude**
- 메뉴 → **Hibernate Idle Agents…**: 모든 프로젝트의 로컬 탭 중 판정을 통과한 것 전부. 확인 창에 대상 탭과 각자의 유휴 시간을 보여 준다.
- 왜 일괄을 첫 조각에 넣나: 탭 하나를 손으로 재우면 쉬는 claude 하나, 약 218MB(footprint)가 풀린다. 7.35GB(footprint 합) 가운데 3~5%에 그친다. 효과는 일괄에서 나온다. 반복문 하나라 추가 비용도 작다. 자동은 여전히 미룬다(§9).

## 2. 대상 프로세스: `~/.claude/sessions/<pid>.json`

탭 셸의 직계 자식(`TerminalStateDetector.childPIDs(of: host.shellPID)`) 가운데 등록 파일이 있는 것이 대상이다. 이름 비교는 하지 않는다.

읽는 필드(형식은 실측, 문서화되지 않은 내부 파일): `pid`, `procStart`, `kind`, `status`, `waitingFor`, `statusUpdatedAt`.
- **`sessionId`는 읽지 않는다.** 깨우는 줄은 claude가 스스로 찍는다(§5). 앱이 id를 알 필요가 없으므로 id가 낡을 걱정도, 대화 파일을 찾을 일도 없다. rev 1의 "대화 파일을 id로 찾기"와 그 경로 인코딩 문제는 사라졌다.
- **프로세스와 묶는다**:
  - `record.pid == pid`
  - `procStart`가 그 pid의 실제 시작 시각과 같아야 한다.
    - **`procStart`는 문자열이다**: `"Sat Nov 21 16:25:03 2026"`. claude가 `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`를 trim해서 만든다(바이너리 문자열). 일이 한 자리면 공백으로 채운다(`Tue Nov  3 04:41:04 2026`, pid 1로 실측).
    - **변환은 우리 쪽에서 문자열 → 초로 한다.** `DateFormatter`를 `en_US_POSIX` locale, UTC, 형식 `"EEE MMM d HH:mm:ss yyyy"`로 둔다. 공백 하나든 둘이든 받는다. 이걸 `kp_proc.p_starttime.tv_sec`와 비교한다. sysctl은 `GhosttyTerminalHost.swift:26`의 `KERN_PROC_PID` 호출을 같이 쓴다. fable이 pid 39980과 pid 1(두 칸 공백)에서 두 값이 일치함을 확인했다.
    - 파싱에 실패하면 nil, 즉 거절이다. 형식이 바뀐 새 버전에서 fail closed한다.
  - `kind == "interactive"`
  - 하나라도 어긋나면 대상이 아니다. 재활용된 pid나 남은 파일을 거른다.
- 실행 파일 이름은 보지 않는다. 등록 파일과 시작 시각, 그리고 탭 셸의 직계 자식이라는 사실로 충분하다.
- 보이지 않는 경우: `npx claude` 같은 래퍼나 탭 안의 tmux 아래에서 돈 claude는 셸의 직계 자식이 아니라서 메뉴가 뜨지 않는다. 받아들인다.

## 3. 판정: 순수 함수 하나

`AgentHibernation.verdict(record:, isLocal:, hostRunsCommand:, now:) -> Verdict`
- `.allowed(idleFor:)`: `isLocal`이고, `!hostRunsCommand`이며, `status == "idle"`이고 `waitingFor == nil`일 때.
- 그 밖에는 이유를 단 `.refused`. 메뉴에서는 이유를 보이며 꺼진다.
  - `busy` → "Claude is working"
  - `shell` → "A background shell is running"
  - `waiting` → "Claude is waiting for an answer"
  - 모르는 값 → "Unknown state". 새 버전이 상태를 추가하면 여기서 fail closed한다.
  - 원격 탭, 명령 탭

  일괄 동작의 확인 창은 refused 탭을 이유와 함께 "건너뜀"으로 보여 준다.
- `isLocal`은 탭이 속한 프로젝트의 transport에서 명시적으로 받는다. `SessionViewData`에 transport가 없으므로 `projects`의 `liveSessionDetails`로 찾는다. `sendStateNotification`이 이미 이렇게 찾는다. "명령으로 붙었으니 원격도 걸러진다"는 우연에 기대지 않는다(codex).
- `hostRunsCommand`는 `TerminalHostProtocol.runsCommand`(attach에 `command != nil`이었는지)다. `targetLabel`은 쓰지 않는다. 복원된 에이전트 탭은 셸이면서도 `claude`라고 적혀 있기 때문이다.
- `idleFor = now - statusUpdatedAt`. 메뉴 라벨에 쓴다("Hibernate Claude — idle 3h").
- `sessionsAwaitingAnswer`는 판정에 쓰지 않는다. 1분 유휴 OSC 777 때문에 쉬는 탭이 거의 다 들어 있다. 답을 기다리는 탭은 `status == "waiting"`이 말해 준다.

## 4. 재우기

`AppModel.hibernateAgent(sessionID:)`. 일괄은 같은 함수를 `withTaskGroup`으로 **동시에** 부른다. 차례로 부르면 탭 27개 × 최대 3~5초로 1~2분이 걸린다. 탭마다 하는 재확인이 그 사이의 변화를 걸러 주므로 병렬이어도 안전하다. 확인 창에서는 끝날 때까지 진행 상황(n/N)을 보여 준다.
1. 등록 파일을 **다시 읽어** §2의 묶기와 §3의 판정을 한 번 더 한다. 메뉴를 연 뒤에 사용자가 입력했을 수 있다. `.refused`면 아무것도 하지 않는다.
2. 종료 감시(`DispatchSource.makeProcessSource(.exit)`)를 먼저 등록하고, 그 pid **하나**에 `SIGTERM`을 보낸다.
   - 프로세스 그룹에는 보내지 않는다. fable 실측에서 pid 하나로 고아가 없었다.
   - MCP 서버를 단 세션에서 고아가 생기면(0단계) 그때 다시 본다.
3. 최대 5초 기다린다. 안 끝나면 SIGKILL하지 않고 알린다(단일: `loadErrorMessage`, 일괄: 결과 요약). 강제 종료는 터미널 모드를 되돌리지 않은 채 셸에 넘길 수 있다.
4. 끝나면 `sessionStates[id] = .idle`을 미리 넣는다. 값싼 보험일 뿐이고, 알림 폭주를 막는 장치는 아니다. 1분 넘게 쉰 claude는 OSC 777 때문에 이미 `.needsInput`이고, `detectState`는 `oldState`가 `.running`이나 nil일 때만 알린다(`AppModel+Monitor.swift:73`). 그래서 needsInput→idle은 원래 알림을 띄우지 않는다. 미리 넣는 것은 1분이 안 된 idle 탭(아직 `.running`)의 경우만 막는다.
   - 셸이 프롬프트로 돌아오면 Level 2가 `.idle`을 읽고, 그때 `sessionsAwaitingAnswer`에서도 빠진다(`AppModel+Monitor.swift:65`, 기존 동작).
   - 감지 코드는 고치지 않는다.

**입력줄에는 아무것도 넣지 않는다.** rev 1의 `claude --resume <id>` 채우기는 뺐다.
- claude가 종료하면서 깨우는 줄을 스스로 찍는다. 그 줄은 **원래 플래그를 보존한다**. 우리가 조립하는 줄은 `--model`, 권한 모드, `--add-dir`을 잃는다(rev 1 §9-2가 저절로 풀린다).
- `ghostty_surface_text`는 붙여넣기라서 셸 입력줄에 **이어 붙는다**(`git sta` → `git staclaude --resume …`). 종료와 붙여넣기 사이에 사용자가 친 글이 있으면 깨진다(codex).
- 채운 줄은 마지막 줄을 uuid로 끝나게 만들어 감지를 `.running`/`.needsInput`으로 바꾼다. 그래서 감지 고침 ①②가 필요했는데, 둘 다 필요 없어진다. codex는 ②("자식 없는 셸 = idle")가 빌트인, 함수, 치다 만 입력을 오판한다고 지적했다.
- 안내 줄은 화면에 있으므로 **보통은** 재시작 뒤에도 화면 재생으로 돌아온다(fable 확인: SIGTERM을 받은 claude가 안내를 찍었다. `extractRestoreSnapshot`은 `unwrap=true`로 rows×11줄을 담으므로 소프트 랩된 안내도 한 줄로 남는다. 재생에는 상한이 없다). 입력줄에 넣은 줄은 재시작하면 사라졌다. 한계도 있다.
  - 재운 뒤 약 10화면 넘게 출력이 쌓이면 안내 줄이 잘려 나간다.
  - 흐린 텍스트로만 돌아온다.
  - 복원된 셸은 `last_cwd`에서 열린다. 재운 뒤 `cd`했다면 안내 줄을 다른 디렉터리에서 실행하게 된다. 그래서 0단계 (f)는 재시작 이야기의 전제다.

그 결과 `TerminalHostProtocol`에는 `runsCommand` 하나만 더한다. 새 모델 상태도 없다. 재운 탭은 claude의 안내 줄 아래에 프롬프트가 있는 셸 탭이다.

## 5. 깨우기
사용자가 화면의 안내 줄을 실행한다(복사해서 붙여넣기, 또는 직접 입력).
- 탭을 보기만 해서는 깨지 않는다. `Cmd+[/]` 순환이 지나가는 탭을 전부 깨우면 MCP 기동과 토큰을 모르게 쓴다.
- 마찰이 있다는 것은 안다. "Resume" 메뉴(화면의 안내 줄을 읽어 실행)는 다음 조각 후보로 둔다. 입력줄이 비었는지 확실히 알 수 있어야 해서 이번에는 하지 않는다(§9-1).

## 6. 0단계에 남은 실측 (버리는 세션으로만)
이 기계에서 사용자가 돌리는 claude/codex에는 신호를 보내지 않는다.
- (a) **진짜 Ghostty 탭(또는 CodeSpark 탭)에서 SIGTERM 뒤의 터미널 모드**:
  - kitty 플래그 조회(`printf '\e[?u'`)가 0인가
  - Shift 바이트 오라클(CLAUDE.md "모디파이어 키")이 통과하는가
  - bracketed paste가 꺼져 있는가(붙여넣기가 `^[[200~` 없이 들어오는가)
  - 백스페이스가 정상인가

  **이게 실패하면 멈춘다.** 셸에 깨진 키보드를 넘기는 기능은 내보낼 수 없다.
- (b) MCP 서버 1개 이상을 단 세션에 SIGTERM을 보낸 뒤의 고아 수. 재우기 전에 자손 전체를 기록하고, 후에 하나씩 종료됨 / 재부모됨 / 실행 중으로 분류한다(codex). codex broker 트리(107MB)가 주인 claude가 죽은 뒤에도 살아남은 원인은 여기서 같이 본다.
- (c) 서브에이전트(Task)가 도는 중의 `status`. fable의 표본은 결론이 나지 않았다.
- (d) `/loop`나 예약된 깨우기가 걸린 세션의 `status`
- (e) 팀 피어나 팀원으로 동작하는 세션의 `status`(`messagingSocketPath`, `notify_idle`). **실제 질문이다**: fable이 하단에 "← 2 agents"가 뜬 세션이 `status: idle`인 것을 봤다. 피어가 연결된 세션도 idle로 읽힐 수 있다.

  (c)~(e)가 `idle`로 읽히더라도 손으로 하는 동작에서는 받아들이고 확인 창에 의존한다. 대신 **자동 hibernation은 이것들을 구분하기 전에는 하지 않는다**.
- (f) 대화형 `claude --resume <id>`를 다른 cwd에서 했을 때(안내 줄을 다른 디렉터리에서 실행하는 경우). 재시작 뒤 `last_cwd`가 달라진 경우가 바로 이것이다(§4).

## 7. 명령 탭으로 넓힐 때 (이번 범위 밖, 기록)
표면을 내리고 탭만 남긴 뒤, 깨울 때 `command:`로 새 호스트를 붙인다. `hosts[id] == nil`인 탭을 가정하는 곳이 모두 걸린다.
- `attachLiveSessions`(맨 셸을 붙인다)
- `closeSession`(일찍 반환하므로 닫을 수 없는 탭이 된다)
- ssh `filter { hosts[$0.id] != nil }`
- `detectState`, `captureCheckpoints`, `saveAllSessionsForRestore`
- `MainContentView.swift:173`과 `mainAreaContent`의 새 케이스
- `hosts`가 `@Published`가 아니라는 점

## 8. 검증
- **유닛**:
  - 등록 파일 파서(임시 디렉터리: idle / busy / shell / waiting / 모르는 status / 깨진 JSON / kind 다름 / pid 불일치)
  - `procStart` 대조(시작 시각을 주입한다. 두 자리 일과 한 자리 일(두 칸 공백) 픽스처, 파싱 실패 → nil)
  - `verdict` 표
  - `hibernateAgent` 정책(신호와 대기를 주입):
    - 재확인에서 busy가 되면 신호 0회
    - 신호는 대상 pid 하나에 정확히 1회
    - 타임아웃이면 에러가 나고 SIGKILL은 없다
    - 성공 후 `sessionStates == .idle`이고 알림은 0개
    - 일괄은 refused 탭을 건너뛰고 결과를 요약한다
- **소스 게이트**(보조): 앱 소스에서 `kill(`/`killpg(`/`SIGTERM`/`SIGKILL`/`SIGINT`/`SIGHUP`이 hibernation 파일 하나에만 있는지 본다. 지금은 주석과 문자열을 포함해 0곳이라 오탐이 없다(grep). 그래도 `//` 주석 줄은 빼고 센다. 그래야 나중에 이 단어를 언급하는 주석이 게이트를 깨지 않는다. `Process.terminate()`(Subprocess, RemoteTerminfo의 데드라인)는 대상이 아니다. 주된 보증은 위의 정책 테스트다(codex).
- **수동 체크리스트(진짜 CodeSpark, 사용자 기계)**:
  - zsh와 bash 각각에서: 비밀 단어 → 재우기 → 안내 줄이 보이는가 → 그 줄을 실행 → 기억하는가
  - 재운 직후 셸 입력: 백스페이스, 화살표, kitty 바이트 오라클, 붙여넣기
  - 숨은 탭과 포커스 없는 탭에서 일괄 재우기
  - busy / shell / waiting 상태에서 메뉴가 이유와 함께 꺼지는가
  - 재운 탭을 두고 재시작 → 화면 재생에 안내 줄이 있는가
  - 메모리: 앱 자손 footprint 합계를 전후로 잰다

  GUI가 필요하므로 SSH 세션에서는 하지 않는다.

## 9. 사용자 결정 필요
1. **깨우기**: 안내 줄을 사용자가 실행(제안) vs 다음 조각에 "Resume" 메뉴 vs 탭 선택 시 자동.
2. **입력창에 쓰다 만 글**: 실측으로 status가 idle로 남으므로 판정이 막지 못한다. 확인 창(일괄)과 사용자의 선택(단일)에 맡겨도 되는지.
3. **일괄의 최소 유휴 시간**: 확인 창만으로 충분한지, 아니면 "idle 30분 이상만" 같은 문턱을 둘지(제안: 문턱 없음, 확인 창에 유휴 시간 표시).
4. **명령 탭**: 사용자 기계에서도 드문지(§7을 할 가치가 있는지).
5. **다음 조각 순서**: Resume 메뉴 / 자동 hibernation(0단계 (c)~(e) 해결이 전제) / 명령 탭 / codex.

## 리뷰에서 받지 않은 것
- codex: "claude가 아닌 자손이 있으면 거절하거나 명시적으로 확인". MCP 서버도 자손이므로 이 규칙을 따르면 거의 모든 세션이 거절된다. 대신 백그라운드 셸은 `status == "shell"`로 이미 거절되고(실측), 서브에이전트·루프·피어는 0단계 (c)~(e)로 잰다. 일괄 동작에는 확인 창이 있다. 자손 분류는 검증(0단계 (b))에서 한다.
- codex: "실행 파일과 부모 사슬 검증". 부모는 우리가 직접 고른 것이고(탭 셸의 직계 자식), `procStart` 대조가 재활용을 막는다. 실행 파일 이름은 버전 디렉터리(`versions/2.1.330`)라 비교 기준도 불안정하다.
- codex: "레코드를 다시 읽어 `sessionId`가 바뀌었으면 거절". id를 쓰지 않게 됐으므로(§4) 바뀌어도 해가 없다. 안내 줄은 claude가 그 순간의 id로 찍는다. 다시 읽기와 `procStart` 대조는 그대로 한다.
- codex: "입력줄이 비어 있지 않으면 거절" / "붙여넣기 재설계". 채우기 자체를 뺐다.
- codex: 감지 고침 ②의 회귀 테스트 4종. ②를 뺐다. 감지 코드는 건드리지 않는다.
- codex: "준비한 명령이 재시작에 살아남지 않는다". 준비한 명령이 없어졌다. 안내 줄은 화면 재생으로 살아남는다.
- fable: 프로세스 그룹 신호 분기. 실측에서 pid 하나로 충분했으므로 뺐다(MCP 실측에서 고아가 나오면 되살린다).

## Out of scope
- 자동 hibernation, Resume 메뉴, 명령 탭(§7), codex, ssh 탭.
- `AgentSessionDiscovery.discoverClaude`의 경로 인코딩 버그(`.`과 비 ASCII 문자도 `-`가 된다). 이 작업이 그 경로를 더 이상 쓰지 않으므로 따로 고친다.
