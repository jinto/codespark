# Spec: 어느 탭이 메모리를 먹는지 보이게 한다

- Intent: intent.md (draft — 승인 대기)
- Status: 만들지 않음 (2026-11-22 사용자 결정) — 조사 기록으로 남긴다

## 1. 어떤 프로세스가 한 탭에 속하는가: 그 탭 pty의 프로세스 + 그 자손

**루트를 pid로 잡지 않고 탭의 터미널로 잡는다.**

1. `ghostty_surface_tty_name(surface)` → `/dev/ttysNNN`(`ghostty.h:1195`, 지금까지 안 쓰던 API).
   - **전체 경로다**: macOS에서는 `TIOCPTYGNAME` ioctl의 결과 그대로다(`pty.zig:291-309`).
   - **문자열은 `ptr`/`len`으로 만든다**. `String(cString:)`을 쓰지 않는다(CLAUDE.md의 클립보드 `len` 함정과 같은 이유). 다 쓰면 `ghostty_string_free`로 놓는다.
   - **pty는 표면이 살아 있는 동안 산다.** 자식이 끝나도("Press any key") 이름은 남는다. 그 탭은 tty 위에 프로세스가 없어서 목록에서 빠진다(§4).
   - **스레드**: 첫 호출이 이름을 락 없이 캐시한다. Ghostty 안에서 이걸 부르는 곳은 이 C API 하나뿐이다(grep). 그래서 메인 스레드에서만 부르면 캐시 쓰기끼리는 경쟁하지 않는다. 다만 `self.pty`는 IO 스레드가 시작할 때 대입한다(`Exec.zig:911`). 막 열리는 탭은 한 번의 목록에서 빠질 수 있다. 그 탭은 다음에 열 때 나온다.
   - **포인터는 안전하다(fable 확인)**: `&(self.pty orelse return null)`(`Exec.zig:1259`)은 optional payload를 제자리에서 가리킨다. zig 0.16에서 Debug와 ReleaseFast 테스트로 확인했고, `embedded.zig:2018-2026`이 바로 `dupeZ`로 복사한다.
2. `stat(...).st_rdev` → `proc_listpids(PROC_TTY_ONLY, rdev, …)`: 그 pty를 제어 터미널로 가진 모든 프로세스. 탭의 `login`, 셸, 백그라운드 작업(`node test.mjs &`), 하위 셸 전부. 이 기계의 ssh 세션에서는 셸·claude·npm·node·caffeinate 5개가 잡혔다. 다른 터미널 앱의 `login` tty에서는 `login`과 셸이 잡혔다(실측). 그래서 §2의 `.launcher` 구분이 필요하다.
3. 그 집합에서 출발해 `childPIDs(of:)`로 자손을 더한다. `setsid`로 터미널을 떼어 냈지만 부모(에이전트)가 아직 살아 있는 도구 자식이 여기서 잡힌다. 두 경로가 같은 pid를 내므로 visited 집합이 필요하다.

**왜 `host.shellPID`가 아닌가 (fable 지적, 소스로 확인)**: `GhosttyTerminalHost.attach`는 `ghostty_surface_new` 전후로 앱의 자식 목록을 비교해 pid를 잡는다. 그런데 Ghostty는 fork를 surface_new 안에서 하지 않는다. surface_new가 IO 스레드를 띄우고(`Surface.zig:744`), fork는 그 스레드의 `threadEnter`에서 일어난다(`termio/Exec.zig:86-108`). 비교가 fork보다 먼저 끝나면 pid는 영영 nil이다. 복원 중에 앱이 띄운 git/ssh 자식이 끼어 엉뚱한 pid를 잡을 수도 있다. tty는 이 경주가 없고, pid 재사용 문제(codex 지적)도 없다 — 저장해 둔 pid가 없으므로.

### libproc 반환값
- `proc_listpids`는 **바이트 수**를 돌려준다(실측: pid 5개에 20). `proc_listchildpids`는 **개수**다. `TerminalStateDetector`에 이미 적힌 함정의 반대편이라 같은 파일에 같이 적는다.
- 버퍼가 작으면 실패하지 않고 **잘라서** 돌려준다(실측: 자식 3개, 버퍼 2칸이면 2를 반환). `childPIDs(of:)`는 256 고정이라 넘치면 조용히 자른다(codex 지적).
  - `childPIDs`: 고정 크기를 **4096**으로 올린다. 직계 자식이 4096을 넘는 프로세스는 현실에 없다. 재시도 루프나 버퍼 주입 같은 테스트 이음새는 두지 않는다. `// ponytail:` 주석에 한계를 적는다.
  - `proc_listpids`: 버퍼 없이(NULL) 한 번 불러 상한 바이트 수를 받고, 그 크기로 한 번 더 부른다. 루프는 없다.

## 2. 무엇을 재는가: 각 프로세스의 `phys_footprint` 합

- `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`. 프로세스 하나의 값은 `footprint -p`가 말하는 값과 같다(fable 확인). RSS는 공유 페이지를 프로세스마다 다시 세고 압축된 몫을 빼먹는다.
- 합은 "그 탭 프로세스들의 footprint 합"이다. Activity Monitor·다이얼로그와 같은 숫자라고 약속하지 않는다.
- 상태에는 **바이트 그대로** 둔다. 반올림은 화면에서 문자열로 바꿀 때 한 번(`ByteCountFormatter`, `.memory`). 이 포매터는 `2 GB`, `2.1 GB`, `953.7 MB`처럼 찍는다(실측) — `2.0 GB`는 안 나온다.
- **못 읽은 프로세스는 숫자에 표시한다**(codex 지적): `ESRCH`(사이에 죽음)는 무시하고, `EPERM`은 센다. 탭의 `login(1)`은 항상 EPERM이므로 빼고 센다 — 판별은 "부모가 이 앱인 프로세스"(`sysctl KERN_PROC_PID`의 ppid, root 프로세스도 읽힌다. `shell(startedBy:)`가 이미 쓰는 방식). 하나라도 남으면 숫자 뒤에 `+`를 붙이고 행의 도움말이 "N개 프로세스는 읽지 못함"을 말한다.
- 가장 큰 프로세스의 이름(`proc_name`)을 같이 낸다. 목록에서 `node`가 보여야 "아 그거"가 된다.

순수 함수로 둔다(`TerminalStateDetector` 옆, 이름은 plan에서):

```swift
static func measureTab(roots: [pid_t],
                       children: (pid_t) -> [pid_t],
                       sample: (pid_t) -> ProcessSample) -> TabMemory
// ProcessSample = .footprint(UInt64, name) | .denied | .gone | .launcher
// TabMemory = (bytes, heaviestName, deniedCount)
```

표 테스트가 가짜 트리로, 진짜 프로세스 테스트가 실제 libproc 함수로 같은 함수를 부른다.

## 3. 언제 재는가: 목록을 열 때 한 번

- 폴링하지 않는다. `@Published` 상태도 두지 않는다. 그래서 탭 닫기 정리 경로도 필요 없다.
- 시트가 뜰 때 재고, "Refresh" 버튼으로 다시 잰다.
- 메인 스레드에서 잰다. **상한이 있다**: 모든 탭의 프로세스는 기계 전체 프로세스의 부분집합이다. 기계 전체(352개)를 걷는 데 8.5ms(이 기계 실측). plan 0단계에서 사용자 기계(13일 가동, 탭 27개)로 같은 전체 걷기를 재고, 50ms를 넘으면 백그라운드로 옮긴다.

## 4. 어떤 탭이 목록에 오는가
- `hosts`의 모든 탭(선택 안 된 프로젝트 포함). 로컬·명령 탭·복원된 탭·ssh 탭을 구분하지 않는다 — 다 Ghostty 표면이고 pty가 있다. 경로가 하나라 탭 종류별 분기와 테스트가 없다(codex가 요구한 "명령 탭·복원 탭은?"의 답).
- ssh 탭은 로컬 ssh 클라이언트 몇 MB와 이름 `ssh`로 바닥에 깔린다. 숨기지 않는다. 필터가 하나 줄고, 이름이 스스로 설명한다.
- 잰 프로세스가 하나도 없으면(`.launcher`만 있거나 아무것도 없음 — 셸이 끝나 "Press any key"에 선 탭, tty 이름을 못 받은 탭) 목록에서 뺀다. 잴 것이 없다.

## 5. 화면

**Window 메뉴 → "Tab Memory…"** → 시트. 단축키는 없다(`AppShortcut` 표를 건드리지 않는다).

- 맨 위: `Tabs: 7.4 GB` (목록의 합). 그 아래 한 줄로 고아가 안 보인다는 안내(§6).
- 행(내림차순): `2 GB  node` · `프로젝트 › 워크트리 › 탭 제목`. 워크트리가 하나인 프로젝트는 워크트리를 생략한다(사이드바와 같은 규칙).
- 행 클릭 → 시트를 닫고 그 탭으로 간다: `selectWorktree(projectID:path: session.workspacePath)`. **이 함수가 돌려주는 Bool이 true일 때만** `activeSessionID = id`를 넣는다. 추월당한 네비게이션은 손을 뗀다는 CLAUDE.md 규칙 그대로다. `workspacePath`가 빈 옛 행은 프로젝트 경로로 간다.
- 시트를 닫으면서 탭을 바꾸는 것은 CLAUDE.md "포커스는 표면이 스스로" 절이 적어 둔 바로 그 경로다. 새 코드는 포커스를 주장하지 않는다(`claimFocus()` 하나만 주장한다는 게이트). 대신 오라클로 확인한다(plan 5단계).
- SwiftUI `List` + 버튼 행이라 VoiceOver가 행을 읽는다. 행의 접근성 라벨은 화면 문자열과 같다(codex: 알약의 접근성 — 알약이 없어졌으므로 행에 적용).
- 시트 문자열은 순수 함수(`TabMemory` 배열 → 행 문자열)가 만든다. 뷰는 그리기만 한다.

## 6. 알고 받아들인 한계
- **고아는 안 보인다. 생각보다 넓다.** 에이전트의 Bash 도구 셸에는 제어 터미널이 없다. 그래서 에이전트가 띄운 백그라운드 작업(`&`, `nohup`, dev 서버)은 도구 호출이 돌아오는 순간 `ppid=1 tty=??`가 된다(실측). tty 집합에도 자손 걷기에도 안 잡힌다. 셸이 끝난 탭의 `nohup` 작업도 같다. 0단계가 그 크기를 본다.
- **고아 행을 만들지 않는다면 시트가 그 사실을 말한다**: 합계 줄 아래에 "Processes detached from a tab (e.g. started in the background by an agent) are not shown." 안 그러면 `Tabs: 3.1 GB`가 조용히 적게 말한다.
- **tmux·screen 안의 프로세스도 같은 부류다**: 그 서버는 데몬이고 자기 pty를 따로 쓴다. 탭에는 클라이언트만 잡힌다.
- root·`sudo` 아래 프로세스는 숫자에 못 들어간다. `+`가 그 사실을 말한다.
- 열 때의 순간값이다. 목록을 띄워 둔 채로는 안 변한다.

## 7. 검증
- **유닛(표)**: `measureTab` — 루트 둘(tty 목록) + 손자 합, tty 목록과 자손이 같은 pid를 내도 한 번만, `.denied`는 합에서 빠지고 개수에 오름, `.launcher`(login)는 개수에도 안 오름, `.gone`은 조용히 빠짐, 가장 큰 이름.
- **유닛(진짜 프로세스)**: 테스트 호스트는 앱 자신이라(`TEST_HOST`) 자기 footprint가 기준을 넘을 수 있다 — 테스트 프로세스를 루트로 쓰지 않는다(fable 지적). `sh → sh → perl` 사슬(각 sh는 명령 뒤 `; :`로 살려 두어 exec되지 않게 한다)로 perl을 **손자**로 만들고, 바깥 sh를 루트로 잰 합이 perl 자신의 `ri_phys_footprint` 이상인지 본다. perl은 `'a' x 10_000_000`(약 20MB)이면 충분하다. 기준이 perl 자신의 값이라 크기는 상관없다. 직계 자식만 걷는 구현은 빨간불.
- **유닛(진짜 tty)**: `Process`로 `/usr/bin/script`(절대 경로)에 `-q /dev/null /bin/sleep 30`을 주고 `standardInput = FileHandle.nullDevice`로 띄운다. 그러면 pty를 만들고 sleep을 그 위에 띄운다. sleep의 `e_tdev`(sysctl)를 `devname`으로 이름으로 바꾸고 → `stat` → `proc_listpids`로 되돌렸을 때 sleep이 있는지. 앱이 실제로 타는 경로(이름 → rdev → 목록) 그대로이고, `proc_listpids`의 바이트/개수를 거꾸로 읽으면 빨간불.
- **유닛(문자열)**: 행 문자열, 합계, `+`, 워크트리 생략, 고아 안내 줄.
- **수동 오라클(사용자 기계 앞)**: 다른 프로젝트 탭에서 `perl -e '$x = "a" x 1_000_000_000; sleep 600' &`(약 1.9GB) → 시트를 연다 → 그 탭이 맨 위에 `perl`로, 숫자가 `footprint -p <perl pid>`와 같은 단위로 → 누르면 그 탭에 선다. 에이전트에게 `node -e 'setInterval(()=>{},1e3)' &`을 시킨 탭은 **안 보이는 것이 기대값**이다(0단계가 달리 말하지 않는 한). 화면 확인은 사용자가 한다(SSH 세션의 `screencapture`는 사용자 화면에 권한 프롬프트를 띄운다).

## Out of scope
- 프로세스 종료, 고아 행(0단계 결과로 재결정), 상시 배지·폴링·기준치, 앱 합계, 원격 메모리, CPU.
- **Level 1 상태 감지의 같은 경주**: `shellPID`가 위 §1의 이유로 nil일 수 있다면 그 탭은 Level 1 없이 화면 파싱만으로 상태를 정한다. 이 기능은 `shellPID`를 안 쓰므로 고치지 않는다. 별건으로 보고한다(앱 밖에서는 경주가 났는지 구분할 방법이 없어 0단계에서 재지 않는다).
