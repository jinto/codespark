# Plan: 어느 탭이 메모리를 먹는지 보이게 한다

- Spec: spec.md (draft — 승인 대기)
- Status: 만들지 않음 (2026-11-22 사용자 결정) — 조사 기록으로 남긴다

0단계는 코드보다 먼저다. 그 결과가 이 기능의 모양을 바꿀 수 있다.

## 0. 사용자 기계 실측 — 게이트 (코드 없음)
문제가 된 기계에서, 앱이 오래 떠 있는 상태로 읽기 전용 프로브를 돌린다(fable의 `p.c`와 같은 것: `proc_pid_rusage` + `responsibility_get_pid_responsible_for_pid` + `proc_listpids(PROC_TTY_ONLY)`. 앱에는 SPI를 넣지 않는다. 프로브에서만 쓴다).
- [ ] **고아 상위 N**: responsible pid가 CodeSpark이고 ppid가 1인 프로세스를 footprint 순으로 상위 10개(pid, 이름, 명령행, 가동 시간, footprint). 같은 순서로 탭 tty 집합 + 자손 쪽 상위 10개.
- [ ] **비용 상한**: 기계 전체 걷기 시간(spec §3, 50ms 기준).
  → verify: `docs/2026-11-22-tab-process-memory.md`에 숫자를 남긴다. **판단 기준은 비율이 아니라 "가장 큰 범인들이 고아인가"다.** 그렇다면 멈추고 intent를 고쳐("탭 밖" 행이 본체) 다시 승인받는다. 아니라면 1단계로 간다. 이 경우 시트에 고아 안내 줄을 둔다(spec §6).

## 1. 프로세스 헬퍼 (TDD)
- [ ] **빨강(tty)**: `Process`로 `/usr/bin/script -q /dev/null /bin/sleep 30`, `standardInput = FileHandle.nullDevice`(stdin이 tty가 아니어도 sleep이 pty 위에 뜬다, 실측) → sleep의 `e_tdev` → `devname` → 그 이름을 받는 `pids(onTTY:)`에 sleep이 있는지.
- [ ] **초록**: `childPIDs`의 버퍼를 4096 고정으로(`// ponytail:` 한계 주석). `pids(onTTY name: String) -> [pid_t]`: `stat` → `st_rdev` → NULL 호출로 상한 → 그 크기로 `proc_listpids(PROC_TTY_ONLY)`, **바이트 수를 pid 크기로 나눈다**. 주석에 `childPIDs`(개수)와의 차이를 적는다.
  → verify: tty 테스트 초록, 기존 `TerminalStateDetectorTests` 초록. `proc_listpids` 반환을 개수로 읽게 바꾸면 tty 테스트가 빨개진다(sleep 이외 쓰레기 pid 또는 범위 초과).

## 2. 탭 측정 함수 (TDD)
- [ ] **빨강(표)**: `measureTab(roots:children:sample:)` — spec §7의 표(루트 둘 + 손자 합, 중복 pid 한 번, `.denied`는 개수만, `.launcher`는 어디에도 안 셈, `.gone` 무시, 가장 큰 이름).
- [ ] **빨강(진짜 프로세스)**: `sh → sh → perl(약 20MB, `'a' x 10_000_000`)` 사슬, 바깥 sh를 루트로 잰 합 ≥ perl 자신의 footprint. 테스트 호스트(=앱)를 루트로 쓰지 않는다. `defer`로 사슬 전체를 죽인다(바깥 sh만 죽이면 perl이 고아로 남는다 — `childPIDs`로 내려가며 죽인다).
- [ ] **초록**: `measureTab`, 그리고 실제 `sample(pid)`: `proc_pid_rusage` V4 → `.footprint(bytes, proc_name)`, `ESRCH` → `.gone`, `EPERM`이면 sysctl ppid가 `getpid()`인지 보고 `.launcher` 아니면 `.denied`.
  → verify: 표·진짜 프로세스 초록. 자손 걷기를 빼면(루트만 재면) 진짜 프로세스 테스트가 빨개진다.

## 3. 목록 모델과 문자열 (TDD)
- [ ] **빨강**: 순수 함수 — `[(session, project, worktree?, TabMemory)]` → 정렬된 행 문자열, 합계, 고아 안내 줄. `2 GB  node`, `+`(denied > 0), 워크트리 하나인 프로젝트는 워크트리 생략, 잰 프로세스가 없는 탭 제외, 합계 `Tabs: 7.4 GB`.
- [ ] **초록**: 함수 + `AppModel.tabMemoryRows()`(hosts를 돌며 `ghostty_surface_tty_name` → `pids(onTTY:)` → `measureTab`). `TerminalHostProtocol`에 `ttyName: String?` 하나를 더하고 NoOp/Mock은 nil.
- [ ] **빨강/초록(이동)**: 다른 프로젝트의 행을 고르면 `selection.id`가 그 프로젝트, `activeSessionID`가 그 탭이 되는지(기존 `MockProjectCoreClient` 패턴). 그리고 느린 조회 중에 다른 숫자 키가 추월하면 `activeSessionID`가 바뀌지 않는지(`selectWorktree`의 Bool. `test_an_overtaken_digit_does_not_empty_the_project_it_was_overtaken_by`처럼 `Task.detached` 지연). `workspacePath`가 빈 옛 세션은 프로젝트 경로로.
  → verify: 유닛 전체 초록.

## 4. 시트와 메뉴
- [ ] `TabMemorySheet`: `List` + 버튼 행, 맨 위 합계와 고아 안내 줄, Refresh. `.onAppear`에서 잰다. 행의 접근성 라벨 = 행 문자열.
- [ ] Window 메뉴(`CommandGroup(after: .windowArrangement)`)에 "Tab Memory…". 단축키 없음 — `AppShortcut` 표와 pre-commit 훅 규칙 밖이다.
  → verify: Release 빌드 + 유닛 전체 + pre-commit 통과. XCUITest `test_declared_commands_are_wired_to_menu_items`가 여전히 초록(새 단축키가 없으므로 영향 없음을 확인만).

## 5. 실측 검증 (사용자 기계 앞에서)
- [ ] spec §7 수동 오라클: 다른 프로젝트 탭의 백그라운드 perl(약 1.9GB) → 시트 맨 위에 `perl` → 숫자가 `footprint -p`와 같은 자릿수 → 누르면 그 탭에 선다.
- [ ] **에이전트가 띄운 백그라운드 작업**: 탭의 claude에게 `node -e 'setInterval(()=>{},1e3)' &`을 시킨다. 그 node는 목록에 **없는 것이 기대값**이다(`ppid=1 tty=??`). 시트에 고아 안내 줄이 보이는지 확인한다. 0단계 결과로 고아 행을 만들기로 했다면 거기에 나와야 한다.
- [ ] **tty 이름 확인**: 탭 몇 개에서 시트가 잡은 프로세스와 `ps -t <tty>`가 같다(fable이 포인터 안전을 확인했으므로 확인 차원).
- [ ] ssh 탭이 `ssh`로 바닥에, "Press any key" 탭은 없음, `sudo sleep 600 &`이 있는 탭은 `+`.
- [ ] 접힌 그룹·닫힌 shelf 안 프로젝트의 탭도 목록에 있고 누르면 간다.
- [ ] **포커스 오라클**: 행을 누르고 바로 타이핑한다. 글자가 그 탭에 들어가고 빈 화면이나 낡은 프레임이 없어야 한다(CLAUDE.md "포커스는 표면이 스스로"와 "Ctrl-L로 살아나는 빈 화면").
  → verify: 결과를 docs에 남긴다.

## 6. 리뷰와 마무리
- [ ] 구현 리뷰를 codex와 fable에게 병렬로 받는다. 지적을 반영한다.
- [ ] `ponytail-review`.
- [ ] CLAUDE.md "Terminal State Detection"에: 탭의 프로세스는 tty로 잡는다(왜 `shellPID`가 아닌지 — fork는 IO 스레드), `proc_listpids`는 바이트·`proc_listchildpids`는 개수, 고아는 안 보인다, `+`의 뜻.

## 커밋 단위
0(docs, 실측) → 1(헬퍼) → 2(측정) → 3+4(목록·시트) → 5·6(docs, CLAUDE.md).

## 리뷰 반영 중 설계가 바뀌어 성립하지 않게 된 것
목록을 열 때 한 번 재는 설계로 바뀌면서 저장하는 상태, 기준치, 필터가 없어졌다. 아래 지적은 맞았지만 고칠 대상이 사라졌다.
- codex·fable: "상태에는 날 바이트를 두고 화면에서만 반올림한다, 기준치는 날값에 적용한다". 날값은 그대로 받았다(spec §2). 기준치는 없어졌다.
- codex: "탭 닫기 정리 경로(`AppModel.swift:1533-1542`)에 맞춰 상태를 지운다". 저장하는 상태가 없다.
- fable: "1GB 기준치는 7.35GB 중 2GB만 보인다". 목록이 모든 탭을 정렬한다.
- fable: "ssh 필터와 0.1GB 바닥 중 하나만". 둘 다 없앴다.
- codex: "알약에 접근성 라벨". 알약이 없어졌고, 목록 행에 같은 요구를 적용했다(spec §5).

## 리뷰에서 받지 않은 것
- codex: "shellPID에 시작 시각을 저장해 pid 재사용을 거른다". 이 기능은 pid를 저장하지 않는다. 열 때마다 tty로 새로 찾는다. 걷는 사이의 재사용은 ms 창이고, 그 결과는 순간값 하나에 그친다.
- codex: "메인 스레드 대신 백그라운드에서 모아 한 번 게시한다". 열 때 한 번이고, 기계 전체 걷기가 상한이다(8.5ms). 0단계에서 50ms를 넘으면 그때 옮긴다.
- fable: "Level 1의 shellPID 경주를 고친다(최소한 nil 개수를 센다)". 소스로 사실임을 확인했다(`Surface.zig:744` → `Exec.zig:86-108`). 하지만 이 기능의 범위가 아니다. 별건으로 보고한다.
