# RisuAI에서 Aethrion을 모델로 쓰기

RisuAI(또는 SillyTavern)의 "Custom API"를 Aethrion으로 돌리면, 플레이어가 쓴 문장을 Aethrion의 규칙이 먼저 읽고 적용한 뒤 모델이 그 결과에 맞춰 이야기합니다. 호감·신뢰, HP, 주사위, 엔딩 같은 숫자는 모델이 아니라 규칙이 정합니다.

[English](risuai.md)

## 왜 필요한가

RisuAI 커뮤니티의 시뮬레이션·RPG 카드는 대개 상태를 모델에게 맡깁니다. 프롬프트에 "응답 끝에 상태창을 출력하라"고 적어 두거나, 채팅 변수와 트리거 스크립트로 숫자를 관리합니다. 그러다 보니 다음 문제가 반복됩니다.

- **리롤하면 두 번 적용됩니다.** 같은 공격을 다시 생성하면 피해가 한 번 더 들어가거나, 호감도가 또 오릅니다.
- **모델이 숫자를 흘립니다.** 긴 채팅에서 HP가 슬그머니 회복되거나, 앞에서 정한 수치를 잊습니다.
- **판정이 모델 기분에 달려 있습니다.** 같은 행동이 어떤 때는 명중하고 어떤 때는 빗나갑니다.

Aethrion은 상태를 대화 기록에서 정해진 규칙으로 다시 계산합니다. 같은 기록이면 언제나 같은 결과가 나오므로, 리롤해도 한 번만 적용되고 앞의 문장을 고치면 고친 대로 다시 계산됩니다.

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

## 가장 쉬운 방법: Docker

Elixir를 설치할 필요가 없습니다. RisuAI 데스크톱 앱이나 SillyTavern과 함께 쓰면 됩니다. RisuAI 웹 버전(risuai.xyz)은 내 컴퓨터의 서버에 닿지 못합니다([이유](#2-risuai-설치)).

```bash
git clone https://github.com/simulacre7/aethrion && cd aethrion
cp .env.example .env     # AETHRION_TOKEN과 모델 주소·키를 넣습니다
docker compose up -d
```

`.env`에 넣을 것:

- **`AETHRION_TOKEN`**(필수): 내 Aethrion의 접속 비밀번호입니다. 모델 사용량을 세는 토큰이 아니라서 비용이 들지 않습니다. 아무 긴 무작위 문자열이면 됩니다. 예를 들어 `openssl rand -hex 16`의 출력을 쓰면 됩니다. RisuAI가 요청마다 이 토큰을 보내고, 브라우저에 열린 다른 사이트가 이 서버와 그 뒤의 모델을 쓰지 못하게 막아 줍니다.
- **이야기를 쓸 모델**: OpenAI 호환 API(OpenRouter 등), Claude API, 이 컴퓨터에서 돌리는 모델(Ollama, LM Studio, llama.cpp) 중에서 고릅니다. 각각의 설정 예시는 `.env.example`에 있습니다.
- **`AETHRION_CAST`**: 캐스트를 고릅니다. 기본값은 `campfire`(모닥불)입니다.

그다음:

1. RisuAI에서 [3. 모델 설정](#3-모델-설정)대로 설정하되, URL은 `http://localhost:4848/v1`, Key/Password는 `AETHRION_TOKEN`의 값으로 넣습니다.
2. 카드 받기: http://localhost:4848 을 열고 Token 칸에 `AETHRION_TOKEN`을 넣은 뒤 **RisuAI** → **Download the RisuAI card**를 누릅니다. 같은 패널에서 URL과 요청 모델도 복사할 수 있습니다. 받은 카드는 [4. 캐릭터 카드](#4-캐릭터-카드)대로 가져옵니다. macOS 데스크톱 앱에서는 창에 끌어다 놓으면 됩니다.

`docker compose logs aethrion`으로 Aethrion이 하는 일을 볼 수 있고, `docker compose down`이면 멈춥니다. 포트는 이 컴퓨터에만 열립니다.

이 아래는 Elixir를 설치해서 직접 설정하는 방법입니다.

## 1. Aethrion 서버 실행

```bash
export AETHRION_TOKEN=$(openssl rand -hex 16)   # 접속 비밀번호. RisuAI의 Key/Password에 넣습니다
mix aethrion.serve --cast priv/casts/den.json --llm claude --locale ko --port 4848
```

`--llm`은 이야기를 쓰고 문장을 해석할 모델입니다. `anthropic`, `openai`, `ollama`, `lmstudio`, `llamacpp`, `claude`(Claude Code CLI), `codex` 중에서 고릅니다. `--llm` 없이 띄우면 `/v1`은 400을 돌려줍니다. 이야기를 쓸 모델이 없기 때문입니다.

## 2. RisuAI 설치

**데스크톱 앱**을 쓰세요([릴리스](https://github.com/kwaroran/RisuAI/releases)). 데스크톱 앱은 `http://localhost:4848/v1`로 바로 요청을 보냅니다.

- **웹 버전(risuai.xyz)은 내 컴퓨터의 Aethrion에 닿지 못합니다.** 로컬 주소(localhost, 127.0.0.1, 사설망 주소, `.local` 이름)는 앱이 직접 막고 "You are trying local request on web version" 오류를 냅니다. 그 밖의 주소는 RisuAI 쪽 서버를 거쳐 나가는데, 그 서버에서는 내 컴퓨터가 보이지 않습니다.
- **접속 비밀번호.** Aethrion을 토큰(`--token` 또는 `AETHRION_TOKEN`)과 함께 띄우고, 같은 값을 RisuAI의 Key/Password 칸에 넣으세요. 이 토큰은 내 Aethrion 서버의 비밀번호일 뿐, 모델 사용량을 세는 토큰이 아니라서 비용이 들지 않습니다. 토큰이 없으면 Aethrion은 이 기기의 이름(`localhost`, `127.0.0.1`, `host.docker.internal` 등)으로 온 요청만 받고, 다른 출처에서 온 요청은 403으로 거절합니다. 그렇지 않으면 브라우저에 열린 아무 사이트나 이 서버와 그 뒤의 모델을 쓸 수 있기 때문입니다.
- **직접 띄운 RisuAI**도 서버가 요청을 보내므로 됩니다. 다만 공식 이미지(`ghcr.io/kwaroran/risuai`)는 `VITE_RISU_LEGAL_CONFIGURED` 없이 빌드돼 있어서, 법적 문서 안내 화면에서 멈춥니다. RisuAI 안내문에는 개인 용도의 셀프호스팅이라면 이 값을 `TRUE`로 두고 이미지를 직접 빌드해도 된다고 적혀 있습니다. 안내문을 읽고 직접 판단하세요.

```bash
git clone https://github.com/kwaroran/RisuAI
cd RisuAI
docker compose up -d     # http://localhost:6001
```

처음 열면 이 서버에서 쓸 비밀번호를 정하라고 묻습니다. 끌 때는 같은 폴더에서 `docker compose down`을 실행합니다.

Docker 안의 RisuAI에서 내 컴퓨터의 Aethrion은 `http://host.docker.internal:4848/v1`입니다(Docker Desktop). Linux Docker라면 `docker-compose.yml`에 `extra_hosts: ["host.docker.internal:host-gateway"]`를 넣고, Aethrion을 `--bind 0.0.0.0 --token 비밀값`으로 띄웁니다.

## 3. 모델 설정

설정 → 채팅 봇 → 모델 탭에서:

| 항목 | 값 |
| --- | --- |
| 모델 | `Custom API` |
| URL | `http://localhost:4848/v1` (Docker 안에서 띄운 RisuAI라면 `http://host.docker.internal:4848/v1`) |
| 키/패스워드 | 접속 비밀번호(`--token`이나 `AETHRION_TOKEN`으로 정한 값) |
| 요청 모델 | `aethrion` (카드에서 첫 인사를 하는 캐릭터와 대화. `aethrion:sera`처럼 직접 지정할 수도 있음) |
| 포맷 | `OpenAI Compatible` |

요청 모델은 다음 중에서 고릅니다. 목록은 `GET /v1/models`로 볼 수 있고, 적(enemy)은 대화 상대 목록에 나오지 않습니다.

- `aethrion:캐릭터id`: 처음에는 그 캐릭터에게 말을 거는 것으로 읽습니다. 다른 캐릭터의 이름을 부르면 그때부터는 그 캐릭터에게 갑니다(아래 6절).
- `aethrion`: 캐스트 카드에서 첫 인사를 하는 캐릭터(적이 아니고 `greeting`이 있는 첫 캐릭터)를 대화 상대로 씁니다. 그런 캐릭터가 없으면 적이 아닌 첫 캐릭터입니다.
- `aethrion-plain:캐릭터id`: 상태 블록 없이 이야기만 돌려줍니다. 응답에 체크포인트 id가 없으므로, 잘리지 않은 대화는 문장들로 체크포인트를 다시 찾지만, 잘린 대화는 남은 기록만으로 계산합니다. 또 대화 상대를 바꾼 직후에는, 같은 서버의 다른 대화가 같은 첫 문장을 다른 캐릭터에게 했을 때 둘을 구분하지 못할 수 있습니다. 상태 블록을 쓰는 `aethrion`이 더 정확합니다.

**보조 모델은 Custom API로 두지 마세요.** RisuAI는 요약, 감정 이미지, 번역 같은 일을 보조 모델에 맡기는데, 그 요청이 Aethrion으로 오면 요약할 글을 플레이어의 말로 읽습니다.

## 4. 캐릭터 카드

Aethrion 캐스트를 내레이터 카드로 내보내 RisuAI에 가져옵니다. http://localhost:4848 을 열고 Token 칸에 접속 비밀번호를 넣은 뒤 **RisuAI** → **Download the RisuAI card**를 누르면 됩니다. 터미널에서 받으려면 이렇게 합니다.

```bash
curl -s -H "Authorization: Bearer $AETHRION_TOKEN" 'localhost:4848/casts/card?name=늑대굴' -o 늑대굴.json
```

RisuAI에서 캐릭터 임포트로 이 파일을 엽니다. 파일 선택 창이 뜨지 않으면(macOS 데스크톱 앱에서는 뜨지 않습니다) 파일을 RisuAI 창에 끌어다 놓으면 됩니다. 카드에는 등장인물 소개, 첫 메시지(적이 아닌 캐릭터의 `greeting`), 로어북, 그리고 상태창 정규식이 들어 있어서, 따로 설정하지 않아도 상태창이 그려집니다.

이미 쓰던 카드를 쓰려면 상태창 모듈만 가져옵니다. 설정 → 모듈 → 모듈 임포트에서 [`priv/risu/aethrion-status.json`](../priv/risu/aethrion-status.json)을 열고 그 카드에서 켭니다. 모듈은 `<aethrion-status>` 블록을 표시할 때만 바꾸는 정규식(디스플레이 수정) 하나입니다.

반대로 커뮤니티 카드를 Aethrion 캐스트로 가져와 수치와 엔딩을 붙일 수도 있습니다.

```bash
mix aethrion.card 내카드.png --player 선생님 --out casts/my.json
```

카드의 설명·성격·시나리오는 프로필로, 예시 대화는 말투로, 첫 메시지는 인사말로, 로어북은 세계 노트로 들어갑니다. 카드에는 게임 수치가 없으므로, 수치·엔딩·인연 스토리는 `/editor`에서 붙입니다. RisuAI의 정규식·트리거 스크립트와 매크로(`{{getvar}}` 등)로 만든 로어는 실행하지 않고, 가져올 때 무엇을 뺐는지 알려 줍니다.

## 5. 플레이

모닥불 캐스트에서 목걸이를 준 다음 턴에 고블린을 공격했을 때의 상태창입니다. 괄호 안은 이번 턴에 바뀐 만큼입니다.

```txt
나: 고블린 척후를 벤다

(모델의 서술)
┌──────────────────────────────────────
│ 나 · HP 28/28
│ 도윤 · 호감 45 · 신뢰 22 (+2) · HP 13/20 (-7)
│ 하린 · 호감 25 · 신뢰 20 · HP 24/24
│ 세라 · 호감 50 · 신뢰 44 (+2) · HP 21/21
│ 고블린 척후 · HP 0/7 (-7)
│ 고블린 궁수 · HP 7/7
│ 고블린 두목 · HP 21/21
└──────────────────────────────────────
```

척후는 쓰러졌고, 반격은 함께 싸운 도윤이 맞았습니다. 같이 싸운 도윤과 세라는 플레이어를 조금 더 믿게 됐습니다.

- **이번 턴 판정:** 상태창 아래 접힌 칸을 펼치면 대사를 무엇으로 읽었는지, 누가 봤고 누가 자리에 없었는지, 공격마다 굴린 주사위와 AC, 캐릭터 사이의 소문과 위로가 나옵니다.
- **리롤(답 다시 뽑기):** 같은 기록이므로 같은 판정이 나옵니다. 이야기만 새로 씁니다.
- **수정:** 마지막 문장이든 앞의 문장이든, 고친 문장부터 다시 계산합니다.
- **긴 채팅:** 앞부분이 잘려도 체크포인트에서 이어집니다. 응답의 상태 블록을 지우면 그 턴의 체크포인트는 쓰지 못하고, 그 앞 체크포인트부터 다시 계산합니다.
- **이어서 쓰기:** 새 턴이 아니므로 규칙은 아무것도 다시 적용하지 않고, 이어 쓴 부분에는 상태 블록을 붙이지 않습니다.
- **연달아 보낸 문장:** 답이 오기 전에 문장을 여러 개 보내면, 모두 이번 턴으로 적용하고 모델에게 함께 알립니다.
- **캐릭터 바꾸기:** 요청 모델을 `aethrion:doyun`으로 바꿔도 지금까지의 체크포인트에서 이어지고, 그 뒤 문장부터 도윤에게 한 말로 읽습니다.
- **캐스트를 고친 뒤:** 체크포인트는 만든 캐스트를 기억하므로, 캐스트를 바꾸면 남은 대화 기록에서 새로 계산합니다.

## 6. 여러 캐릭터와

내레이터 카드 한 장으로 등장인물 모두와 대화합니다. RisuAI의 그룹 채팅 기능은 쓰지 않습니다.

- **누구에게 하는 말인지:** 문장 맨 앞에서 이름을 부르면("도윤, 왜 그렇게 조용해?", "하린아 고마워") 그 캐릭터에게 하는 말이 되고, 이름이 없으면 직전 상대에게 이어서 말합니다. 선물이나 사과를 받은 캐릭터도 다음 상대가 됩니다.
- **누가 보는지:** 그 자리에 있는 캐릭터(적이 아니고, 쓰러지지 않았고, `away`가 아닌)는 플레이어의 말과 선물을 목격합니다. 그래서 다른 캐릭터에게 준 선물에 질투하거나, 거친 말에 실망합니다.
- **시간과 소문:** 캐스트의 스토리에 `turn_hours`가 있으면 턴마다 그만큼 시간이 흐릅니다. 그사이 질투나 외로움에 빠진 캐릭터는 가장 믿는 친구에게 털어놓고, 소문은 그렇게 퍼집니다. `away` 수치는 돌아오기까지 남은 시간이라서, 시간이 흐르면 줄어들고 0이 되면 돌아옵니다.
- **모델이 듣는 것:** 누가 봤는지, 누가 자리에 없어 모르는지, 누가 누구에게 털어놓았는지, 서로를 어떻게 여기게 됐는지, 누가 돌아왔는지를 사실로 전달받습니다. 상태창에는 `도윤 → 세라 · 긴장 +8`처럼 캐릭터 사이의 변화가 나옵니다.
- **전투에서도:** 아끼는 동료가 위험하면 대신 맞고, 아끼던 이가 쓰러지면 분노하고, 플레이어를 깊이 믿으면 유리하게 함께 공격하고, 원한이 있으면 치료를 미룹니다. 자리에 없는 동료는 싸우지 않습니다.

`priv/casts/campfire.json`(모닥불)이 이 모든 것을 보여 주는 캐스트입니다. 밤의 야영지에 세라와 도윤이 있고, 하린은 정찰을 나가 3시간 뒤에 돌아오며, 덤불 속에는 고블린이 있습니다.

```bash
mix aethrion.serve --cast priv/casts/campfire.json --llm claude --locale ko --port 4848
curl -s -H "Authorization: Bearer $AETHRION_TOKEN" 'localhost:4848/casts/card?name=모닥불' -o 모닥불.json
```

세라에게 목걸이를 주면 그것을 본 도윤이 질투해 하린에게 소식을 전하고, 세라는 고블린의 공격을 플레이어 대신 받아 줄 만큼 마음이 커집니다. 선물 없이 싸우면 세라는 한 번도 막아서지 않습니다.

## 알아 둘 것과 한계

- **스트리밍:** RisuAI 설정 → 채팅 봇에서 Response 스트리밍을 켜면, 서술이 써지는 대로 보입니다. 상태창은 맨 끝에 붙습니다. OpenAI 호환 API, Claude API, Claude Code CLI는 스트리밍되고, Codex CLI는 한 번에 옵니다.
- **걸리는 시간:** 새 문장은 먼저 모델이 무슨 행동인지 읽고(몇 초. 이미 읽은 문장은 저장돼 있어서 리롤할 때는 건너뜁니다), 그다음 서술을 씁니다. Claude Code CLI로는 서술 길이에 따라 한 턴에 15~40초쯤 걸립니다. API 모델이 더 빠릅니다.
- **비용:** 새 문장 하나에 모델 호출이 두 번 듭니다. 문장을 읽는 호출과 서술하는 호출입니다. `--read-model NAME`(또는 `AETHRION_READ_MODEL`)을 주면 같은 API의 더 작은 모델로 읽어서 비용을 줄일 수 있습니다. Claude Code CLI에서는 CLI를 띄우는 시간이 대부분이라 빨라지지는 않습니다.
- **서버 콘솔**에는 턴마다 한 줄씩 남습니다. 플레이어가 쓴 문장, 규칙과 모델이 걸린 시간, 모델이 답했는지가 나옵니다. 아무것도 안 나오면 RisuAI가 Aethrion에 닿지 못한 것입니다.
- 한 요청에서 다시 계산하는 문장은 300개까지입니다. 체크포인트 없이 그보다 긴 대화를 보내면 400(`too_many_lines`)을 돌려줍니다.
- RisuAI의 그룹 채팅 기능은 쓰지 않습니다. 내레이터 카드 한 장으로 여러 캐릭터와 대화합니다(6절).
- 체크포인트 파일은 턴마다 세계 전체(캐스트의 로어는 빼고)를 저장하므로 오래 쓰면 커집니다. 지워도 동작하며, 그때는 대화 기록에서 다시 계산합니다.

## SillyTavern

SillyTavern 1.19.0에서 확인했습니다. 표지와 로어북이 들어간 카드, 스트리밍, 상태창이 모두 되고, 스와이프해도 숫자가 그대로입니다.

1. **연결:** API Connections → API: Chat Completion → Chat Completion Source: Custom (OpenAI-compatible)로 두고 아래를 넣습니다.
   - Custom Endpoint: `http://localhost:4848/v1`
   - Custom API Key: 접속 비밀번호
   - Model ID: `aethrion`
   - Connect를 누릅니다. "Valid"가 뜨고 모델 목록이 나오면 Aethrion에 닿은 것입니다.
2. **카드:** 채팅 페이지의 **RisuAI** 패널에서 PNG 카드를 받아 캐릭터로 가져옵니다(Import Character, 또는 `data/default-user/characters/`에 파일을 넣기). 포함된 로어북을 가져올지 물으면 예를 누릅니다.
3. **상태창:** Regex 확장에서 전역 스크립트를 두 개, 이 순서로 추가합니다. 둘 다 Affects는 AI Output, Other Options는 Alter Chat Display입니다.
   - 이번 턴 판정을 접어 둔 상태창:
     - Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)\n?<aethrion-turn title="([^"]*)">([\s\S]*?)<\/aethrion-turn><\/aethrion-status>/g`
     - Replace With: `<div style="white-space:pre-line;border:1px solid rgba(127,127,127,.35);border-radius:10px;padding:8px 12px;margin-top:10px">$1<details><summary>$2</summary><div style="white-space:pre-line">$3</div></details></div>`
   - 판정할 게 없는 턴의 상태창:
     - Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)<\/aethrion-status>/g`
     - Replace With: `<div style="white-space:pre-line;border:1px solid rgba(127,127,127,.35);border-radius:10px;padding:8px 12px;margin-top:10px">$1</div>`

SillyTavern의 Chat Completion은 기본으로 스트리밍이 켜져 있습니다.
