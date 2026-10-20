# Intent: 사이드바 강화 (M2a)

- Date: 2026-04-03
- Status: retroactive — spec.md/plan.md에서 2026-10-20 재구성
- Next: spec.md

## Problem
지금 사이드바는 project별 aggregate count만 보여준다. 어떤 세션이 열려 있는지, 각 세션이 일하는 중인지 쉬는 중인지 사이드바에서 알 수 없고, 세션 이름도 바꿀 수 없다.

## Proposed outcome
- 사이드바를 터미널 멀티플렉서 수준으로: project마다 live session 목록이 보인다.
- 세션별 상태 뱃지(Live / Idle / Closed). 10초간 출력이 없으면 Idle.
- 각 project를 Finder처럼 독립적으로 펼치고 접는다. 접힌 상태에서는 이름 옆에 종합 상태가 보인다.
- 세션 행을 더블클릭해 이름을 바꾼다(Enter 확정, Esc 취소). 탭 제목에도 바로 반영된다.

## Affected users and systems
- Code Spark 사용자.
- 사이드바, 세션 탭바, 프로젝트 저장소(project summary), 터미널 출력 추적.

## Constraints
- 사이드바 전체를 한 번의 summary 조회로 그린다.
- Idle 여부는 저장소가 아니라 앱(Swift) 수준에서 터미널 출력 시간으로 판단한다.

## Out of scope (M2b)
- Project 생성/삭제/이름 변경 UI.
- Git 브랜치 + 경로 표시.
- 검색(Cmd+K).
- Window state restoration.
