# Tasks

## M7: Project UX 개선 (실사용 피드백)

- [x] **새 프로젝트 생성 위치** — 액티브 프로젝트 바로 아래에 삽입 (현재: 목록 끝에 추가)
- [x] **닫기 확인 (Cmd+W)** — 터미널/프로젝트 닫을 때 confirm dialog 표시. Cmd+W가 현재 동작하지 않는 버그 수정 포함
- [x] **닫힌 탭 복원 UX** — closed sessions를 하단에 모아두지 않고, 프로젝트를 다시 열 때 "이전 세션을 다시 열까요?" 프롬프트
- [x] **자동 복원** — SSH 등 복원 가능한 세션은 프롬프트 없이 최대한 자동 복원

## M9: 알림 시스템

- [x] **사이드바 정렬** — Needs input 프로젝트를 상단으로 자동 정렬
- [x] **사이드바 벨 아이콘** — unread count 뱃지
- [x] **macOS 데스크톱 알림** — idle 전환 시 알림 (다른 프로젝트 보고 있을 때)
- [x] **알림 스니펫** — 프로젝트 카드에 마지막 출력 요약

## M10: 터미널 성능 + 너비 + Ctrl 키 수정

- [x] **터미널 너비** — `convertToBacking`으로 physical pixels 전달 + `autoresizingMask` 추가
- [x] **터미널 성능** — GhosttyKit ReleaseFast 빌드 (debug allocator 제거) + wakeup coalescing + run loop yield
- [x] **Ctrl+C/D/Z** — `performKeyEquivalent` override + control char text 재계산 (공식 Ghostty 패턴)
- [x] **비활성 세션** — opacity → `isHidden` 전환
- [x] **Timer guard** — background 시 idle/git 타이머 skip
- [x] **Running 상태 표시** — wakeup→tick 시 active session의 lastOutputTime 갱신, 사이드바에 Running/Idle 정확히 반영

## M10.5: Workspace → Project 리네이밍

- [x] **모델 리네이밍** — ProjectViewData.swift, 모든 Project* 타입
- [x] **AppModel 리네이밍** — projects, selectedProjectID, 모든 메서드명
- [x] **뷰 리네이밍** — SidebarView, MainContentView, CodeSparkApp의 변수명 + UI 텍스트
- [x] **Zig/C 리네이밍** — project_service_*, project_core.h의 모든 타입/함수명, DB 테이블명
- [x] **브릿지 리네이밍** — ProjectCoreClient, project_core.swift, C API 호출 전부 갱신
- [x] **AppStorage 마이그레이션** — 키 변경 + 마이그레이션 코드 (기존 사용자 설정 보존)
- [x] **문서 업데이트** — CLAUDE.md, TASKS.md, PRD.md

## M10.7: 코드 리뷰 기반 리팩토링

### Critical
- [x] **DB 마이그레이션 시스템** — schema_version 테이블 + 버전별 ALTER TABLE 체인 (store.zig)
- [x] **C API line_count 검증** — 범위 체크 추가, 비정상 값 방어 (c_api.zig)
- [x] **ProjectCoreClient unsafe pointer 수정** — baseAddress 강제 언래핑 제거, 포인터 수명 보장

### Major
- [x] **AppModel 분리** — Extension 파일 분리: AppModel+Hook.swift (105줄), AppModel+Monitor.swift (90줄), AppModel.swift (511줄)
- [x] **에러 삼킴 수정** — try? → do/catch + NSLog (AppModel 4곳)
- [x] **세션 복구 코드 통합** — recoverSession(from:) 하나로 통합
- [x] **프로젝트 닫기/삭제 중복 제거** — teardownProject(id:) 공통 함수 추출
- [x] **타임라인 이벤트 에러 처리** — catch {} → std.log.warn (store.zig 6곳)

### Design
- [ ] **Hook 시스템 분리** — HookEventProcessor 추출, AppModel은 결과만 처리
- [ ] **AppStorage 키 상수화** — 하드코딩 문자열 → 상수
- [ ] **비즈니스 로직 Zig 이동** — 세션 상태 머신, hook 이벤트 타입 정의를 Zig로

## M11: 터미널 분할 + 검색

- [ ] **터미널 분할 (수평)** — Cmd+D로 현재 터미널을 좌우 분할
- [ ] **터미널 분할 (수직)** — Cmd+Shift+D로 상하 분할
- [ ] **터미널 내 검색** — Cmd+F로 현재 터미널 출력에서 텍스트 검색

## M12: Git Worktree 격리

- [ ] **프로젝트별 worktree** — 새 프로젝트 생성 시 독립적인 git worktree 자동 생성
- [ ] **브랜치 자동 관리** — worktree 생성 시 새 브랜치 자동 생성, 삭제 시 정리
- [ ] **내장 Diff 뷰어** — 프로젝트 내 코드 변경사항 검토 (git diff 시각화)

## M13: 외부 통합

- [ ] **IDE 열기** — 프로젝트의 cwd를 VS Code, Cursor, Xcode 등에서 원클릭 열기
- [ ] **포트 모니터링** — 프로젝트별 활성 포트 감지 및 표시
- [ ] **앱 내 브라우저** — 활성 포트의 웹 서비스를 인앱 프리뷰

## M14: 프로젝트 자동화

- [ ] **프리셋** — 터미널 설정(셸, cwd, 초기 명령어)을 프리셋으로 저장/재사용
- [ ] **설정/해제 스크립트** — 프로젝트 생성/삭제 시 자동 실행되는 스크립트 (.codespark/setup.sh, teardown.sh)
- [ ] **크로스 프로젝트 검색** — 모든 열린 프로젝트의 터미널 출력을 한번에 검색

## M15: 다중 에이전트 지원

- [ ] **에이전트 타입 감지** — 터미널에서 실행 중인 AI CLI 종류 자동 감지 (Claude Code, Codex, Gemini CLI 등)
- [ ] **에이전트별 상태 표시** — 각 에이전트의 실행 상태를 사이드바에 아이콘으로 구분
- [ ] **에이전트 대시보드** — 모든 에이전트의 상태를 한 화면에서 모니터링
