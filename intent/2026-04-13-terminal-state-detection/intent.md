# Terminal State Detection via Process + Screen Parsing

- Status: done — 9dfbc39 2026-04-13 (Services/TerminalStateDetector.swift, hook 시스템 삭제)

## Goal

Hook 시스템을 완전히 제거하고, **프로세스 감지 + 화면 파싱**으로 범용 터미널 상태를 감지한다.

- 대상: Claude Code뿐 아니라 모든 터미널 프로그램
- 상태: `running`, `idle`, `needInput`
- 기존 hook 인프라 (ClaudeHooksManager, HookSocketServer, codespark-hook CLI) 삭제

## Architecture

```
Level 1: 프로세스 감지 (shell PID → 자식 프로세스 유무)
  → 자식 있음: running
  → 자식 없음: not-running → Level 2로

Level 2: 화면 파싱 (5초 debounce 후, not-running일 때만)
  → 내장 패턴 매칭: idle / needInput
  → default: running
```

### Trigger

- 화면 변화가 5초간 없으면 파싱 시작
- 세션별 `DispatchWorkItem`으로 debounce 관리
- `markOutput()` 호출 시마다 기존 item cancel → 5초 뒤 새 item 스케줄

### Level 1: 프로세스 감지

- 셸 PID의 자식 프로세스 유무로 `running` vs `not-running` 판정
- `proc_listchildpids()` 또는 동등한 macOS API 사용
- 비용: 시스템 콜 한 번, 매우 저렴

### Level 2: 화면 파싱

- `extractSnapshot()` (`ghostty_surface_read_text`) 으로 전체 화면 텍스트 추출
- 마지막 비어있지 않은 줄 + 상위 N줄 분석
- 내장 패턴 (Swift enum/struct):

| 우선순위 | 패턴 | 상태 |
|---------|------|------|
| 1 | 마지막 줄 `>` + 상위 5줄에 `?` 패턴 | `needInput` |
| 2 | 마지막 줄 `>` (질문 없음) | `idle` |
| 3 | 마지막 줄 셸 프롬프트 (`$`, `❯`, `%`) | `idle` |
| — | 매칭 없음 | `running` (default) |

### State Machine

- 규칙 매칭 로직은 순수 함수 (enum 타입)로 추출 — `HookEventProcessor` 패턴 준수
- 세션별 상태 추적 유지 (이전 상태 참조 가능)

## Constraints

- 5초 debounce (화면 변화 없음 threshold)
- 규칙은 Swift 내장 패턴 (enum/struct), 외부 파일 없음
- `extractSnapshot()` + 프로세스 감지는 메인 스레드 차단 최소화
- 비활성 세션도 polling으로 감지 (active session만이 아님)

## Non-Goals

- 외부 JSON 규칙 파일 (향후 확장)
- OSC 133 셸 통합 (별도 이슈)
- Hook과의 공존/점진 전환

## Acceptance Criteria

| AC | 시나리오 | 기대 결과 |
|----|---------|----------|
| AC-1 | 셸 자식 프로세스 존재 | `running` |
| AC-2 | 자식 프로세스 없음 + 마지막 줄 `$`/`❯`/`%` | `idle` |
| AC-3 | 자식 프로세스 없음 + 마지막 줄 `>` + 상위 5줄에 `?` 패턴 | `needInput` |
| AC-4 | 자식 프로세스 없음 + 마지막 줄 `>` + 질문 패턴 없음 | `idle` |
| AC-5 | 어떤 패턴도 매치 안 됨 | `running` (default) |
| AC-6 | 화면 변화 5초 이내 재발생 | 파싱 취소, debounce 리셋 |
| AC-7 | Hook 관련 코드 완전 제거 | codespark-hook, HookSocketServer, ClaudeHooksManager 없음 |

## 제거 대상

| 파일 | 내용 |
|------|------|
| `Services/ClaudeHooksManager.swift` | Hook 설치/제거/상태 관리 |
| `Services/HookSocketServer.swift` | Unix socket 서버 |
| `Services/HookEventProcessor.swift` | Hook 이벤트 순수 로직 |
| `apps/macos/CLI/main.swift` | codespark-hook CLI |
| `AppModel.swift` 내 hook 관련 프로퍼티 | `hookNeedsInputCwds`, `hookSnippets`, `claudeHooksStatus` 등 |
| `AppModel+Hook.swift` | Hook 이벤트 핸들링 → 재작성 (파싱 로직) |
| `CodeSparkApp.swift` 내 hook 초기화 | HookSocketServer 생성, health check |
| `SidebarView.swift` 내 hook 상태 분기 | `claudeHooksStatus != .installed` 분기 |
| `SettingsView.swift` 내 hook 설정 UI | Uninstall 버튼 등 |

## 신규 파일

| 파일 | 내용 |
|------|------|
| `Services/TerminalStateDetector.swift` | 프로세스 감지 + 화면 파싱 + 상태 판정 (순수 함수) |

## 수정 대상

| 파일 | 변경 |
|------|------|
| `AppModel+Monitor.swift` | debounce 타이머 추가, `TerminalStateDetector` 호출 |
| `AppModel.swift` | hook 프로퍼티 제거, screen parsing 상태 프로퍼티 추가 |
| `CodeSparkApp.swift` | hook 초기화 제거, 상태 감지 초기화 추가 |

## 검증 결과

| 검증자 | 채택 | 거부 (사용자 결정) |
|--------|------|-------------------|
| Architect | 세션별 debounce, per-session state, 순수 함수 추출 | Hook 보완 구조 |
| Critic | AC 추가, 순수 함수 추출, debounce 구체화 | — |
| CEO | 프로세스 감지 레이어, 내장 패턴 | Hook 보완, 외부 JSON |
