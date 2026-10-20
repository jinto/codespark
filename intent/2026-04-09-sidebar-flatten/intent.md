# Sidebar Flatten — Project-Only List

- Status: superseded — 43f89a8 2026-04-09 출하 후 워크트리 사이드바 트리(e3f8e3e 2026-08-11)로 계층 복귀

## Goal
사이드바를 프로젝트 평탄 리스트로 단순화. 워크스페이스 계층 제거.

## Changes

| # | Change | Acceptance Criteria |
|---|--------|---------------------|
| 1 | 사이드바: 프로젝트만 표시 | 워크스페이스 행 렌더링 없음 |
| 2 | 프로젝트 선택 시 `activeWorkspacePath = project.path` 강제 | 메인 워크트리 세션만 표시 |
| 3 | Cmd+1~9 → 프로젝트 전환 | 프로젝트 수 초과 시 no-op |
| 4 | 워크트리 UI 숨김 | 컨텍스트 메뉴에서 Add/Remove Worktree 제거 |
| 5 | 고아 워크트리 세션 필터링 | 모델에 존재하되 UI에 미표시 |

## Constraints
- 워크트리 서비스/모델 코드 삭제 금지 (숨기기만)
- `@AppStorage` stale workspace 값 → 프로젝트 선택 시 project.path로 덮어쓰기
- 세션 0개인 프로젝트 → 빈 상태 또는 placeholder

## Non-Goals
- 워크트리 코드 삭제
- 새 기능 추가

## Verification Sources
- Architect: APPROVED (enforce path, handle orphans)
- Critic: ITERATE → addressed (stale storage, empty state, Cmd bounds)
- CEO: APPROVED (REDUCTION — correct strategic direction)
