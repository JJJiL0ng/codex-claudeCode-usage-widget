# 에이전트 설치 가이드

> 코딩 에이전트(Claude Code, Codex 등)가 사용자의 Mac에 **AI Agent Usage**를 설치할 때 따르는 안내서입니다.
> 단계를 순서대로 진행하고, "사용자에게 묻기"라고 적힌 곳에서는 짐작하지 말고 반드시 물어보세요.

AI Agent Usage에는 별도의 로그인이 없습니다. 사용자가 이미 Claude Code CLI와 Codex CLI에 로그인해 둔 세션을 그대로 활용합니다. 따라서 설치 과정은 크게 세 가지입니다.

1. 로그인이 되어 있는지 확인하기
2. 앱 빌드하기
3. 설정 고르기

### 한눈에 보는 단계

| 단계 | 내용 | 필수 여부 |
|:-:|---|:-:|
| 1 | 요구 사항 확인 | 필수 |
| 2 | 추적할 에이전트 고르고 로그인 확인 | 필수 |
| 3 | 빌드와 설치 | 필수 |
| 4 | 사용자 설정 적용 | 필수 |
| 5 | 로그인 시 실행 | 선택 |
| 6 | 초기화 시각에 Mac 깨우기 | 선택 |
| 7 | 결과 보고 | 필수 |

---

## 반드시 지킬 규칙

> [!CAUTION]
> - **OAuth 토큰을 출력하거나 기록하거나 복사하지 마세요.** 자격 증명이 *있는지*만 확인하고, 값은 절대 출력하지 않습니다. `security ... -w` 결과를 터미널에 띄우거나 `cat ~/.codex/auth.json`을 실행하면 안 됩니다.
> - **`sudo` 실행이나 `/etc/sudoers.d` 수정은 직접 하지 마세요.** 6단계는 선택 사항입니다. 사용자가 원하면 명령어를 보여주고 사용자가 직접 실행하게 합니다.
> - **대신 로그인하지 마세요.** CLI가 로그인되어 있지 않다면, 사용자에게 본인 터미널에서 로그인해 달라고 요청합니다.

---

## 1. 요구 사항 확인

```sh
sw_vers -productVersion        # 13.0 이상이어야 함
xcode-select -p                # swiftc를 위한 Command Line Tools 필요
```

Command Line Tools가 없다면 사용자에게 `xcode-select --install`을 실행해 달라고 요청하세요.

---

## 2. 추적할 에이전트 고르기

> [!IMPORTANT]
> **사용자에게 묻기:** 어떤 에이전트를 추적할까요? **Claude Code**, **Codex**, 또는 **둘 다**.
> 고른 에이전트만 확인합니다.

### Claude Code

```sh
command -v claude
security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && echo "claude: logged in" || echo "claude: not logged in"
```

로그인되어 있지 않으면 사용자에게 `claude`를 실행한 뒤 `/login`으로 Claude 구독 계정에 로그인해 달라고 요청하세요.

### Codex

최신 모델은 최신 CLI가 필요하기 때문에, 앱은 ChatGPT 데스크톱 앱에 포함된 Codex 실행 파일을 우선 사용합니다.

```sh
CODEX=/Applications/ChatGPT.app/Contents/Resources/codex
[ -x "$CODEX" ] || CODEX=$(command -v codex)
"$CODEX" --version
"$CODEX" login status
```

로그인되어 있지 않으면 사용자에게 `codex login`을 실행해 달라고 요청하세요.

---

## 3. 빌드와 설치

```sh
./build.sh                                  # dist/AI Agent Usage.app을 빌드하고 --self-test 실행
"dist/AI Agent Usage.app/Contents/MacOS/AIAgentUsage" --fetch-once
```

`--fetch-once`는 에이전트별 남은 사용량을 퍼센트로 출력합니다. 사용자가 고르지 않은 에이전트에서 실패가 나는 건 정상입니다.

설치하고 실행합니다.

```sh
pkill -x AIAgentUsage 2>/dev/null
rm -rf "/Applications/AI Agent Usage.app"
cp -R "dist/AI Agent Usage.app" /Applications/
open "/Applications/AI Agent Usage.app"
```

---

## 4. 사용자 설정 적용

설정은 `dev.jihong.ai-agent-usage` defaults 도메인에 저장됩니다. **값을 쓰기 전에 앱을 종료하고, 다 쓴 뒤 다시 실행하세요.**

| 키 | 타입 | 기본값 | 의미 |
|---|---|---|---|
| `enabled.claude` | bool | `true` | Claude Code 추적 |
| `enabled.codex` | bool | `true` | Codex 추적 |
| `autoKickoff` | bool | `true` | 5시간 창이 초기화되면 곧바로 작은 요청을 보내 다음 창을 즉시 시작 |
| `claudeKickoffModel` | string | `haiku` | Claude 자동 시작 요청에 쓸 모델 |
| `codexKickoffModel` | string | `gpt-6-luna` | Codex 자동 시작 요청에 쓸 모델 |
| `refreshSeconds` | int | `900` | 갱신 주기(초). Claude 사용량 엔드포인트는 자주 조회하면 HTTP 429를 반환하므로 **900 이상**을 유지하세요. |

예시로, Claude만 쓰는 사용자라면 이렇게 설정합니다.

```sh
pkill -x AIAgentUsage
defaults write dev.jihong.ai-agent-usage enabled.codex -bool false
open "/Applications/AI Agent Usage.app"
```

> [!TIP]
> 사용자는 나중에 메뉴 막대의 **에이전트**, **초기화 직후 자동 시작** 메뉴에서 언제든 바꿀 수 있습니다.

### Codex 자동 시작 모델 고르기

ChatGPT 계정은 일부 모델만 허용합니다. 먼저 이 계정에서 쓸 수 있는 모델 목록을 확인하세요.

```sh
(printf '%s\n' \
  '{"method":"initialize","id":0,"params":{"clientInfo":{"name":"setup","title":"setup","version":"1"}}}' \
  '{"method":"initialized","params":{}}' \
  '{"method":"model/list","id":1,"params":{}}'; sleep 6) | "$CODEX" app-server 2>/dev/null
```

숨김 처리되지 않은 모델 중 가장 저렴한 것을 고르세요. 보통 "빠름" 또는 "저렴함"으로 설명된 모델입니다. 고른 모델을 `codexKickoffModel`에 넣고 테스트합니다.

```sh
"/Applications/AI Agent Usage.app/Contents/MacOS/AIAgentUsage" --kickoff codex
"/Applications/AI Agent Usage.app/Contents/MacOS/AIAgentUsage" --kickoff claude
```

> [!WARNING]
> 테스트할 때마다 사용자의 사용량이 조금씩 소모됩니다. **실행하기 전에 사용자에게 먼저 알리세요.**

---

## 5. 선택: 로그인 시 실행

사용자에게 메뉴에서 **로그인 시 실행**을 켜 달라고 요청하세요. 앱은 `SMAppService`로 스스로를 등록하는데, 이 승인은 에이전트가 대신할 수 없습니다.

---

## 6. 선택: 초기화 시각에 Mac 깨우기

Mac이 잠자기 중일 때도 자동 시작 요청을 보내려면, 앱이 `pmset schedule wake`로 깨우기를 예약해야 합니다. 이 명령은 root 권한이 필요합니다. 이 단계를 건너뛰면 자동 시작은 Mac이 깨어 있을 때만 동작합니다.

사용자에게 이 내용을 설명한 뒤 아래 명령어를 **보여주기만 하세요. 직접 실행하면 안 됩니다.**

```sh
echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *" | sudo tee /etc/sudoers.d/ai-agent-usage
sudo chmod 440 /etc/sudoers.d/ai-agent-usage && sudo visudo -c
```

이 규칙은 깨우기 예약을 *추가*하는 것만 허용합니다. 사용자가 실행을 마치면 메뉴에서 **지금 새로고침**을 누르게 한 뒤 확인합니다.

```sh
sudo -n -l /usr/bin/pmset schedule wake "01/01/30 00:00:00" AIAgentUsage   # 허용되었다면 명령어가 출력됨
pmset -g sched | grep AIAgentUsage                                         # 초기화 시각을 알게 되면 표시됨
```

<details>
<summary>되돌리는 방법</summary>

```sh
sudo rm /etc/sudoers.d/ai-agent-usage
```

</details>

---

## 7. 결과 보고

설치를 마치면 사용자에게 다음 내용을 알려주세요.

- [ ] 활성화된 에이전트와 `--fetch-once`로 확인한 현재 남은 사용량
- [ ] 자동 시작이 켜져 있는지, 어떤 모델을 쓰는지
- [ ] 깨우기 예약이 설정되었는지
- [ ] 실패한 단계가 있다면 정확한 오류 메시지와 함께
