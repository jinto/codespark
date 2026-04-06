# Tasks

## M7: Workspace UX 개선 (실사용 피드백)

- [x] **새 워크스페이스 생성 위치** — 액티브 워크스페이스 바로 아래에 삽입 (현재: 목록 끝에 추가)
- [x] **닫기 확인 (Cmd+W)** — 터미널/워크스페이스 닫을 때 confirm dialog 표시. Cmd+W가 현재 동작하지 않는 버그 수정 포함
- [x] **닫힌 탭 복원 UX** — closed sessions를 하단에 모아두지 않고, 워크스페이스를 다시 열 때 "이전 세션을 다시 열까요?" 프롬프트
- [x] **자동 복원** — SSH 등 복원 가능한 세션은 프롬프트 없이 최대한 자동 복원

## M9: 알림 시스템 (cmux 스타일)

- [x] **사이드바 정렬** — Needs input 워크스페이스를 상단으로 자동 정렬
- [x] **사이드바 벨 아이콘** — unread count 뱃지
- [x] **macOS 데스크톱 알림** — idle 전환 시 알림 (다른 ws 보고 있을 때)
- [ ] **알림 스니펫** — 워크스페이스 카드에 마지막 출력 요약

## M10: 터미널 성능 + 너비 + Ctrl 키 수정

- [x] **터미널 너비** — `convertToBacking`으로 physical pixels 전달 + `autoresizingMask` 추가
- [x] **터미널 성능** — GhosttyKit ReleaseFast 빌드 (debug allocator 제거) + wakeup coalescing + run loop yield
- [x] **Ctrl+C/D/Z** — `performKeyEquivalent` override + control char text 재계산 (공식 Ghostty 패턴)
- [x] **비활성 세션** — opacity → `isHidden` 전환
- [x] **Timer guard** — background 시 idle/git 타이머 skip
- [x] **Running 상태 표시** — wakeup→tick 시 active session의 lastOutputTime 갱신, 사이드바에 Running/Idle 정확히 반영
