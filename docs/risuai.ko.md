# RisuAI에서 Aethrion을 모델로 쓰기

RisuAI(또는 SillyTavern)의 "Custom API"를 Aethrion으로 돌리면, 플레이어가 쓴 문장을 Aethrion의 규칙이 먼저 읽고 적용한 뒤 모델이 그 결과에 맞춰 이야기합니다. 호감·신뢰, HP, 주사위, 엔딩 같은 숫자는 모델이 아니라 규칙이 정합니다.

[English](risuai.md)

## 왜 필요한가

RisuAI 커뮤니티의 시뮬레이션·RPG 카드는 대개 상태를 모델에게 맡깁니다. 프롬프트에 "응답 끝에 상태창을 출력하라"고 적어 두거나, 채팅 변수와 트리거 스크립트로 숫자를 관리합니다. 그러다 보니 다음 문제가 반복됩니다.

- **리롤하면 두 번 적용됩니다.** 같은 공격을 다시 생성하면 피해가 한 번 더 들어가거나, 호감도가 또 오릅니다.
- **모델이 숫자를 흘립니다.** 긴 채팅에서 HP가 슬그머니 회복되거나, 앞에서 정한 수치를 잊습니다.
- **판정이 모델 기분에 달려 있습니다.** 같은 행동이 어떤 때는 명중하고 어떤 때는 빗나갑니다.

Aethrion은 상태를 대화 기록에서 결정론적으로 다시 계산합니다. 같은 기록이면 같은 결과가 나오므로 리롤해도 한 번만 적용되고, 앞의 문장을 고치면 그 문장대로 다시 계산됩니다.

## 동작 방식

```txt
RisuAI ──(대화 전체)──▶ Aethrion /v1/chat/completions
                          1. 플레이어 문장을 다시 재생해 세계 상태를 만든다 (읽은 결과는 캐시)
                          2. 이번 턴에 규칙이 정한 것과 현재 상태를 모델에게 메모로 붙인다
                          3. 모델(--llm)이 카드·로어북·기록·메모를 보고 이야기를 쓴다
RisuAI ◀──(이야기 + <aethrion-status>)──┘
```

- 채팅 앱은 매번 대화 전체를 보내고, 채팅 id가 없습니다. 그래서 상태는 대화 기록을 따라갑니다. 리롤은 마지막 응답을 뺀 기록을 다시 보내므로 같은 결과가 나오고, 수정한 문장은 그 문장대로 다시 계산됩니다.
- 응답 끝의 `<aethrion-status id="...">` 블록은 상태창으로 그려지고, 다음 요청 때 기록에서 빠집니다. 블록의 id는 그 턴 뒤의 세계를 가리키는 체크포인트입니다. RisuAI가 컨텍스트 한도에 맞추려고 오래된 메시지를 잘라 보내도, 남아 있는 체크포인트부터 이어서 계산하므로 상태가 되감기지 않습니다.
- 문장을 무엇으로 읽었는지는 캐시되어(`--data` 폴더, 기본 `tmp/worlds`의 `bridge-readings.jsonl`), 새 문장만 해석 모델을 부릅니다. 체크포인트는 같은 폴더의 `bridge-checkpoints.jsonl`에 남습니다.

## 1. Aethrion 서버 실행

```bash
mix aethrion.serve --cast priv/casts/den.json --llm claude --locale ko --port 4848
```

`--llm`은 이야기를 쓰고 문장을 해석할 모델입니다. `anthropic`, `openai`, `ollama`, `lmstudio`, `llamacpp`, `claude`(Claude Code CLI), `codex` 중에서 고릅니다. `--llm` 없이 띄우면 `/v1`은 400을 돌려줍니다. 이야기를 쓸 모델이 없기 때문입니다.

## 2. RisuAI 설치

시험한 방법은 직접 띄운 RisuAI(Docker)입니다. 데스크톱 앱도 같은 요청을 보냅니다. 웹 버전(risuai.xyz)은 대부분의 요청을 RisuAI 쪽 서버를 거쳐 보내지만, `localhost`·`127.0.0.1` 주소는 브라우저에서 바로 요청하므로 `http://localhost:4848/v1`에 닿을 수 있습니다. 이때 Aethrion을 `--token`과 함께 띄우고 그 값을 키로 넣어야 합니다. 토큰이 없으면 다른 출처(웹 사이트)의 요청에 CORS 헤더를 보내지 않습니다. 그렇지 않으면 사용자가 연 아무 사이트나 이 서버와 그 뒤의 모델을 쓸 수 있기 때문입니다. 또 브라우저의 사전 요청(OPTIONS)에 답하려면 Erlang/OTP 29 이상이 필요합니다(그 전의 `:httpd`는 OPTIONS를 501로 거절합니다). 브라우저가 로컬 네트워크 접근을 허용할지 물을 수도 있고, 이 경로는 시험하지 않았습니다.

```bash
git clone https://github.com/kwaroran/RisuAI
cd RisuAI
docker compose up -d     # http://localhost:6001
```

처음 열면 이 서버에서 쓸 비밀번호를 정하라고 묻습니다. 끌 때는 같은 폴더에서 `docker compose down`을 실행합니다.

Docker 안의 RisuAI에서 내 컴퓨터의 Aethrion은 `http://host.docker.internal:4848/v1`입니다(Docker Desktop). Linux Docker라면 `docker-compose.yml`에 `extra_hosts: ["host.docker.internal:host-gateway"]`를 넣고, Aethrion을 `--bind 0.0.0.0 --token 비밀값`으로 띄웁니다.

## 3. 모델 설정

설정 → 봇 설정에서:

| 항목 | 값 |
| --- | --- |
| 모델 | `Custom API` |
| URL | `http://host.docker.internal:4848/v1` (데스크톱 앱이면 `http://localhost:4848/v1`) |
| 키/패스워드 | `--token`이나 `AETHRION_TOKEN`으로 정한 값 (없으면 비워 둠) |
| 요청 모델 | `aethrion:sera` (대화 상대가 세라) |
| 포맷 | `OpenAI Compatible` |

요청 모델은 다음 중에서 고릅니다. 목록은 `GET /v1/models`로 볼 수 있고, 적(enemy)은 대화 상대 목록에 나오지 않습니다.

- `aethrion:캐릭터id`: 그 캐릭터에게 말을 거는 것으로 읽습니다.
- `aethrion`: 적이 아닌 첫 캐릭터를 대화 상대로 씁니다.
- `aethrion-plain:캐릭터id`: 상태 블록 없이 이야기만 돌려줍니다. 이 경우 체크포인트가 없어서, 잘린 대화는 남은 기록만으로 계산합니다.

**보조 모델은 Custom API로 두지 마세요.** RisuAI는 요약, 감정 이미지, 번역 같은 일을 보조 모델에 맡기는데, 그 요청이 Aethrion으로 오면 요약할 글을 플레이어의 말로 읽습니다.

## 4. 캐릭터 카드

Aethrion 캐스트를 내레이터 카드로 내보내 RisuAI에 가져옵니다.

```bash
curl -s 'localhost:4848/casts/card?name=늑대굴' -o 늑대굴.json
```

RisuAI에서 캐릭터 임포트로 이 파일을 엽니다. 카드에는 등장인물 소개, 첫 메시지(적이 아닌 캐릭터의 `greeting`), 로어북, 그리고 상태창 정규식이 들어 있어서, 따로 설정하지 않아도 상태창이 그려집니다.

이미 쓰던 카드를 쓰려면 상태창 모듈만 가져옵니다. 설정 → 모듈 → 모듈 임포트에서 [`priv/risu/aethrion-status.json`](../priv/risu/aethrion-status.json)을 열고 그 카드에서 켭니다. 모듈은 `<aethrion-status>` 블록을 표시할 때만 바꾸는 정규식(디스플레이 수정) 하나입니다.

반대로 커뮤니티 카드를 Aethrion 캐스트로 가져와 수치와 엔딩을 붙일 수도 있습니다.

```bash
mix aethrion.card 내카드.png --player 선생님 --out casts/my.json
```

카드의 설명·성격·시나리오는 프로필로, 예시 대화는 말투로, 첫 메시지는 인사말로, 로어북은 세계 노트로 들어갑니다. 카드에는 게임 수치가 없으므로, 수치·엔딩·인연 스토리는 `/editor`에서 붙입니다. RisuAI의 정규식·트리거 스크립트와 매크로(`{{getvar}}` 등)로 만든 로어는 실행하지 않고, 가져올 때 무엇을 뺐는지 알려 줍니다.

## 5. 플레이

```txt
나: 세라, 고마워. 다이어 울프에게 롱소드를 휘두른다!

(모델의 이야기)
┌──────────────────────────────────────
│ 나 · HP 20/28
│ 도윤 · 호감 35 · 신뢰 15 · HP 14/20
│ 세라 · 호감 29 · 신뢰 18 · HP 21/21
│ 다이어 울프 · HP 23/37
└──────────────────────────────────────
```

- **리롤:** 같은 기록이므로 같은 판정이 나옵니다. 이야기만 새로 씁니다.
- **수정:** 마지막 문장이든 앞의 문장이든, 고친 문장부터 다시 계산합니다.
- **긴 채팅:** 앞부분이 잘려도 체크포인트에서 이어집니다. 응답의 상태 블록을 지우면 그 턴의 체크포인트는 쓰지 못하고, 그 앞 체크포인트부터 다시 계산합니다.
- **이어서 쓰기:** 새 턴이 아니므로 규칙은 아무것도 다시 적용하지 않고, 이어 쓴 부분에는 상태 블록을 붙이지 않습니다.
- **연달아 보낸 문장:** 답이 오기 전에 문장을 여러 개 보내면, 모두 이번 턴으로 적용하고 모델에게 함께 알립니다.
- **캐릭터 바꾸기:** 요청 모델을 `aethrion:doyun`으로 바꿔도 지금까지의 체크포인트에서 이어지고, 그 뒤 문장부터 도윤에게 한 말로 읽습니다.
- **캐스트를 고친 뒤:** 체크포인트는 만든 캐스트를 기억하므로, 캐스트를 바꾸면 남은 대화 기록에서 새로 계산합니다.

## 한계

- 응답은 한 번에 옵니다. `stream: true`면 서버 전송 이벤트 한 덩어리로 보냅니다.
- CLI 모델(`--llm claude`)은 한 턴에 10~15초쯤 걸립니다. API 모델이 더 빠릅니다.
- 한 요청에서 다시 계산하는 문장은 300개까지입니다. 체크포인트 없이 그보다 긴 대화를 보내면 400(`too_many_lines`)을 돌려줍니다.
- 그룹 채팅은 아직 지원하지 않습니다. 대화 상대는 요청 모델 이름으로 정합니다.
- 체크포인트 파일은 턴마다 세계 전체(캐스트의 로어는 빼고)를 저장하므로 오래 쓰면 커집니다. 지워도 동작하며, 그때는 대화 기록에서 다시 계산합니다.

## SillyTavern

SillyTavern도 같은 방식으로 붙습니다. API를 Chat Completion → Custom (OpenAI-compatible)으로 두고, 엔드포인트 `http://localhost:4848/v1`, 모델 `aethrion:sera`를 입력합니다. 상태창은 Regex 확장에 스크립트를 하나 추가해 그립니다.

- Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)<\/aethrion-status>/g`
- Replace With: `<div style="white-space:pre-line">$1</div>`
- Affects: AI Output, Other Options: Alter Chat Display

SillyTavern 연결은 OpenAI 호환 요청 형식만 맞춘 것으로, RisuAI만큼 시험하지는 않았습니다.
