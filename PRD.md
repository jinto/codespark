# Code Spark — Product Requirements Document

## Vision

개발자를 위한 통합 작업 환경.
터미널 멀티플렉서 + 프로젝트 관리 + AI 에이전트 오케스트레이션을 하나의 네이티브 macOS 앱에서.

> cmux의 터미널 관리 + Linear의 프로젝트 관리 + 팀/에이전트 협업을 통합한다.

## Core Principles

1. **Terminal-first** — 터미널이 1등 시민. 모든 작업이 터미널에서 시작된다.
2. **Stateful** — 세션 상태가 자동으로 보존되고 복원된다. 앱을 닫아도, 크래시가 나도.
3. **Keyboard-driven** — 마우스 없이 모든 작업이 가능하다. 파워 유저를 위한 도구.
4. **Native** — macOS 네이티브 앱. 웹 래퍼가 아닌, 진짜 네이티브.

## User Personas

### P1: 풀스택 개발자
- 3개 이상의 프로젝트를 동시에 작업
- 프로젝트별 터미널 세션 관리가 필요
- Git 브랜치별 작업 컨텍스트를 유지하고 싶음

### P2: DevOps / SRE
- 다수의 SSH 세션을 동시 관리
- 서버 상태 모니터링 + 긴급 대응
- 세션 복원이 생명선

### P3: 팀 리드
- AI 에이전트(Claude Code, Codex 등)의 작업을 관리
- 팀 멤버의 작업 상황을 한눈에 파악
- 프로젝트 이슈를 터미널 작업과 연결

## Feature Layers

### Layer 1: Terminal Multiplexer (M1 — 현재)

Workspace 기반 터미널 멀티플렉서. tmux를 대체하되, 상태가 영속적으로 보존된다.

| 기능 | 상태 |
|------|------|
| Workspace 생성/선택 | Done |
| Live session 탭 (Cmd+T/W) | Done |
| 탭 전환 (Cmd+Shift+]/[) | Done |
| Ghostty 터미널 렌더링 | Done |
| 키보드 입력 + Cmd+V 붙여넣기 | Done |
| Session 종료 시 스냅샷 캡처 | Done |
| Closed session 복원 (recovery actions) | Done |
| Cmd+Q 시 세션 상태 저장 | Done |
| 다크 테마 + 커스텀 타이틀바 | Done |
| Window dragging | Done |

### Layer 2: Enhanced Navigation (M2 — 다음)

cmux 수준의 사이드바. Workspace 아래에 세션 목록과 실시간 상태를 표시한다.

| 기능 | 상태 |
|------|------|
| 사이드바에 live session 목록 표시 | Todo |
| 세션별 상태 뱃지 (Running/Idle/Needs input) | Todo |
| Workspace 확장/축소 (disclosure) | Todo |
| 세션 이름 변경 (더블클릭 or F2) | Todo |
| 세션/workspace 검색 (Cmd+K) | Todo |
| Workspace 생성/삭제/이름 변경 UI | Todo |
| Git 브랜치 + 경로 표시 | Todo |
| Window state restoration | Todo |

### Layer 3: Project Management (M3)

Workspace 노트를 태스크 보드로 발전시킨다. Linear처럼 이슈를 관리하되, 터미널 세션과 연결한다.

| 기능 | 상태 |
|------|------|
| 태스크 보드 (Todo/Doing/Done) | Todo |
| 이슈 생성 + 상태 관리 | Todo |
| 이슈 ↔ 세션 연결 | Todo |
| Git 브랜치 ↔ 이슈 연동 | Todo |
| 마크다운 노트 렌더링 | Todo |
| 이슈 검색 + 필터 | Todo |

### Layer 4: Team & Agents (M4)

AI 에이전트와 팀 멤버를 통합 관리한다. roro-code-hq처럼 에이전트 세션을 시각화하고, 팀 작업을 조율한다.

| 기능 | 상태 |
|------|------|
| AI 에이전트 세션 관리 (Claude Code, Codex 등) | Todo |
| 팀 멤버 목록 + 온라인 상태 | Todo |
| 스레드/대화 관리 | Todo |
| 에이전트 생성 (+ New Agent) | Todo |
| 에이전트 출력 모니터링 | Todo |
| Canvas/Board 뷰 | Todo |

## Tech Stack

| Layer | Technology | Role |
|-------|-----------|------|
| UI | Swift + SwiftUI + AppKit | macOS 네이티브 UI |
| Terminal | Ghostty (GhosttyKit) | 터미널 렌더링 엔진 |
| Persistence | Zig + SQLite | workspace-core 저장소 |
| Build | XcodeGen + Zig Build | 빌드 시스템 |

## Architecture

```
Code Spark
├── apps/macos/          — SwiftUI macOS 앱
│   ├── App/             — 앱 진입점, WindowGroup, Commands
│   ├── Models/          — AppModel (ObservableObject)
│   ├── Views/           — Sidebar, MainContent, TabBar, Inspector
│   ├── Terminal/        — Ghostty 통합 (Runtime, Surface, Host)
│   ├── Bridge/          — Zig C API ↔ Swift 브리지
│   └── Theme/           — AppTheme 상수
├── libs/workspace-core/ — Zig 저장소 라이브러리
│   ├── src/             — store, models, restore, c_api
│   ├── include/         — C 헤더
│   └── tests/           — Zig 테스트
└── vendor/ghostty/      — Ghostty 터미널 엔진
```

## Design References

- `rock-contact.jpg` — roro-code-hq 앱 UI 컨택트 시트
- `key-002.jpg` — roro-code-hq 상세 화면 (팀 + 에이전트 + 스레드)
- cmux — 터미널 멀티플렉서 사이드바 패턴

## Milestones

| Milestone | 내용 | 상태 |
|-----------|------|------|
| M1 | Terminal Multiplexer MVP | Done |
| M2 | Enhanced Sidebar + Navigation | Next |
| M3 | Project Management | Planned |
| M4 | Team & Agent Integration | Planned |
