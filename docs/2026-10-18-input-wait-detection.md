# 탭이 사용자 입력을 기다리는지 알기 — 연구 (2026-10-18)

M18 연구 항목. 결론부터: **Claude Code는 이미 우리에게 말하고 있고, 우리가 버리고 있다.**

## 지금 상태: `needsInput`은 에이전트 탭에서 한 번도 켜지지 않는다

`TerminalStateDetector.detect`는 Level 1(자식 프로세스 있음 = `running`)이 먼저다. 그런데 권한을 묻고 있는
Claude Code도, 승인 대기 중인 Codex도 **셸의 자식 프로세스로 살아 있다**. 그래서 Level 2(화면 파싱)까지
가지 못하고 언제나 `running`이다. `>` + `?` 패턴은 에이전트가 끝나고 셸로 돌아온 뒤에야 읽힌다 — 정작
알고 싶은 순간에는 읽히지 않는다. ssh 탭도 같다: 셸의 자식이 `ssh`라 언제나 `running`.

## 후보별 실측

pty 하나를 열어 에이전트를 띄우고 출력 바이트를 그대로 받았다(`TERM_PROGRAM=ghostty`, 40×120).
Claude Code 2.1.302, codex-cli 0.147.0.

| 신호 | 결과 |
|---|---|
| **Claude Code — OSC 777** | 권한 프롬프트가 뜨고 ~6초 뒤 `ESC]777;notify;Claude Code;Claude needs your permission BEL`. 포커스 보고(`ESC[I`)를 보내도 똑같이 왔다 — 포커스로 끄지 않는다. |
| Claude Code — 유휴 | 소스상 같은 경로로 "Claude is waiting for your input"(답을 끝내고 60초 입력 없음, `messageIdleNotifThresholdMs`). 실측은 안 했다. |
| Claude Code — 채널 선택 | `preferredNotifChannel` 기본값 `auto`가 `TERM_PROGRAM`을 본다: `ghostty` → OSC 777, `iTerm.app` → OSC 9, 그 외 → **아무것도 안 보냄**. libghostty가 우리 셸에 `TERM_PROGRAM=ghostty`를 넣는다(`Exec.zig:743`). |
| **Codex** | 승인 프롬프트("Would you like to run the following command?")에서 **아무것도 안 보냈다** — 기본값, `-c tui.notifications=true`, 포커스 아웃(`ESC[O`) 보고 모두. OSC 9/777/BEL 0개. |
| BEL 단독 | 둘 다 0개. Claude Code는 `preferredNotifChannel: terminal_bell`일 때만 보낸다. |
| tty read 블록(`proc_pidinfo`) | 기각. node/bun TUI는 언제나 `kevent`에서 기다리지 tty `read`에서 막히지 않는다 — 일할 때와 기다릴 때가 커널에서 똑같이 보인다. |

## Ghostty 쪽 경로 — 이미 다 있다

`OSC 9` / `OSC 777;notify` → `termio/stream_handler.zig`의 `show_desktop_notification` → `Surface.showDesktopNotification`
→ 앱에 `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`(`title`, `body`, 대상 surface). 막는 것 둘:
- `desktop-notifications` 설정(기본 true) — 우리는 안 건드린다.
- **앱 전체** 1초에 1개, 같은 내용은 5초에 1개(`Surface.zig:6165`). 탭 여러 개가 동시에 같은 문장("Claude needs your permission")을 내면 **뒤의 것이 버려진다** — 같은 문장이 탭마다 오므로 실제로 걸린다. 상태 판정의 근거로 쓰려면 이게 한계다.

우리 `action_cb`(`GhosttyRuntime.swift:90`)는 `GHOSTTY_ACTION_PWD`만 받고 나머지는 `false`로 버린다. `RING_BELL`도 같다.

## 원격(ssh)

OSC 777은 ssh pty를 그대로 건너온다. 막히는 건 **채널 선택**이다: ssh는 `TERM_PROGRAM`을 넘기지 않으므로(기본 `SendEnv`는 `LANG`/`LC_*`) 원격 Claude Code는 `auto` → 아무것도 안 보냄. 이미 원격 접속 스크립트에 preamble을 끼우고 있으니(`RemoteCwdReporter`, terminfo 설치) 거기서 `export TERM_PROGRAM=ghostty`를 하면 원격도 같은 신호를 낸다 — 단, 그 변수를 보고 행동을 바꾸는 다른 원격 프로그램(nvim 등)이 우리를 Ghostty로 보게 된다. 실제로 Ghostty라 맞는 말이다.

## 권고

1. **`GHOSTTY_ACTION_DESKTOP_NOTIFICATION`을 받아 그 surface의 탭을 `needsInput`으로** 만든다. 해제는 그 탭에 사용자가
   키를 칠 때(또는 화면이 셸 프롬프트로 돌아왔을 때). Level 1이 `running`이라 해도 이 신호가 이긴다.
   - 1초/5초 제한은 Ghostty 앱 전역이라 놓칠 수 있다. 놓친 탭은 지금처럼 `running`으로 남을 뿐 — 최악이 지금이다.
   - macOS 알림은 이미 `sendStateNotification`이 낸다. 이 신호로 바꿔 타면 "idle"이 아니라 Claude가 쓴 문장을 그대로 보여줄 수 있다.
2. **Codex는 화면 파싱으로**: 자식 프로세스가 있어도 화면 마지막 부분에 승인 프롬프트(`Would you like to run`, `Press enter to confirm`)가 보이면 `needsInput`. 문구에 묶이는 취약한 판정이라 Codex 전용으로 좁힌다. Codex의 `notify` 설정(외부 프로그램 호출)은 사용자 설정을 건드려야 해서 뺐다.
3. **원격은 1이 끝난 뒤** preamble에 `TERM_PROGRAM=ghostty` 한 줄.
4. 기각: `proc_pidinfo` tty-read, BEL 단독(아무도 기본으로 안 보낸다).

## 재현

```bash
# scratchpad/ptycap.py: pty.fork → TERM_PROGRAM=ghostty → 출력 바이트를 파일로
uv run --no-project python ptycap.py out.bin 50 \
  claude --settings '{"permissions":{"ask":["Bash"]}}' "Use the Bash tool to run exactly: echo probe"
python3 -c "import re;print(re.findall(rb'\x1b\](?:9|777)[^\x07]*\x07', open('out.bin','rb').read()))"
```
`ask` 규칙이 없으면 사용자 설정이 명령을 자동 허용해 프롬프트가 안 뜬다(첫 시도가 그랬다).
