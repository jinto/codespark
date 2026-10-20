# Intent: Overhaul — 전수조사와 수정

- Date: 2026-08-30
- Status: done — d22e7f7…2b45afc 2026-08-30~31 (plan.md 6-A~6-D [x]); AppModel 타입 분해만 미완 [~]
- Origin: retroactive — spec.md/plan.md에서 2026-10-20 재구성
- Next: plan.md

## Problem
같은 종류의 버그가 계속 돌아온다. `fix:` 커밋 약 60개 중 57%가 `AppModel.swift`·`SidebarView.swift` 두 파일에 몰려 있고, 거의 전부 "이 탭 / 이 문자열은 어느 행의 것인가"의 변주다. `Cmd+1…9`의 대상은 세 번 바뀌었다.
구조적 원인은 넷이다: 워크스페이스 주소가 타입이 아니라 관습이고, 선택이 두 개의 키로 표현되며, 고쳐진 버그가 형제 코드에 가지 않고, 막는다고 선언한 게이트 중 셋이 실제로는 아무것도 막지 않는다.
그 결과 데이터를 잃거나 앱이 죽는 결함이 남아 있다: ssh 인자 인젝션(로컬 임의 명령), 마이그레이션 중단 시 매 실행 크래시, 복원 중 종료 시 탭 영구 삭제, 다른 프로젝트의 워크스페이스가 붙은 탭이 영구 기록됨.

## Proposed outcome
- Critical 결함이 닫히고, 게이트(빌드 페이즈·Zig 테스트·Stop 훅·릴리즈 DMG)가 실제로 실패할 수 있게 된다.
- 같은 질문이 반복되지 않도록 구조로 막는다: 주소는 하나의 타입, 선택은 하나의 값, 사이드바 표현은 순수 함수, 서브프로세스는 하나의 헬퍼.
- 출하하는 것을 테스트한다.
- 죽은 코드와 낡은 문서를 정리한다.

## Affected users and systems
- Code Spark 사용자(로컬·ssh 프로젝트, 세션 복원, 사이드바).
- AppModel·사이드바, git/ssh 서비스, Zig 스토어·C API, 빌드 페이즈·훅·릴리즈 워크플로, 문서.

## Constraints
- 가드를 덧붙이는 방식으로 고치지 않는다. 오염이 "조용히 삼켜진 Cmd+T"로 바뀔 뿐이다.
- 각 게이트는 되돌려 빨간불을 확인한다.

## Out of scope
- Ghostty 임베딩 계층 재작성. 대체 불가능한 지식이 거기 있다.
- 원격 워크트리를 로컬 경로와 같은 문자열 공간에 둔 결정(틀린 것은 결정이 아니라 타입이다).
- `TerminalHostProtocol` + `NoOpTerminalHost`, FFI 소유권 경계, 주석 밀도 — 현상 유지가 옳다.

## Open questions
- core/FFI 감사의 마지막 보고가 전송 중 잘렸다(A5 중간). codex 보고와 겹쳐 보이나 확인되지 않았다.
- ssh 목적지 6곳 통합은 별도 결정: `ConnectTimeout` 5 vs 8 중 어느 쪽이 의도인지 기록이 없다.
- `AppModel` 타입 분해(`ProjectStore` / `SessionCoordinator`)는 미완.
