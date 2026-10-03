<div align="center">

# AI Agent Usage

**Claude Code와 Codex의 남은 사용량을 메뉴 막대에서 한눈에.**

<br>

![macOS](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-native-F05138?style=flat-square&logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-supported-D97757?style=flat-square)
![Codex](https://img.shields.io/badge/Codex-supported-10A37F?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

<br>

```
✳ 97%  ⚙ 28%
```

<sub>메뉴를 열면 에이전트별 5시간·주간 사용량, 초기화 시각, 요금제를 바로 확인할 수 있습니다.</sub>

</div>

<br>

## 주요 기능

| 기능 | 설명 |
|---|---|
| **사용량 한눈에 보기** | Claude Code와 Codex의 남은 사용량을 메뉴 막대 아이콘 하나로 보여줍니다. 둘 다, 하나만, 혹은 아무것도 추적하지 않도록 고를 수 있습니다. |
| **자동 시작** <sup>선택</sup> | 5시간 창이 초기화되는 순간, 저렴한 모델로 아주 작은 요청을 하나 보냅니다. 기본값은 Claude `haiku`, Codex `gpt-6-luna`입니다. 첫 실제 요청을 기다리지 않고 다음 창의 시간이 곧바로 흐르기 시작합니다. |
| **초기화 시각에 깨우기** <sup>선택</sup> | `pmset`으로 Mac을 깨워 자동 시작 요청을 보낸 뒤, 그동안 아무도 건드리지 않았다면 다시 잠자기로 돌려놓습니다. |
| **세부 설정** | 갱신 주기를 조절할 수 있고, 로그인할 때 자동으로 실행되게 할 수 있습니다. |
| **한국어 UI** | 메뉴는 한국어로 표시됩니다. |

<br>

## 요구 사항

- **macOS 13** 이상
- **Xcode Command Line Tools** — `xcode-select --install`로 설치
- 아래 중 하나 이상
  - Claude 구독 계정으로 로그인된 **Claude Code CLI**
  - ChatGPT 계정으로 로그인된 **Codex CLI** 또는 **ChatGPT 데스크톱 앱**

<br>

## 설치

### 방법 1 · 코딩 에이전트에게 맡기기 <sup>추천</sup>

이 폴더를 Claude Code나 Codex로 열고 이렇게 말하면 됩니다.

> **agent-install.md 대로 설치해줘**

에이전트가 로그인 상태를 확인하고, 앱을 빌드하고, 원하는 설정을 적용합니다. 비밀번호가 필요한 선택 단계는 직접 실행할 수 있도록 안내해 줍니다.

### 방법 2 · 직접 설치하기

```sh
./build.sh
cp -R "dist/AI Agent Usage.app" /Applications/
open "/Applications/AI Agent Usage.app"
```

> [!NOTE]
> 빌드 결과물은 내 Mac 전용으로 ad-hoc 서명됩니다. 공증(notarization)을 거치지 않았기 때문에, 다른 Mac으로 복사하면 Gatekeeper가 실행을 막습니다. 앱을 쓸 Mac에서 직접 빌드하세요.

<br>

## 동작 방식

| | 사용량 조회 | 자동 시작 요청 |
|---|---|---|
| **Claude Code** | Claude Code가 로그인 키체인(`Claude Code-credentials`)에 저장해 둔 OAuth 토큰으로 `GET https://api.anthropic.com/api/oauth/usage` 호출 | `claude -p … --model haiku` <br><sub>도구, 설정, MCP 서버, 세션 저장을 모두 끈 상태로 실행</sub> |
| **Codex** | `codex app-server` JSON-RPC의 `account/rateLimits/read` | `codex exec --ephemeral -m gpt-6-luna -c model_reasoning_effort="low"` |

> [!IMPORTANT]
> 토큰은 그 토큰을 발급한 제공사에 보내는 요청에만 쓰입니다. 앱은 토큰을 따로 저장하거나, 다른 곳으로 보내거나, 로그에 남기지 않습니다.

<details>
<summary><b>디버깅용 명령줄 옵션</b></summary>

<br>

```sh
AIAgentUsage --self-test          # 오프라인 자체 점검
AIAgentUsage --fetch-once         # 남은 사용량 출력
AIAgentUsage --kickoff claude     # 자동 시작 요청 1회 전송 (사용량 소모)
```

</details>

<br>

## 알아두실 점

- Claude 사용량은 공개 API가 아닌 엔드포인트에서 가져옵니다. 그래서 언젠가 바뀌거나 막힐 수 있습니다. 너무 자주 조회해서 429가 뜨면, 앱이 알아서 잠시 쉬었다가 다시 조회합니다.
- 자동 시작 요청도 사용량에 조금 잡힙니다. 주간 창이 아직 시작 전이라면 주간 창도 같이 시작됩니다.
- 잠든 Mac을 깨우려면 sudoers 설정이 하나 필요합니다. 방법은 [agent-install.md](agent-install.md) 6단계에 있습니다. 덮개를 닫은 상태에서는 아직 테스트해 보지 않았습니다.
- 다른 앱이 Claude Code 토큰을 읽어 쓰거나 자동으로 요청을 보내는 것을 제공사 약관이 허용하는지는 각자 한 번 확인해 주세요.

<br>

## 상표

Claude는 Anthropic의 상표입니다. OpenAI, ChatGPT, Codex는 OpenAI의 상표입니다. 이 프로젝트는 두 회사와 제휴하거나 보증을 받지 않았습니다. 로고는 각 제공사의 사용량을 구분하는 용도로만 쓰입니다.

## 라이선스

[MIT](LICENSE)
