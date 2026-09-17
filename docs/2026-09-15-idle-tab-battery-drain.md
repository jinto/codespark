# 배터리 진단 — "CodeSpark가 에너지를 많이 사용 중"

작성일 2026-09-15. 대상: 로컬 맥(MacBookAir10,1)에서 10일 17시간 떠 있던 CodeSpark 1.2.4 (59), pid 4403.
증상: macOS 배터리 메뉴의 **Using Significant Energy** 목록에 CodeSpark가 계속 올라온다.

## 한 줄 결론

**탭 25개 중 화면에 보이는 1개를 뺀 24개가 vsync마다 계속 렌더링하고 있다.**
libghostty는 새 표면을 `focused = true`로 켜고, `ghostty_surface_set_focus(surface, false)`를
받아야만 DisplayLink를 멈춘다. 그 호출이 안 가는 탭은 전부 포커스된 줄 알고 계속 그린다.
앱 CPU의 **80% 가까이**가 이 렌더 경로(Metal·renderer·CVDisplayLink)이고, 대부분이
아무도 보지 않는 화면이다.

**빌드마다 새는 범위가 다르다** — 아래 "원인" 참고:
- **1.2.4 (측정한 빌드)**: `set_focus`를 **아예 부르지 않는다**. 활성 탭까지 모든 탭이 영구히 focused.
- **1.3.0**: 20150a1이 `set_focus`를 붙였지만 Swift 쪽 초기값이 `false`라, **한 번도 포커스를
  받은 적 없는 탭**(복원된 탭, 안 들여다본 탭)에는 여전히 `false`가 안 간다.

## 측정값

가동 10일 17시간, 누적 CPU **2166분** — 평균 14%, 한 코어를 상시 물고 있는 셈.

`sudo powermetrics --samplers tasks --show-process-energy`:

```
CodeSpark  4403  213.71 ms/s   (= 코어 21% 상시)
```

`sudo spindump 4403 5` — 5초 창에서 CodeSpark CPU 합계 1.363s (코어 27%):

| 비중 | 스레드 | 개수 |
|---|---|---|
| 39.8% | `com.Metal.CommandQueueDispatch` | 19 |
| 30.5% | `renderer` | 25 (**25개 전부 활동중**) |
| 11.3% | `CVDisplayLink` | 25 (**25개 전부 활동중**) |
| 11.2% | `com.apple.main-thread` | 1 |
| 4.0% | Swift Task (git/ssh 폴링) | - |

위 세 줄(Metal·renderer·CVDisplayLink) 합이 81.6%인데 **활성 탭 몫도 들어 있다**
(활성 탭 renderer가 나머지 탭의 약 3배). 안 보이는 탭만 따지면 70%대 후반이다.

렌더러 스레드별 CPU 분포 (5초간, 초):

```
0.056  0.027  0.023  0.020  0.019  0.019  0.018  0.018  0.017  0.016  0.015  0.015 ...
 ^활성 탭        ^^^^^^^^^^ 나머지 24개가 고르게 타고 있다
```

프로세스 스레드 구성 195개 = `renderer` 24 + `io` 24 + `io-reader` 22 +
`CVDisplayLink` 24 + `cf_release` 24 + 나머지. 탭 하나당 5개 스레드.

숫자가 서로 안 맞는다 — spindump 표는 renderer/CVDisplayLink가 **25**, 스레드 구성은 **24**,
`io-reader`는 **22**. `io-reader`가 2~3개 적은 것은 **셸이 이미 끝난 탭**일 수 있다(가설):
1.2.4에는 `close_surface_cb`의 `userdata` 버그가 있어 끝난 탭이 "Press any key"에 영영
남았고, 그 탭들도 계속 그렸을 것이다. 1.3.0에서는 이 몫이 따로 사라진다.

### 무죄 판명된 용의자

처음에는 폴링 타이머를 의심했다. `sample(1)`에 `__posix_spawn`이 잡혔고,
`AppModel+Monitor.swift:10`의 10초 타이머가 탭마다 `detectState` → `extractSnapshot()`을
돌리고 `refreshGitBranches/Worktrees`가 원격 프로젝트마다 `/usr/bin/ssh`를 띄우기 때문이다.
60초 표본에서 git/ssh 자식이 실제로 계속 뜨고 졌고, ssh는 벽시계 시간의 8%를 살아 있었다.

**그러나 spindump에서 그쪽 몫은 전부 합쳐 4%뿐이다.** `sample`은 CPU 가중이 아니라서
`kevent64`/`cvwait`/`poll`에 주차된 스레드 195개에 묻혀 답을 못 준다. 이 질문에는
`spindump`나 `powermetrics`를 써야 한다. 게다가 10초·30초 타이머는 이미
`NSApp.isActive`로 막혀 있어, 앱이 배경일 때(= 배터리 메뉴를 여는 상황)는 0에 가깝다.

## 원인

### 1.2.4 — 아무도 알려주지 않았다

```
v1.2.4: GhosttyTerminalSurfaceView.swift 안 ghostty_surface_set_focus 호출 0개
v1.3.0: 1개 (20150a1 "the focus that hid them")
```

측정한 빌드는 libghostty에 포커스를 **한 번도** 알리지 않았다. 표면은 `focused = true`로
태어나 앱이 떠 있는 내내 그대로다 — 활성 탭이든, 방문했다 떠난 탭이든, 끝난 탭이든.
spindump의 "25개 전부 활동중"은 이 상태 그대로다. **따라서 이 측정은 아래 1.3.0의
초기값 불일치를 증명하지 않는다** — 그 메커니즘이 없어도 같은 숫자가 나왔을 것이다.

### 1.3.0 — 초기값 불일치 (2026-09-17 실측으로 확인 — 아래 "1.3.0 실측")

```
vendor/ghostty/src/renderer/Thread.zig:109    focused: bool = true    ← 표면은 focused로 태어난다
vendor/ghostty/src/renderer/generic.zig:707   .focused = true         ← 그래서 DisplayLink가 돈다
apps/macos/CodeSpark/Terminal/GhosttyTerminalSurfaceView.swift:16
                                              private var surfaceFocused = false   ← Swift는 반대로 가정
apps/macos/CodeSpark/Terminal/GhosttyTerminalSurfaceView.swift:204
                                              guard surfaceFocused != focused else { return }
```

`generic.zig:1038`의 `setFocus`는 포커스를 잃을 때 `display_link.stop()`을 부른다.
그 경로 자체는 멀쩡하다 — **호출이 안 갈 뿐이다.**

1. 배경 탭의 뷰는 first responder가 된 적이 없다 → `resignFirstResponder`가 안 울린다.
2. 어쩌다 `surfaceFocusDidChange(false)`가 불려도 `false != false`라 가드에서 돌아간다.
3. 따라서 `ghostty_surface_set_focus(surface, false)`가 **한 번도** 나가지 않는다.
4. ghostty는 그 표면을 계속 focused로 알고 DisplayLink를 디스플레이 주사율로 돌린다.

1.3.0에서는 포커스를 받았다가 잃은 탭은 꺼진다 — 탭을 숨기면 AppKit이 first responder를
회수하므로 `resignFirstResponder`가 울린다. **새로 열고 안 건드린 탭과, 세션 복원으로
되살아난 탭이 새는 것들이다.** 1.2.4보다 범위는 좁지만, 복원 탭이 많은 사용자에게는
거의 같은 증상이다.

**1.3.0에서 먼저 잴 것 (수정 전)** — 결과가 갈리는 실험:
1. 재실행 → 복원 직후 `sudo spindump <pid> 5` → 활동중인 `renderer`가 **약 24개**여야 한다.
2. 모든 탭을 한 번씩 클릭해 방문 → 다시 spindump → **1개**여야 한다.

2에서도 24개면 원인이 따로 있다.

## 고치기

### 1. 초기값을 libghostty와 맞춘다

`GhosttyTerminalSurfaceView.swift`:

```swift
/// What libghostty was last told about our focus, so we only tell it changes.
/// libghostty creates a surface focused (renderer/Thread.zig:109) — so do we.
private var surfaceFocused = true
```

그리고 init에서 표면을 만든 직후 `surfaceFocusDidChange(false)`를 한 번 부른다.
포커스를 받을 탭은 곧 `becomeFirstResponder`에서 `true`를 다시 받는다.

libghostty 쪽 부작용이 없음을 확인했다 (`Surface.zig:3280` `focusCallback`):
- 같은 상태면 즉시 돌아간다 — 두 번 불려도 무해.
- 눌린 키가 없으니(`pressed_key == null`) key release 합성이 없다.
- `queueIo(.focused = false)`는 focus reporting(DECSET 1004)이 켜졌을 때만 pty에 `\e[O`를
  쓴다 — 방금 만든 표면은 꺼져 있다.
- `surface == nil`이면 `:204` 가드에서 돌아가고 미러만 `true`로 남는다 — 무해.

### 2. 창이 key를 잃으면 다시 계산한다

아래 "남은 항목"의 occlusion으로는 **안 잡히는** 경우가 있고, 스크린샷이 정확히 그 상황이다:
다른 앱(Firefox)을 쓰는 동안 CodeSpark 창은 뒤에 **보이는** 채로 있다. 창이 key를 잃어도
`resignFirstResponder`는 안 울리므로 **활성 탭 하나가 배경에서 vsync로 계속 그린다.**

업스트림은 `windowDidResignKey`/`windowDidBecomeKey` → `syncFocusToSurfaceTree()`에서
포커스를 `isKeyWindow && isFirstResponder`로 다시 계산하고(`BaseTerminalController.swift:299`),
앱 활성 상태가 바뀌면 `ghostty_app_set_focus`를 부른다(`Ghostty.App.swift:308/314`).
우리는 둘 다 안 한다.

### 검증

libghostty C API에는 포커스 **getter가 없다**(`ghostty.h`는 setter뿐) — 유닛 테스트로는
libghostty가 들은 값을 볼 수 없다. 오라클은 spindump다:

- 위 1.3.0 실험을 수정 후 다시 → 복원 직후에도 활동중인 `renderer`가 **1개**.
- 다른 앱으로 전환한 채(창은 보이게) spindump → `CVDisplayLink` 활동 **0개**(2번 수정 후).
  `renderer`는 출력이 오는 탭만 깨어난다 — 모든 탭이 idle 프롬프트면 거의 0이어야 한다.

"탭을 하나씩 닫아 CPU가 선형으로 떨어지는지" 보는 A/B는 1.3.0에서는 판별력이 약하다 —
닫으러 가는 길에 탭을 방문하게 되고, 방문한 탭은 이미 꺼진다.

## 남은 항목 — occlusion

`ghostty_surface_set_occlusion`을 앱 어디에서도 부르지 않는다.
위 두 수정을 해도 이건 남는다: 창 전체를 최소화하거나 다른 Space로 보냈을 때
렌더 스레드가 "보인다"고 믿어 QoS를 낮추지 않고, 출력이 올 때마다 그린다.
업스트림은 `BaseTerminalController.swift:1255`에서 `window.occlusionState`를 보고 처리한다.
DisplayLink는 2번 수정으로 이미 멈추므로, 이건 3순위.

## 1.3.0 실측 (2026-09-17)

### 사용자 기계 — spindump, CodeSpark 프로세스만

| | 실행 후 | 표면(io) | renderer prio 46 | renderer prio 37 | CVDisplayLink | CPU/5s |
|---|---|---|---|---|---|---|
| 1. 복원 직후 | 60s | 1 | 1 | 0 | 1 | 0.054s |
| 2. 프로젝트들 방문 후 | 146s | 14 | **13** | 1 | **13** | 0.529s |

- **renderer 스레드 우선순위가 libghostty의 포커스 믿음이다**(`Thread.zig` `setQosClass`):
  46 = focused+visible, 37 = visible·unfocused. C API에 getter가 없어도 이걸로 판별된다.
- `false`를 받은 1개만 display link가 없고 10초째 잠들어 있었다 — 끄는 경로는 멀쩡, 호출이 안 간 것.
- **예측이 틀린 곳**: 복원은 표면을 만들지 않는다. 표면은 **프로젝트를 선택할 때**
  `attachLiveSessions`가 그 프로젝트의 탭 전부에 한꺼번에 만들고, 포커스는 기억된 탭 하나만 받는다.
  방문은 프로젝트 단위(사이드바·Cmd+숫자)였다 — 초기값 불일치 그대로.

### 이 기계 — `sample`로 재현 (sudo 불필요)

`sample <pid> 2`의 `Thread_N: CVDisplayLink` 개수. 개발 스토어의 `codespark` 프로젝트(로컬 탭 2개)가
시작 시 선택되어 표면 2개가 생긴다.

| | 고치기 전 | 고친 후 |
|---|---|---|
| 앱이 앞 | 2 | **1** |
| Finder가 앞 | 2 | **0** |
| 다시 앞 | — | **1** |

수정은 "고치기" 1·2 그대로. 스크립트는 세션 scratchpad의 `measure-focus.sh`였다(앱 실행 →
25초 → `sample` 스레드 이름 집계).
