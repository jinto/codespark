# Plan: 사이드바 워크트리 — 부제 줄이 비지 않게

> 개정 2 — codex 리뷰(2026-08-25) 반영: 캐시 콜드 상태 정의, 플랫 repo·원격 상태 명시, 증상 4에 대한 입장, 테스트 보강.

## 문제 (사용자 보고, 스크린샷 4장)

1. `lxp_services_ai` 행에 설명 없는 **빈 줄**이 있다.
2. 그 행을 클릭했더니 워크트리 정보가 **사라졌다**.
3. 한 번 더 클릭하니 `main` + `·· 1 more`가 나왔다.
4. 어느 순간 워크트리가 전부 보인다.

### 원인

접힘 기제가 둘인데 둘 다 화면에 자기 상태를 말하지 않는다.

| 기제 | 범위 | 저장 |
|---|---|---|
| `expandedProjectIDs` (트리 열림/닫힘) | 프로젝트 | UserDefaults — **영구** |
| `projectsShowingEveryWorktree` (탭 없는 워크트리 펼치기) | 프로젝트 | 메모리 — **실행마다 리셋** |

저장 방식이 비대칭이라 "열려 있는데 자식이 0개"는 드문 사고가 아니라 **재실행 때마다의 기본 상태**다 — 탭 없는 워크트리를 가진 열린 프로젝트는 전부 여기 빠진다.

- **(1) 빈 줄**: 열림이면 `ProjectSidebarRow`가 부제를 `.opacity(0)`으로 감추고 자리만 남긴다(`SidebarView.swift:436`). 자식이 전부 접히면 그 빈 줄을 설명할 게 화면에 없다.
- **(2) 클릭이 정보를 감춤**: 이미 열려 있던 트리라 클릭이 닫았다(`selectProjectAndToggleWorktrees`). 열려 있다는 표시가 없었으므로 클릭이 열지 닫을지 예측할 수 없다.
- **(3) 개수가 클릭으로 변함**: "지금 서 있는 워크트리는 접지 않는다" 예외가 **선택된 프로젝트에만** 걸린다(`AppModel.swift:1068`). 선택되는 순간 행이 하나 늘어 `2 more` → `1 more`.
- **(4) 목록이 나중에 또 변함**: 워크트리 목록은 git 왕복으로 온다. 선택 안 된 프로젝트는 `GitWorktreeService` 캐시로, 선택된 프로젝트는 라이브 `workspaces`로 그룹핑하며, 폴링(10초)이 새 워크트리를 발견하기도 한다.

## 결정

접힘은 **유지**한다(워크트리가 쌓이는 repo에서 목록이 길어지는 걸 막는 장치는 계속 필요하다). 대신 **부제 줄이 절대 비지 않게** 하고, 접기 규칙에서 예측 불가능한 두 조건을 뺀다.

### 1. 부제 줄은 언제나 무언가를 말한다

개수의 출처는 **`gitWorktreeService.worktrees(for: project.path)` 하나**다. 이 값은 `[GitWorktree]?` — **nil이면 "아직 모름", 배열이면 "안다"** 이고, 선택 여부와 무관하게 같은 답을 준다. (지금 `sidebarWorktrees(for:)`가 선택된 프로젝트만 라이브 그룹핑을 읽는 것과 달리, 부제는 이 한 곳만 본다.)

| 프로젝트 행 상태 | 부제 | 자식 행 |
|---|---|---|
| 개수 모름 (캐시 콜드 / 조회 실패, 열림·닫힘 무관) | `main` / `non-git` / `jinto@kt-server` — 정체만 | 없음 |
| 워크트리 1개 (플랫) | 정체만 | 없음 — 이 행이 곧 그 워크트리 |
| 닫힘, 워크트리 2개 이상 | `main · 3 worktrees` | 없음 |
| 열림, 워크트리 2개 이상 | `3 worktrees` | main + 탭 있는 것 + `·· N more` |
| 정체도 모름 (브랜치 조회 전) | 지금과 동일하게 빈 줄 — 추측을 쓰지 않는다 | — |

- 닫힘에 개수가 붙으므로 **열기 전에 안에 뭐가 있는지 안다** — (2)의 놀람이 사라진다.
- 열림에서 정체(브랜치/호스트)를 빼는 이유: 바로 아래 `main` 워크트리 행이 그걸 말한다. 한 줄 차이로 같은 단어를 두 번 쓰지 않는다. **이것이 `.opacity(0)`를 지울 수 있게 하는 조건이다** — 개수 없이 감춤만 지우면 `main`이 한 줄 간격으로 두 번 나온다.
- 열림 부제가 곧 **"열려 있다"는 표시**다. 삼각형을 없앤 뒤 비어 있던 자리를 이 줄이 메운다.
- **플랫 repo(워크트리 1개)는 지금 그대로다.** `sidebarWorktrees(for:)`가 `[]`를 돌려주므로 열림 플래그가 있어도 자식이 없고, 아래 규칙 2의 "main은 접지 않는다"도 해당 사항이 없다. 프로젝트 행 하나가 전부다.
- **개수를 모르는 동안에는 개수를 쓰지 않는다.** `non-git`을 조회 전에 말하지 않는 것과 같은 규칙이다. 답이 도착하면 부제가 `main` → `main · 3 worktrees`로 바뀌고, 열려 있었다면 자식 행이 함께 나타난다. git 왕복을 없앨 방법은 없으므로, 목표는 **변화가 설명되게** 하는 것 — 늘어난 이유가 같은 줄에 숫자로 적힌다.
- **원격**: 부제의 정체는 계속 `user@host`다. 개수는 스캔이 성공한 뒤에만 붙는다. `remotePath` 없는 `ssh://host`는 애초에 스캔 대상이 아니므로(`worktreeProjectPaths`) 영원히 정체만 보인다. 조회가 실패해도 캐시가 직전 목록을 유지하므로(`expireCache` 규칙) 개수는 마지막으로 알던 값을 유지한다 — 실패가 워크트리 삭제로 읽히면 안 된다는 기존 원칙과 같다.

### 2. 열려 있으면 `main` 워크트리 행은 접지 않는다

열림에 자식이 있는 경우(워크트리 2개 이상), 거기엔 항상 최소 한 줄의 실체가 따라온다. "열렸는데 `·· 2 more` 한 줄뿐"인 상태가 성립하지 않는다.

### 3. 접기 판정에서 선택 여부를 뺀다

`selectedProjectID == project.id && workspace.path == activeWorkspacePath`를 `workspace.path == projectSelectedWorkspaces[project.id]`로 바꾼다. 그 프로젝트에서 마지막으로 서 있던 워크트리는 선택 여부와 무관하게 보인다 → 클릭 전후 행 목록이 같다. 기록이 없는 프로젝트(이번 실행에 한 번도 안 들어간 곳)는 규칙 2가 main을 지키므로 빈 트리가 생기지 않는다.

클릭 동작(`선택 + 토글`)은 **그대로 둔다**. 부제가 상태를 말하게 되면 다음 클릭이 뭘 할지 예측 가능해진다.

### 증상 4에 대한 입장

목록이 늘어나는 것 자체는 기능이다 — 폴링이 밖에서 만든 워크트리를 발견하고(CLAUDE.md, 최대 ~40초), 캐시가 콜드였다가 채워진다. 이 플랜이 없애는 것은 *설명 없이* 늘어나는 것이다:

- **클릭 때문에** 변하던 몫은 규칙 3이 없앤다 (같은 데이터, 같은 목록).
- **데이터가 도착해서** 변하는 몫은 남는다. 대신 부제의 숫자가 같이 바뀌므로 "왜 늘었나"가 화면에 적힌다.
- 여기서 더 가려면 `workspaces(for:)`의 두 경로(선택=라이브 그룹핑 / 비선택=캐시 그룹핑)를 하나로 합쳐야 한다. 그건 탭 그룹핑 전체를 건드리는 별건이므로 이 플랜에 넣지 않는다. 부제만은 규칙 1대로 이미 단일 출처를 쓴다.

## Blast Radius

| 파일 | 변경 |
|---|---|
| `Models/AppModel.swift` | `projectInfoLine(for:)`에 규모 접미사(열림이면 규모만); 개수 출처 헬퍼 하나; `sidebarWorktreeRows(for:)`의 shown 필터 두 줄 |
| `Views/SidebarView.swift` | `ProjectSidebarRow`의 `.opacity(...)`와 `showsWorktreeRows` 파라미터 제거(용도가 그 하나였다) |
| `CodeSparkTests/AppModelTests.swift` | 아래 테스트 |
| `CLAUDE.md` | Worktree Scoping 절 갱신 (아래 대체 문구) |

새 파일 없음. `projectsShowingEveryWorktree` / `revealFoldedWorktrees` / `FoldedWorktreesRow` / `worktreePathLine`은 그대로 둔다.

## CLAUDE.md 대체 문구 (지금 문서와 정면으로 어긋나므로 함께 고친다)

지금: "**감추되 자리는 남긴다** — 상태 점과 같은 이유다. 줄을 없애면 방금 클릭한 행이 커서 밑에서 한 줄만큼 짧아진다."

바뀔 내용: 프로젝트 행의 부제는 **감추지 않는다. 상태에 따라 다른 사실을 말한다** — 닫히면 그 워크트리의 정체(`main`/`non-git`/`user@host`)에 규모를 덧붙이고(`main · 3 worktrees`), 열리면 규모만 말한다(`3 worktrees`). 정체는 바로 아래 main 워크트리 행이 이어받으므로 중복이 없고, 줄이 언제나 채워지므로 높이도 변하지 않는다. **빈 줄은 설명이 없다** — 열렸는데 자식이 전부 접힌 상태에서는 그 자리가 사용자에게 렌더 오류로 읽혔다.

## 테스트 (red → green 순서)

`AppModelTests` — 부제:

1. `test_a_closed_project_row_names_its_branch_and_how_many_worktrees` — 워크트리 3개, 닫힘 → `main · 3 worktrees`.
2. `test_an_open_project_row_says_only_how_many_worktrees` — 열림 → `3 worktrees`, 브랜치 문자열을 포함하지 않는다.
3. `test_a_flat_project_row_says_only_its_branch` — 워크트리 1개는 열림·닫힘 모두 `main`, 자식 행 없음.
4. `test_a_project_row_omits_the_count_until_the_worktrees_are_known` — 캐시 콜드(`worktrees(for:)` == nil) → `main`. 캐시가 채워진 뒤 같은 프로젝트를 다시 읽으면 `main · 3 worktrees`. **콜드 → 웜 전이를 한 테스트 안에서 본다.**
5. `test_a_remote_project_row_keeps_its_host` — ssh: 콜드 → `jinto@kt-server`, 스캔 성공 후 → `jinto@kt-server · 2 worktrees`, `remotePath` 없는 `ssh://host` → 언제나 정체만.

`AppModelTests` — 접기:

6. `test_an_open_tree_always_shows_at_least_the_main_worktree` — 탭이 하나도 없고 `projectSelectedWorkspaces`에 기록도 없는 프로젝트를 열어도 `shown`에 main이 있다. **(1)의 회귀 테스트.**
7. `test_the_shown_worktrees_do_not_change_when_the_project_is_selected` — 선택 전/후로 `sidebarWorktreeRows`를 읽어 **`shown`의 path 배열과 `foldedCount`가 모두** 같다. 개수만 비교하면 엉뚱한 워크트리가 보여도 통과한다. **(3)의 회귀 테스트.**
8. `test_a_worktree_discovered_later_appears_and_the_count_says_so` — 캐시에 워크트리를 하나 더 넣고 다시 읽으면 `shown`/`foldedCount`와 부제 숫자가 함께 늘어난다. 증상 4에서 "남기기로 한 변화"를 명시적으로 못 박는다.

소스 게이트:

9. `test_the_project_row_never_hides_its_own_subtitle` — `Views/`에서 `.opacity(` + `showsWorktreeRows` 패턴을 거부한다. 뷰 문자열·모디파이어는 렌더 테스트로 안 보이므로 소스에서 막는다(`SidebarTypographyTests`와 같은 성격).

수동 확인: 앱을 띄워 워크트리 2개 이상인 프로젝트를 접었다 폈다 하며 5상태를 눈으로 본다.

## 검토한 대안

- **자동 접기 제거 (`N more` 삭제)**: 상태가 2개로 줄어 가장 단순하지만, 워크트리를 쌓아두는 repo에서 사이드바가 길어진다. 사용자가 접힘 유지를 택했다.
- **얇은 부제 줄 전부 삭제**: 빈 줄 문제를 원인째 없애지만 ssh 호스트 구분이 사이드바에서 사라진다. 사용자가 거절했다.
- **선택된 프로젝트만 펼치는 아코디언**: `expandedProjectIDs`가 통째로 사라지지만, "다른 프로젝트로 옮겨가도 열어둔 트리는 그대로"(커밋 `5b73483`, CLAUDE.md에 명시)를 뒤집는다.
- **개수 없이 `.opacity`만 제거** (codex가 제안한 최소 패치): 열렸을 때 프로젝트 행과 그 아래 main 행이 `main`을 한 줄 간격으로 두 번 말한다. 개수는 장식이 아니라 감춤을 지울 수 있게 하는 조건이다.

## 위험

- `main`이 열림 상태에서 항상 보이므로, 워크트리가 많은 repo를 열면 최소 한 행이 늘어난다. 열림 상태에서만이고, 그 한 행이 "열려 있다"의 증거다.
- 부제가 `projectInfoLine`에서 워크트리 개수를 읽으므로 행마다 캐시 조회가 한 번 더 붙는다. `showsWorktreeRows(for:)`가 이미 같은 조회를 하고 있어 새 왕복은 아니고, 사전 조회(dictionary lookup)다.
