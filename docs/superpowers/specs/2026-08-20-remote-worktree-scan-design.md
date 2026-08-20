# 원격(ssh) 프로젝트 워크트리 스캔

작성일: 2026-08-20
브랜치: `worktree-remote-worktree-scan`

## 문제

로컬 프로젝트는 사이드바에 워크트리가 자식 행으로 펼쳐지고, 탭바·`Cmd+[/]`·`Cmd+1…9`가 전부 그
워크트리 단위로 스코프된다. 원격(ssh) 프로젝트는 이 전부에서 배제되어 있다 — 원격 리포에
워크트리가 여러 개 있어도 앱은 프로젝트 하나로만 본다.

배제된 지점:

- `AppModel.worktreeProjectPaths` — `transport != "ssh"` 필터
- `AppModel.selectProject` (AppModel.swift:210) — refresh 호출부 자체가 `detail.transport != "ssh"`로 막힘
- `GitWorktreeService.fetchWorktrees(at:)` — 로컬 `/usr/bin/git -C <path>`. ssh 프로젝트의 `path`는
  `ssh://user@host/path` URI라 `-C` 인자로 무의미
- `AppModel.visitingBranch` — ssh면 즉시 nil

## 범위

로컬과 **완전 동등**: 스캔 + 사이드바 행 + 탭 열기 + 원격 워크트리 생성/삭제.
`remotePath`가 없는 `ssh://host` 프로젝트는 리포 위치를 알 수 없으므로 스캔하지 않는다.

## 핵심 결정: 워크스페이스의 주소는 URI

원격 워크트리의 `workspacePath`는 `ssh://user@host/home/u/worktrees/repo-feat-ab12`.

`workspacePath`는 단순 문자열이 아니라 **탭의 소속을 정하는 키**다. 그룹핑
(`WorkspaceViewData.groupSessions`), 삭제 판정(`SessionViewData.belongs(to:)`), 복원 기억
(`workspaceSelectedSessions`), `Cmd+1…9`(`numberedWorkspaces`)가 전부 이 문자열을 쓴다.

프로젝트 경로가 이미 URI라 같은 문자열 공간에 살고, 호스트가 다르면 자연히 다른 키가 되며,
`SSHConnectionInfo(uri:)`로 되파싱해 그 워크트리로 ssh 탭을 열 수 있다. 스토어 스키마 변경 없음.

기각한 대안:
- **원격 raw 경로** — 로컬 경로와 구분 불가, 호스트 간 충돌, 소속 판정이 두 값으로 쪼개짐
- **`(host, path)` 복합 키 타입** — `workspacePath: String`을 쓰는 모든 곳(스토어 컬럼 포함) 변경 필요.
  URI가 문자열 하나로 같은 보장을 준다

### 두 네임스페이스를 섞지 않기

원격 세션은 **두 종류의 경로**를 동시에 들고 있다.

| 값 | 형태 | 쓰는 곳 |
|---|---|---|
| `workspacePath` | URI (`ssh://…`) | 소속·그룹핑·선택·기억 |
| `lastCwd` | 원격 raw 경로 (`/home/u/…`) | Ghostty working directory, 복원 시 `cd` 대상 |

git 인자에는 **절대 URI가 가면 안 되고**, `workspacePath`에는 **절대 raw 경로가 가면 안 된다**.
이 변환을 `SSHConnectionInfo` 한 곳에 가둔다:

```swift
func workspaceURI(forRemotePath: String) -> String            // raw → URI (자기 authority 승계)
static func remotePath(fromWorkspaceURI: String) -> String?    // URI → raw
```

그룹핑·add/remove·`visitingBranch`·`newSession`이 전부 이 두 함수만 쓴다.

**Canonical 형태**: trailing slash 제거, percent-encoding 없음, 사용자·포트 표기는 프로젝트 URI에서
그대로 승계. 같은 원격 위치가 두 개의 다른 키가 되면 탭이 미아가 되므로, URI 생성은 이 한 곳
외에서 하지 않는다.

**알려진 한계 (범위 밖)**: `SSHConnectionInfo.init(uri:)`의 `lastIndex(of: ":")` 방식은 IPv6 리터럴
호스트에서 지금도 깨진다. 이번 작업으로 생기는 결함이 아니므로 여기서 고치지 않는다.

## 설계

### 1. 스캔

분기는 `GitWorktreeService.fetchWorktrees(at:)` 한 곳. 캐시 키·프루닝은 그대로 두고, 받은 경로를
`SSHConnectionInfo(uri:)`로 파싱해 성공 + `remotePath`가 있으면 원격 경로로 간다.

```
ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    [-p port] [user@]host  "git -C '<repo>' worktree list --porcelain"
```

- `BatchMode=yes` — 백그라운드 스캔이 비밀번호 프롬프트에 매달리면 안 된다
- `ServerAlive*` — `ConnectTimeout`은 연결 단계만 막는다. 연결된 뒤 원격 git이 멈추는 경우를 위해
  프로세스 전체 하드 타임아웃도 함께 건다
- **ControlMaster는 쓰지 않는다.** 얻는 것은 지연시간뿐인데 고아 마스터, 동시 첫 연결 race,
  소켓 경로 길이 제한, dead socket 재사용 같은 실패 모드를 새로 들인다. 30초 TTL이 이미 빈도를
  제한한다. 대신 **동시 실행 수를 제한**한다 (프로젝트 수만큼 ssh를 한꺼번에 띄우지 않는다)
- 출력 파싱은 `parseWorktreeList`를 그대로 재사용하고, 나온 원격 경로만 URI로 감싼다
- `worktreeProjectPaths`와 `selectProject`의 호출 게이트를 **둘 다** 연다. 하나만 고치면 원격
  refresh는 영영 호출되지 않는다

**테스트 가능성**: ssh 실행 파일 경로를 주입 가능하게 한다(기본 `/usr/bin/ssh`). 테스트는 스텁
스크립트를 가리켜 sshd 없이 argv와 파싱을 검증한다.

### 2. 실패해도 화면을 비우지 않는다

**이 기능의 본체는 스캔이 아니라 실패 경로다.** 원격은 일상적으로 끊긴다.

현재 구조에서 조회가 실패하면:
캐시가 `nil` → `groupSessions`가 프로젝트 URI 하나짜리 워크스페이스 반환 →
`visibleSessions`(AppModel.swift:81)가 활성 워크트리 URI를 못 찾아 `[]` →
**메인 영역 빈 화면**. 그리고 `recomputeWorkspaces`의 정정 로직은 `worktrees == nil`일 때
일부러 아무것도 하지 않는다(그게 옳다 — 조회 실패는 워크트리 삭제가 아니므로).

→ **실패 시 직전 성공 목록을 유지한다.** 캐시 엔트리가 실패로 덮이지 않고, 이전 워크트리 목록을
실패 TTL과 함께 들고 있는다. `CLAUDE.md`의 "git 조회 실패와 워크트리 삭제됨은 다르다"를 선택뿐
아니라 화면까지 밀어붙이는 것.

### 3. 활성 워크스페이스 폴백

메인 워크트리의 URI가 프로젝트 URI와 다를 수 있다 — 프로젝트 URI가 리포 하위 디렉터리를
가리키거나 trailing slash가 붙은 경우, git은 canonical 리포 루트를 돌려준다.

`apply(detail:)`이 `activeWorkspacePath = detail.path`로 되돌릴 때 그 경로가 어떤 워크스페이스와도
안 맞으면, 프로젝트 URI가 아니라 **메인 워크트리**로 떨어진다.

### 4. 생성 — 원격 스크립트 한 번

로컬은 `FileManager.fileExists` 루프로 이름 충돌을 피하지만 원격에선 그 검사가 없다. 또
`'~/worktrees'`는 따옴표 안에서 tilde expansion이 일어나지 않는다. 둘 다 한 번의 원격 스크립트로
푼다:

1. `$HOME` 기반으로 루트 전개 (따옴표 밖에서)
2. `test -e`로 충돌 확인 — 있으면 전용 exit code
3. `mkdir -p`
4. `git -C '<repo>' worktree add -b '<branch>' "<root>/<name>"`
5. **만들어진 절대 경로를 stdout으로 출력**

로컬은 그 경로를 받아 URI로 감싼다. 충돌 exit code면 id를 한 번 재추첨해 재시도하고, 그래도
실패하면 에러를 노출한다.

원격 리포 이름은 URI가 아니라 **raw remote path**의 마지막 컴포넌트에서 뽑는다
(`makeWorktreeName`에 URI를 그대로 넘기지 않는다).

### 5. 삭제 — git 성공 후 탭을 닫는다

현재 `removeWorktree`는 git 삭제 **전에** 탭을 닫는다. 원격에선 연결 실패가 흔해서, 삭제가
실패해도 탭만 날아간다. 순서를 뒤집는다 — **로컬 동작도 같이 바뀐다**. 원격만 다르게 둘 이유가
없다.

닫을 탭을 고르는 기준은 그대로 `session.belongs(to: <uri>)`다.

### 6. `isRefreshing`

전역 락이라 진행 중이면 이후 요청을 버린다. 원격 조회가 느려지면 워크트리 생성/삭제 직후의
refresh가 조용히 버려질 확률이 실질적으로 올라간다. 버리는 대신 진행 중인 refresh의 완료를
기다리도록 바꾼다.

### 7. UI

새 화면 없음. 사이드바 자식 행·`Cmd+1…9`·탭바 스코프는 `workspaces`만 보므로 자동으로 따라온다.

- `AddWorktreeSheet` 미리보기 경로가 원격 루트를 보여줘야 한다
- `visitingBranch`의 ssh 가드 해제 — 비교 전에 `lastCwd`(raw)를 프로젝트 authority와 결합해 URI로
  만든 뒤 `WorkspaceViewData.containing(cwd:in:)`에 넘긴다

### 8. 새 탭

`newSession`의 ssh 분기가 지금은 `workspacePath = project.path` 고정이다. 활성 워크스페이스로
바꾸고, 그 URI의 raw 경로를 `info.remotePath`에 넣어 `cd`가 들어가게 한다.
복원 경로(`restoreInterruptedTabs`)는 이미 `workspacePath`를 보존하므로 그대로 동작한다.

## 테스트 (TDD, red 먼저)

- **순수 빌더**: 원격 git argv — 경로에 공백/작은따옴표가 있어도 원격에서 한 단어로 살아남는지.
  스텁 `ssh`로 argv 검증 (sshd 없이 CI에서 돎)
- **URI 왕복**: `workspaceURI(forRemotePath:)` ↔ `remotePath(from:)`, trailing slash·포트·사용자 표기
- **실패 경로**: 조회 실패 시 직전 워크트리 행이 유지되고 `visibleSessions`가 비지 않는지
- **폴백**: 프로젝트 URI가 리포 하위를 가리킬 때 메인 워크트리로 떨어지는지
- **legacy 원격 세션**(빈 `workspacePath`)의 그룹핑과 삭제
- **AppModel**: `primeCache`에 ssh URI 워크트리를 넣고 → 사이드바 행, `Cmd+1…9` 번호,
  새 탭 ssh 명령의 `cd`, 삭제가 그 워크트리 탭만 닫는지
- **삭제 순서**: git 실패 시 탭이 살아남는지
- **실제 ssh**: `SSHIntegrationTests` 방식 — localhost sshd에 `/tmp`의 진짜 리포+워크트리로
  스캔/add/remove 왕복. sshd 없으면 `XCTSkip` (현재 이 머신에서는 skip된다)
- **회귀**: 기존 192개 전부 그린 유지

## 알려진 대가

- `BatchMode=yes`라 키 인증이 안 되는 호스트에서는 워크트리 행이 조용히 안 나온다(에러 배너 없음).
  사용자가 직접 누르는 생성/삭제는 실패 시 기존대로 `loadErrorMessage`에 표시된다.
- IPv6 리터럴 호스트는 기존 파서 한계로 지원하지 않는다.
