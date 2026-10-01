# Aethrion

[English](README.md) | [한국어](README.ko.md)

[![CI](https://github.com/simulacre7/aethrion/actions/workflows/ci.yml/badge.svg)](https://github.com/simulacre7/aethrion/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**발음:** 에이트리온 / ay-three-on

**지속형 AI 캐릭터를 위한 공유 소셜 레이어.**

Aethrion은 기억하고, 관계를 맺고, 시간에 따라 스스로 행동하는 AI 캐릭터를 위한 지속형 소셜 시뮬레이션 런타임입니다. 캐릭터는 사용자에게만 반응하지 않고 서로에게도 반응합니다.

> LLM은 표현을 생성하고, 결정론적 규칙이 시뮬레이션을 구동합니다.

[바로 실행해보기](#바로-실행해보기) · [이벤트 두 개가 이야기가 되기까지](#이벤트-두-개가-이야기가-되기까지) · [소문은 퍼진다](#소문은-퍼진다) · [동작 방식](#동작-방식) · [LLM 경계](#llm-경계) · [시나리오](#시나리오와-리포트) · [Elixir 앱에서 사용하기](#elixir-앱에서-사용하기) · [채팅 앱과 게임](#채팅-앱과-게임에서-쓰기) · [엔딩과 전투](#엔딩과-전투) · [문서](#문서)

이름은 고대의 "aether" 개념에서 영감을 받았습니다. 하늘을 채우고 서로를 연결한다고 여겨졌던 보이지 않는 매질처럼, Aethrion은 기억, 관계, 자율 상호작용을 하나의 공유 소셜 레이어로 다룹니다.

## Alpha Status

Aethrion은 현재 **early alpha**(v0.2) 단계입니다.

- API는 바뀔 수 있습니다. [changelog](CHANGELOG.md)를 참고하세요.
- production-ready 상태가 아닙니다.
- 런타임 모델, API 형태, 데모 시나리오에 대한 피드백을 환영합니다.

## 바로 실행해보기

```bash
mix deps.get
mix test
mix demo.drama                 # host 이벤트 2개와 그로부터 이어지는 모든 일
mix demo.interactive --locale ko   # 캐릭터와 대화하고(한국어 입력 가능), 왜 그렇게 느끼는지 물어보기 (--no-status로 출력 줄이기)
mix aethrion.scenario --all    # 번들 시나리오 실행 및 기대값 검증
mix aethrion.report priv/scenarios/01_the_flower.json --locale ko   # tmp/01_the_flower.ko.html에 한국어 HTML 리포트 생성
```

처음이라면 [튜토리얼](docs/tutorial.ko.md)에서 몇 분 만에 세계, 규칙, what-if를 만들어 볼 수 있습니다.

interactive demo를 녹화한 세션입니다(실제 출력, [plain-text transcript](assets/demo/interactive-demo.txt)):

![Aethrion interactive demo](assets/demo/interactive-demo-readable.svg)

실제 모델과 함께 실행하기 (선택 사항이며, 모델이 없어도 시뮬레이션 결과는 동일합니다):

```bash
export ANTHROPIC_API_KEY=...
mix demo.interactive --llm anthropic
```

**모델과 함께 캐릭터와 대화하기.** 플레이어가 친 문장이 무엇을 하는지(공격, 하자고 한 활동, 선물, 대화와 그 톤)는 모델이 읽고, 캐릭터의 말도 모델이 씁니다. 무엇이 바뀌는지는 전부 규칙이 정하므로 재생하면 같은 결과가 나옵니다. 서버의 모델이든 이 컴퓨터의 모델이든 하나를 고르세요:

```bash
mix aethrion.serve --cast priv/casts/academy.json --locale ko --llm claude   # 이 컴퓨터의 Claude Code (로그인된 계정, 키 불필요)
mix aethrion.serve --llm codex                                              # 이 컴퓨터의 Codex CLI
mix aethrion.serve --llm ollama --model qwen3                               # Ollama가 로컬에서 띄운 모델 (lmstudio, llamacpp도 가능)
ANTHROPIC_API_KEY=... mix aethrion.serve --llm anthropic                    # Claude API
mix aethrion.serve --llm openai --base-url https://api.openai.com/v1 --model gpt-5-mini   # OpenAI 호환 API
```

그다음 http://localhost:4848 에서 대화하고, http://localhost:4848/editor 에서 캐스트를 편집합니다. `--tick-every 10`을 주면 10초마다 한 시간이 지나 캐릭터가 먼저 말을 걸어옵니다. `--llm` 없이 띄우면 키워드 규칙과 템플릿이 대신합니다. 테스트와 개발용 오프라인 대체 경로일 뿐 실제 플레이 모습은 아니며, 채팅 페이지에도 그렇게 표시됩니다.

## 이벤트 두 개가 이야기가 되기까지

host는 이벤트 두 개만 보냅니다. Yuna가 보는 앞에서 user가 Mina에게 꽃을 주고, 두 시간이 흐릅니다. 그 외에는 아무것도 스크립트되어 있지 않습니다. 아래는 `mix demo.drama` 출력의 일부입니다.

```txt
EVENT    user gives Mina a flower (seen by Yuna)
RELATION Mina affinity toward user +10
MEMORY   Mina remembers: "user gave mina a flower."
SAYS     Mina -> user: "Thank you for the flower!"
RULE     Yuna noticed the gift to Mina
STATE    Yuna jealousy +15
MEMORY   Yuna remembers: "yuna saw user give mina a flower."
MOOD     Yuna neutral -> jealous

EVENT    time passes +2h
SAYS     Yuna -> user: "You looked happy with Mina earlier. I wondered if you forgot about me."
CASCADE  Yuna confides in Haru
MEMORY   Haru remembers: "yuna told haru: yuna saw user give mina a flower."
SCENE    Yuna tells Haru about the flower you gave Mina.
SAYS     Haru -> user: "Yuna told me you gave Mina a flower. Smooth."
CASCADE  Haru comforts Yuna
STATE    Yuna loneliness -12
STATE    Yuna jealousy -5
SCENE    Haru stays with Yuna for a while. Yuna feels a little lighter.
MOOD     Yuna jealous -> neutral
```

Yuna가 먼저 연락하는 이유는 질투와 외로움의 합이 임계값을 넘었기 때문입니다. Haru에게 털어놓는 이유는 힘든 상태이고 Haru를 가장 신뢰하기 때문입니다. Haru는 꽃 이야기를 전해 듣고, 장난기 많은 성격이라 user를 놀립니다. 그리고 Yuna를 아끼기 때문에 위로합니다. 이 모든 것이 읽고, 테스트하고, 추적할 수 있는 규칙입니다.

두 시간이 지나기 전에 Yuna에게 사과하면 이 중 아무 일도 일어나지 않습니다. `mix demo.branches`는 같은 순간을 네 가지(침묵, 사과, 다정한 말, 날카로운 말)로 재생하고 Yuna의 결과를 비교합니다.

## 소문은 퍼진다

한 캐릭터를 대하는 방식은 다른 캐릭터들에게도 전해집니다. 사용자가 Haru가 보는 앞에서 Mina에게 모진 말을 하고, 다음 날 Haru에게는 다정하게 말을 겁니다(`priv/scenarios/12_word_gets_around.json`, 발췌):

```txt
EVENT    user -> Mina (hostile): You always ruin everything. (seen by Haru)
SAYS     Mina -> user: "Please stop."
RULE     Haru saw user be hostile to Mina and trusts user less
SAYS     Haru -> user: "What you said to Mina was unkind. Is everything okay?"

EVENT    time passes +2h
CASCADE  Mina confides in Yuna
RULE     Yuna heard user be hostile to Mina and trusts user less
SAYS     Yuna -> user: "Mina told me what you said. That didn't sound like you. Is everything okay?"
CASCADE  Yuna comforts Mina

EVENT    user -> Haru (warm): Want to grab lunch tomorrow?
SAYS     Haru -> user: "Thanks... but I saw what you said to Mina."
```

Haru는 그 장면을 봤고 Mina를 아끼기 때문에 사용자를 덜 믿게 되고, 직접 한마디 합니다. Yuna는 전해 듣기만 했으므로 신뢰가 절반만 떨어집니다. 같은 일이 반복되면 세부 기억이 흐려진 뒤에도 평판("haru knows user has been hostile to mina and yuna 2 times.")이 남아, 몇 주 동안 사용자의 친절이 덜 와닿습니다. `mix demo.interactive`에서 `here haru` 다음에 `message user yuna hostile leave me alone`을 입력하고(Haru는 Yuna를 아낍니다) `opinion haru user`로 확인해 보세요. 관계에는 이 과정에서 바뀌는 이름(friendly, strained, close 등의 단계)도 있어서 바뀔 때마다 이벤트로 알려 주고, `why <from>-><to> bond`로 언제, 왜 바뀌었는지 볼 수 있습니다.

## 왜 필요한가

대부분의 AI 캐릭터 시스템은 단순한 루프를 중심으로 만들어집니다.

```txt
user -> character -> response
```

Aethrion은 다른 모델을 탐구합니다.

```txt
character <-> character
character <-> world
character <-> user
```

목표 사용처는 narrative agent를 위한 social simulation layer입니다. 게임, TRPG assistant, 비주얼 노벨형 캐릭터 시스템, 오래 지속되는 AI companion app 아래에 들어갈 수 있는 레이어입니다.

"Yuna가 선물을 봤다", "Haru가 그 이야기를 Yuna에게서 들었다", "사과 이후 Yuna의 신뢰가 바뀌었다" 같은 사실은 LLM이 매번 즉흥적으로 만들어내는 것이 아니라, 검사 가능하고 테스트 가능하며 지속되는 규칙의 결과여야 합니다.

## 동작 방식

```txt
host event
  -> 검증
  -> rule pipeline (event rules, 이어서 reactive rules)
  -> 규칙이 enqueue한 follow-up 이벤트도 같은 검증과 pipeline을 통과
  -> state + structured outputs + trace
  -> 선택 사항: LLM이 읽기 전용 스냅샷으로 표현형 출력을 문장으로 다듬음
```

- **Rules**는 작은 모듈(`use Aethrion.Rule`)이며 명시적인 `Aethrion.Pipeline`으로 구성됩니다. 직접 규칙을 추가하거나, 기본 규칙을 제거하거나, 새 이벤트 타입을 등록할 수 있습니다. `mix aethrion.rules`로 목록을 볼 수 있습니다.
- **Cascades**로 캐릭터가 서로에게 영향을 줍니다: 목격, 털어놓기, 소문, 공감, 위로, 함께 시간 보내기.
- **평판(Reputation)**: 한 캐릭터를 대한 방식이 다른 캐릭터들에게도 전해집니다. 보거나 전해 들은 이가 당신을 판단하고, 흐려진 세부 기억은 오래 남는 평판이 됩니다.
- **관계 단계(Bonds)**: 각 관계가 지금 어떤 사이인지(서먹함, 친함, 가까움 등) 이름을 붙이고, 이벤트로 단계가 바뀌면 알려 줍니다.
- **시간**은 사람 사이의 시간처럼 흐릅니다: 한동안 연락이 없으면 외로워져 먼저 연락하고, 답이 없으면 연락을 줄입니다. 질투는 옅어지고, 반복되는 사과는 효과가 줄며, 답장은 같은 말을 되풀이하지 않습니다. 몇 주짜리 세션을 직접 돌려 대사가 자연스러운지 확인합니다.
- **여러 사람**이 한 세계를 공유할 수 있습니다: 플레이어마다 표시 이름과 자기만의 "없는 동안" 요약이 있고, 캐릭터는 감정의 대상인 사람에게 말을 겁니다.
- **Traces**는 모든 변화를 기록합니다: 어떤 규칙이, 어떤 이벤트에 대해, 무엇을 무엇으로 바꿨는지. interactive demo의 `why yuna jealousy`가 "Yuna는 왜 이만큼 질투하는가?"에 각 변화와 그 뒤의 이벤트 연쇄로 답합니다.
- **Memory**에는 종류(experienced, observed, heard), 출처, 같은 사건에 대한 모두의 기억을 잇는 topic, 나이 기반 감쇠, 희미해진 경험을 오래 남는 인상(impression)으로 통합하는 기능이 있습니다. 검색은 결정론적이며 vector search를 쓰지 않습니다.
- **Tuning**으로 모든 규칙의 수치가 데이터가 됩니다: 세계, 저장된 상태, 시나리오에서 코드 없이 덮어쓸 수 있습니다.
- **결정론** 덕분에 테스트할 수 있습니다: 같은 이벤트는 항상 같은 세계를 만듭니다. property test가 무작위 이벤트 시퀀스에 대해 값 범위, 결정성, 영속화 왕복을 검증합니다.

모든 규칙과 수치는 [docs/rules.md](docs/rules.md)에 있습니다.

## LLM 경계

언어 모델이 할 수 있는 일은 정확히 두 가지이며, 둘 다 상태를 직접 바꾸지 못합니다.

| | 방향 | 영향을 줄 수 있는 것 |
| --- | --- | --- |
| **Render** | structured output -> 문장 | 그 출력의 텍스트 |
| **Interpret** | 사용자의 자유 텍스트 -> 이벤트 제안 | 닫힌 선택지(톤이 있는 메시지, 또는 사과) 중 하나. 이후 다른 이벤트와 똑같이 검증되고 규칙을 통과합니다 |

```elixir
{:ok, state, outputs, _log} = Aethrion.dispatch(state, event)
outputs = Aethrion.Expression.render(outputs, adapter: Aethrion.LLM.Anthropic)
```

모든 표현형 출력은 결정론적 fallback 텍스트와 읽기 전용 컨텍스트 스냅샷(프로필, 기분, 관계, 선택된 기억)을 담고 있습니다. adapter는 state를 받지 않습니다. 모델이 실패하거나, 시간 초과되거나, 거절하면 fallback 텍스트가 쓰이고 세계는 계속 진행됩니다.

표현은 언어와도 분리되어 있습니다. `FakeAdapter`는 한국어 템플릿을 내장하고 있어(이름의 받침에 맞춰 조사를 고릅니다) `mix demo.interactive --locale ko`로 모든 대사를 한국어로도 볼 수 있습니다(데모 캐릭터는 한국어 줄에서 미나·유나·하루로 불립니다). 실제 모델과 함께 `--llm anthropic --locale ko`로 실행하면 모델이 한국어로 대사를 씁니다. 시뮬레이션 결과는 언어와 무관하게 동일합니다.

```txt
SAYS     Yuna -> user: "You looked happy with Mina earlier. I wondered if you forgot about me."
KO       유나: "아까 미나랑 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?" (Aethrion.LLM.FakeAdapter)
```

Adapter: `Aethrion.LLM.Anthropic`, `Aethrion.LLM.OpenAICompatible`(OpenAI, vLLM, Ollama, llama.cpp), 그리고 결정론적인 `Aethrion.LLM.FakeAdapter`. 두 네트워크 adapter 모두 Erlang 내장 `:httpc`를 사용합니다. 자세한 내용은 [docs/expression.md](docs/expression.md)를 참고하세요.

## 시나리오와 리포트

시나리오는 세계, 이벤트 스크립트, 기대값을 담은 JSON 파일입니다. 테스트 스위트에서 실행되고, 독립 실행형 HTML 리포트로 렌더링됩니다.

```json
{
  "name": "The flower",
  "world": "demo",
  "events": [
    {"type": "gift_received", "from": "user", "to": "mina", "item": "flower", "observed_by": ["yuna"]},
    {"type": "time_tick", "hours": 2}
  ],
  "expect": [
    {"output": "character_interaction", "kind": "comfort", "character": "haru", "to": "yuna", "count": 1},
    {"memory": {"character": "haru", "kind": "heard", "source": "yuna"}, "count": 1}
  ]
}
```

<img src="assets/report/the-flower.ko.png" alt="Aethrion 시나리오 리포트: 요약, 등장인물, 감정 변화, 관계 그래프, 타임라인" width="720">

번들 시나리오: the flower, the apology, words matter(톤), rumor mill(신뢰 그래프를 따라 퍼지는 소문), long silence(외로움과 희미해지는 기억), small town(같은 규칙, 다른 튜닝), crossroads(한 순간, 네 갈래의 분기를 나란히 비교), old friends(대화가 희미해지며 오래 남는 인상으로 통합됨), benefit of the doubt(같은 날카로운 말도 관계 이력에 따라 다르게 받아들여짐), company(사용자가 없는 동안 친구끼리 곁을 지켜 줌), two regulars(두 사람이 있을 때 메시지가 알맞은 사람에게 감), word gets around(친구 앞에서 한 모진 말이 평판이 됨), slowly closer(일주일간의 작은 친절로 관계 단계가 한 칸씩 가까워짐), 하숙집(한국어 캐스트, 한국어 리포트(`mix aethrion.report ... --locale ko`)로 보기 좋음). [docs/scenarios.md](docs/scenarios.md)를 참고하세요.

## Interactive Demo

```txt
user> gift user mina flower observed_by yuna
...
MOOD     Yuna neutral -> jealous

user> say yuna sorry I forgot about you
INTENT   "sorry I forgot about you" -> apology_offered via Aethrion.LLM.FakeAdapter
EVENT    user apologizes to Yuna: sorry I forgot about you
RULE     Yuna accepted an apology from user
STATE    Yuna jealousy -15
STATE    Yuna loneliness -6
RELATION Yuna trust toward user +8
MEMORY   Yuna remembers: "user apologized to yuna: sorry I forgot about you"
SAYS     Yuna -> user: "Thanks. I just wanted to feel remembered too."
MOOD     Yuna jealous -> neutral

user> why yuna jealousy
  jealousy 0 -> 15 by observation in e1: user gives Mina a flower (seen by Yuna)
  jealousy 15 -> 0 by apology in e2: user apologizes to Yuna: sorry I forgot about you
```

명령어: `say`, `message`, `gift`, `apologize`, `comfort`, `tick`, `here`(같은 자리에 있어 당신의 말을 목격하는 캐릭터), `opinion`(한 캐릭터가 다른 이를 어떻게 보는지), `digest`(그동안 달라진 것 요약), `status`, `memories`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, `record`(플레이 세션을 재생 가능한 시나리오로 저장), `report`(세션을 HTML 리포트로 저장).

## Elixir 앱에서 사용하기

```elixir
alias Aethrion.{Event, Runtime}

state = Runtime.demo_state()
event = Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])

{:ok, next_state, outputs, log} = Runtime.dispatch(state, event)
{:ok, step} = Runtime.step(next_state, Event.time_tick("t2", hours: 2))

step.events   # tick과, 그로 인해 이어진 털어놓기와 위로
step.trace    # 규칙별 모든 변화
```

`outputs`는 structured effect입니다. 이를 어떻게 렌더링하고 저장하고 전달할지는 host application이 결정합니다.

오래 실행되는 supervised world:

```elixir
children = [
  {Aethrion.World,
   name: :garden,
   persistence: {Aethrion.Persistence.JsonFile, path: "tmp/garden.json"},
   scheduler: [interval_ms: 60_000, tick_hours: 1],
   expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000]}
]

Supervisor.start_link(children, strategy: :one_for_one)
Aethrion.World.subscribe(:garden)   # {:aethrion, :garden, {:dispatched, step}}, {:expressed, output} 수신
```

`persistence:` 대신 `journal: "tmp/garden.jsonl"`을 쓰면 추가 전용 이벤트 로그가 남습니다. 세계는 로그를 재생해 그대로 복원되고, `mix aethrion.journal`로 어떤 저널이든 리포트로 만들 수 있습니다.

더 많은 예시는 [examples/](examples)와 [docs/api.md](docs/api.md)에 있습니다.

## 채팅 앱과 게임에서 쓰기

위의 예시는 프로세스 하나에 세계 하나입니다. 채팅 앱이나 게임 서버에는 사용자(또는 세이브 슬롯, 방)마다 세계가 하나씩 필요하고, 대화가 이어져야 하며, 어떤 언어에서든 붙일 수 있어야 합니다.

**사용자마다 세계 하나.** `Aethrion.Worlds`는 키(사용자 id 문자열 같은 아무 값)마다 세계를 하나씩 둡니다. 처음 쓸 때 키로부터 시작하고, 한동안 안 쓰면 멈추며, 저널에 남아 있어 다시 켜면 그대로 돌아옵니다. 키를 atom으로 바꾸지 않으므로 사용자 수가 VM의 atom 한도에 묶이지 않습니다.

```elixir
children = [
  {Aethrion.Worlds,
   name: MyApp.Worlds,
   idle_after: :timer.minutes(30),
   world: fn user_id ->
     [initial_state: MyApp.Cast.state(),
      journal: "data/worlds/#{Aethrion.Worlds.file_name(user_id)}.jsonl",
      expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000, adapter_opts: [language: "Korean"]]]
   end}
]

Aethrion.Worlds.subscribe(MyApp.Worlds, user_id)     # {:aethrion, {MyApp.Worlds, user_id}, payload}
Aethrion.Worlds.dispatch(MyApp.Worlds, user_id, event)
```

**대화.** 캐릭터는 사람마다 최근 대화를 기억합니다(`Aethrion.Conversation`). 답장을 쓰는 모델은 대화의 흐름과 각 말이 얼마나 전에 오갔는지, 그리고 규칙이 정한 태도("아직 최근 일로 서운함")를 봅니다. 그래서 실제로 한 말에 답하고, 캐릭터의 말투(`voice`)를 따르되 일어나지 않은 일을 지어내지 않습니다. 무엇이 일어나는지는 규칙이, 어떻게 들리는지만 모델이 정합니다. 모델이 한 말은 저널에 남으므로 다시 켠 세계는 사실뿐 아니라 그때 한 말까지 기억합니다. 사용자가 입력한 글은 인용된 데이터로 모델에 전달되어 프롬프트를 바꿀 수 없습니다.

**어떤 언어에서든.** `mix aethrion.serve`(또는 슈퍼비전 트리의 `Aethrion.API`)는 Erlang 내장 서버로 세계들을 JSON over HTTP로 제공합니다:

```bash
curl -s localhost:4848/worlds/alice/say -H 'content-type: application/json' \
  -d '{"to": "mina", "text": "좋은 아침!"}'

curl -s localhost:4848/worlds/alice/events -H 'content-type: application/json' \
  -d '{"type": "time_tick", "hours": 6}'      # 시간이 흐르면 캐릭터가 먼저 연락하고, 소문을 나누고, 서로 곁을 지킵니다
```

`say`는 자유 입력(이벤트로 해석)을, `events`는 시나리오에 쓸 수 있는 모든 이벤트를 받고, `GET /worlds/{key}/conversation?character=mina&after=e12`로 새 대사를 가져올 수 있습니다. bearer 토큰, localhost 바인딩, 크기 제한은 기본으로 켜져 있거나 옵션 하나로 켤 수 있습니다. [docs/api.md](docs/api.md#http-api)와 [cookbook](docs/cookbook.md)을 참고하세요.

## 엔딩과 전투

AI 채팅과 게임에서 자주 필요한 두 가지를 다른 모든 것과 같은 방식, 즉 수치에 대한 규칙으로 정합니다. 같은 플레이는 언제나 같은 결말에 이르고, 그 이유를 보여 줄 수 있습니다.

**수치로 정해지는 엔딩.** 육성 시뮬레이션처럼 정합니다. 세계의 `story`에는 활동("공부"나 "그림"이 수치와 감정에 주는 영향), 우선순위 순서대로의 엔딩과 조건, 그리고 엔딩을 정하는 시점(마감 시각, 또는 어떤 조건이 성립하는 순간)이 들어갑니다:

```json
"stats": {"mina": {"art": 10, "intelligence": 10}},
"story": {
  "deadline": 720,
  "activities": {"paint": {"art": 3, "joy": 4, "stress": 2}},
  "endings": [
    {"id": "lovers", "title": "함께",
     "when": [{"relationship": ["mina", "user"], "field": "affinity", "at_least": 80},
              {"bond": ["mina", "user"], "is": "close"}]},
    {"id": "painter", "title": "화가의 길", "when": [{"stat": ["mina", "art"], "at_least": 70}]},
    {"id": "ordinary", "title": "평범한 여름", "when": []}
  ]
}
```

`Aethrion.Story.progress/1`은 각 엔딩에 얼마나 가까운지와 무엇이 부족한지("mina art 55 (needs at least 70)")를 알려 주므로, 게임이 루트 힌트를 줄 수 있습니다. `examples/endings.exs`는 30일을 네 가지 방식으로 보내 네 가지 엔딩에 이릅니다. `priv/casts/summer.json`은 채팅에서 바로 해 볼 수 있는 한국어 육성 시뮬레이션입니다. 미대 입시를 30일 앞둔 서윤을 돌보며, 하루하루 무엇을 하자고 하는지("오늘은 같이 그림 그리자", "내일은 좀 쉬자")와 어떻게 말을 거는지에 따라 여섯 엔딩(곁에 남은 사람, 지쳐 버린 여름, 화가의 길, 합격 통지서, 닫힌 방문, 평범한 여름) 중 하나로 정해집니다. 몰아붙이면 스트레스가 100에 닿는 순간 마감 전에 끝나고, 엔딩이 정해진 뒤에는 더 이상 하루를 보낼 수 없습니다. 채팅 페이지의 Story 버튼은 엔딩별 진행도와 부족한 것을 보여 줍니다.

```bash
mix aethrion.serve --cast priv/casts/summer.json --locale ko --llm claude   # http://localhost:4848 에서 그냥 대화하면 됩니다
```

**채팅에 명령어는 없습니다.** `POST /worlds/{key}/chat`은 플레이어가 친 문장을 그대로 받고, 무엇을 하는 말인지는 모델이 읽습니다([채팅 문장 읽기](#채팅-문장-읽기) 참고). 싸움 중이면 전투 행동, 스토리의 활동을 하자고 하면 활동, 무언가를 건네면 선물, 나머지는 대화와 그 톤입니다. 싸움 중에 말과 행동이 한 줄에 섞이면("리아, 고마워! 늑대왕의 목을 노려 벤다") 둘 다 합니다. 리아에게 고맙다고 말한 뒤 늑대왕을 벱니다. 응답의 `interpreted.as`가 어떻게 읽었는지 알려 주고, 한 번 읽힌 이벤트는 그대로 재생됩니다. 아래 대사는 모델 없이 내장 템플릿이 쓴 것이고, `--llm`을 주면 모델이 캐릭터의 말투로 씁니다:

```txt
나:  서윤아, 오늘은 같이 그림 그리자         -> 활동 그림, 하루가 지남 (Day 1 of 30)
나:  네 그림 진짜 좋다. 색이 예뻐            -> 대화 (다정)   서윤: 정말? ...그렇게 말해 줘서 고마워.
나:  물감 새로 사 왔어                       -> 선물 물감     서윤: 물감... 나 주려고 챙긴 거야? 고마워.
나:  내일은 좀 쉬자. 요즘 너무 무리했어      -> 활동 휴식, 하루가 지남
```

**전투.** `hp` 수치가 있는 모든 행위자(플레이어 포함)가 공격, 방어, 회복, 도주를 할 수 있습니다. 피해는 공격력, 방어력, 그리고 누가 누구를 치는지와 전투 상황(양쪽 hp)에서 나온 굴림으로 정해지므로 전투는 그대로 다시 재생되고, 중간에 잡담을 해도 주사위가 바뀌지 않습니다. 방어나 회복을 하면 적(`enemy` 수치가 있는 행위자)이 그 턴에 플레이어 쪽에서 가장 약한 사람을 노리므로 동료를 감싸는 것("리아를 감싸며 방패를 든다")이 의미가 있고, 쓰러진 자는 되살아나지 않으며, 엔딩이 정해지면 더는 싸우지 않습니다. 캐릭터는 전투를 느낍니다. 공격받은 쪽은 원망하고, 그를 아끼는 목격자는 너를 덜 믿고, 곁에서 함께 싸운 동료는 더 믿고, 치료받은 쪽은 정이 듭니다. 반대 방향으로도 작동합니다. 파티원(`party` 수치)은 플레이어에 대한 신뢰가 기준(`combat.party_trust`, 기본 10, 퀘스트는 15) 이상이면 곁에서 함께 싸우고(치유사는 다친 플레이어부터 치료합니다), 아니면 물러서서 지켜봅니다(한 번만 말합니다). 동료는 지켜보는 것만으로가 아니라 함께 싸워야 신뢰가 오릅니다. 동료에게 어떻게 말해 왔는지가 누가 곁에 서는지를 정합니다. 채팅에서는 그냥 말하듯 칩니다. "늑대왕의 목을 노려 벤다"는 공격, "리아를 감싸며 방패를 든다"는 리아를 지키는 방어, "리아, 치료해 줘"는 리아의 치료, "카엘, 고마워"는 대화가 됩니다. `priv/casts/quest.json`은 늑대왕에 맞서는 한국어 파티로, 엔딩이 전투 결과와 동료를 어떻게 대했는지에 따라 달라집니다:

```bash
mix run examples/combat.exs                                   # 같은 퀘스트, 다섯 가지 방식으로 다섯 엔딩
mix aethrion.serve --cast priv/casts/quest.json --locale ko --llm claude   # http://localhost:4848 에서 그냥 대화하면 됩니다
```

**메신저형 채팅.** 캐릭터 게임의 메신저 기능이 동작하는 방식을 본떴습니다. 학생이 선생님에게 먼저 메시지를 보내고, 답장은 몇 개의 선택지에서 고르며, 인연이 깊어지면 다음 인연 스토리가 열립니다. 캐릭터와 대사는 모두 새로 썼습니다. 스토리의 `milestones`는 조건이 처음 충족될 때 한 번 열리고, 캐릭터가 먼저 보내는 메시지를 함께 남기며, 엔딩과 달리 이야기는 계속됩니다(`Aethrion.Rules.Milestone`, `:milestone_reached`). `GET /worlds/{key}/replies?character=hana`는 톤이 붙은 답장 선택지 세 개를 주고(`Aethrion.Replies`), 많은 게임과 달리 고른 답장이 실제로 관계를 움직입니다. `polite` 성향의 캐릭터는 모델 없이도 선생님에게 존댓말로 씁니다. `priv/casts/academy.json`에는 학생 셋(하나, 유키, 미오)과 인연 스토리 여섯 개가 있습니다(아래 답장은 내장 템플릿이 쓴 것이고, `--llm`을 주면 모델이 씁니다):

```txt
나:  하나야, 어제 만든 거 정말 대단하더라!    하나: 에이, 갑자기 왜 이래요? 기분은 좋네요.
나:  고마워, 덕분에 수업 준비가 금방 끝났어.  하나: 헤헤, 그런 말은 더 해 줘도 돼요.
     ♥ 인연 스토리 · 하나 1: 고장 난 오르골
     하나: 선생님! 혹시 방과 후에 시간 있어요? 보여 드릴 게 있어요!
```

```bash
mix aethrion.serve --cast priv/casts/academy.json --locale ko --llm claude --tick-every 30
```

**테이블탑 규칙 (D&D 5e SRD).** 전투원에게 `attack_bonus`와 `ac`(그리고 피해 주사위 `damage_dice`, `damage_die`, `damage_bonus`)를 주면 공격이 시스템 레퍼런스 문서 5.1(SRD 5.1)의 d20 규칙을 따릅니다. d20 + 보너스로 방어도(AC)를 넘으면 명중하고, 자연 20은 무조건 명중하며 피해 주사위를 두 번 굴리고, 자연 1은 무조건 빗나갑니다. 방어(회피) 중인 대상은 불리하게(d20 두 개 중 낮은 것) 공격받고, 치유사는 주사위로 치료하며(`heal_dice` 1, `heal_die` 8, `heal_bonus` 3이면 상처 치료 주문), 포션은 SRD의 치유 포션(2d4+2)으로 둘 수 있습니다. 주사위는 전투 자체에서 나오므로 그대로 재생되고, 모든 줄이 테이블에서 읽어 주듯 주사위를 보여 줍니다: `[d20 13+5=18 vs AC 14, 명중. 1d8+3 (3)] 네가 다이어 울프에게 6의 피해를 입혔다.` `priv/casts/den.json`은 SRD의 다이어 울프와 늑대들에 맞서는 파이터(너), 클레릭, 로그의 늑대굴이고, `examples/den.exs`는 이를 한국어 문장만으로 세 가지 방식으로 플레이해 세 엔딩에 이릅니다. SRD 자료는 CC-BY-4.0으로 사용합니다(`priv/casts/SRD-NOTICE.md`). 회피는 한 라운드가 아니라 다음 한 번의 공격까지 유지되고, 늑대가 넘어뜨리는 내성 굴림 같은 효과는 아직 다루지 않습니다.

```bash
mix run examples/den.exs
mix aethrion.serve --cast priv/casts/den.json --locale ko --llm claude   # http://localhost:4848 에서 그냥 대화하면 됩니다
```

## 세계 만들기

세계는 캐스트 파일(JSON) 하나입니다. 프로필·말투·성향이 있는 캐릭터, 관계, 수치, 활동·엔딩·인연 스토리가 있는 스토리, 규칙 숫자 조정(tuning)이 들어갑니다. `mix aethrion.serve`는 `/editor`에서 **캐스트 편집기**도 제공합니다. 캐릭터, 관계, 수치, 엔딩, 인연 스토리를 폼으로 편집하고(조건은 수치·관계·사이·기분·시간 빌더로), 입력할 때마다 서버가 검증해 문제와 위치를 알려 주며, JSON으로 내려받습니다. **루트 시뮬레이터**는 플레이어가 채팅하듯 적은 루트대로 스토리를 진행해, 루트마다 어느 엔딩에 며칠째 닿는지와 다른 엔딩에 얼마나 가까웠는지 보여 줍니다:

```txt
오늘은 같이 그림 그리자
3일마다: 내일은 좀 쉬자
10일째: 너 주려고 물감 사 왔어
```

코드에서는 `Aethrion.Simulator`와 `POST /casts/simulate`가 같은 일을 합니다. 모든 루트는 결정론적이라, 숫자 하나를 바꾸면 그 효과가 바로 보입니다.

## 채팅 문장 읽기

문장이 무엇을 하는지는 해석기(`Aethrion.Interpreter`)가 정합니다. 자유 텍스트와 규칙 사이의 경계로, 해석기는 확신도와 함께 이벤트를 제안하고 규칙이 그것을 검증해 적용하므로, 재생할 때 해석기를 다시 부르지 않습니다. 기본 `Interpreter.Rules`는 키워드와 패턴으로 읽습니다. 모델은 `Interpreter.questions/1`(캐스트에서 뽑은 선택지: 무엇을 하는 말인지, 누구에게, 어떤 톤으로, 어떤 활동인지, 누가 치료하는지)에 답하는 방식으로 연결되고, `Interpreter.from_answers/2`가 답을 이벤트로 바꿉니다. 선택지와 확률을 돌려주는 판단 모델(Jev 등)이나 구조화 출력을 쓰는 LLM이 이 모양에 맞고, 모델이 실패하거나 선택지 밖으로 답하거나 확신이 낮으면 규칙이 대신합니다.

`mix aethrion.interpret.eval`은 사람이 의도한 의미로 라벨을 단 한국어 채팅 170문장(`priv/eval/interpret.ko.json`, 퀘스트·늑대굴·여름·학원 캐스트)으로 해석기를 채점합니다. 키워드 규칙은 105문장(62%)을 맞힙니다. 사전에 없는 표현("ㄱㄱ 늑대왕 잡자", "수채화 연습하자", "쿠키 구워 왔어")을 놓칩니다. Claude Code CLI(`--llm claude`)를 쓴 `Interpreter.LLM`은 158문장(93%)을 맞히고, 틀린 것도 대부분 근소한 차이입니다("붓" 대신 "새 붓" 등). `--llm 이름`으로 어떤 백엔드든 채점할 수 있습니다. `--interpreter MyApp.Interpreter`로 다른 해석기를 같은 문장으로 채점할 수 있습니다.

## Runtime vs LLM Server

Aethrion은 BEAM 내부에서 모델 추론을 실행하지 않으며, 대부분의 런타임 이벤트는 LLM을 호출하지 않습니다.

```txt
event
  |
  v
Aethrion Runtime
  |
  | deterministic rules
  v
updated state + structured outputs
  |
  +--> LLM 호출 불필요
  |
  +--> 선택적 expression rendering (supervised task, timeout, fallback)
         |
         | HTTP JSON
         v
       Anthropic / OpenAI 호환 provider 또는 model server
```

- LLM 추론은 보통 시스템에서 가장 느린 부분입니다.
- Aethrion은 권위 있는 시뮬레이션 상태를 LLM 서버 밖에 둡니다.
- 많은 상태 전이는 LLM 왕복이 전혀 필요 없습니다.
- LLM 호출에는 timeout이 걸리고 생략할 수 있습니다. retry, rate limit, cache는 adapter나 host의 몫입니다.
- LLM 호출이 실패해도 결정론적 상태는 계속 진행됩니다.
- LLM 응답이 세계에 영향을 주어야 한다면, 새 이벤트로 돌아와 규칙을 다시 통과해야 합니다.

BEAM/OTP는 LLM 추론을 빠르게 하기 위해 쓰는 것이 아닙니다. 오래 지속되는 세계, 예약된 행동, 장애, 외부 LLM 호출을 안정적으로 조율하기 위해 씁니다.

## 왜 Elixir인가?

시뮬레이션 코어는 결정론적이고 process-free이므로 supervision tree 없이 테스트할 수 있습니다. OTP는 실제 가치가 있는 곳에만 들어갑니다. `Aethrion.World`는 runtime server(상태, 구독, 히스토리, 스냅샷), `time_tick` 이벤트용 scheduler, 느리거나 실패하는 모델 호출을 격리하는 task supervisor를 함께 감독합니다. runtime이 죽으면 마지막 스냅샷에서 재시작합니다. 캐릭터는 plain data로 남고, 프로세스는 런타임 관심사를 모델링합니다.

## Aethrion이 하는 것 / 하지 않는 것

Aethrion은:

- 결정론적 소셜 시뮬레이션 런타임입니다
- 서로에게 영향을 주는 지속형 AI 캐릭터를 위한 이벤트 기반 모델입니다
- 설명 가능합니다: 모든 변화가 규칙과 이벤트로 추적됩니다
- 설계상 LLM에 종속되지 않습니다

Aethrion은:

- 챗봇 프롬프트 모음이 아닙니다
- 비주얼 노벨 엔진이 아닙니다
- Phoenix 웹 앱이 아닙니다
- 벡터 데이터베이스 프로젝트가 아닙니다
- LLM이 권위 있는 상태를 소유하는 프레임워크가 아닙니다

## 구조

```mermaid
flowchart TD
    Host["Host app / game / CLI"] --> Runtime["Aethrion Runtime"]
    Runtime --> Pipeline["Rule Pipeline"]
    Pipeline --> State["Memory / Emotion / Relationships"]
    Pipeline -->|follow-up events| Runtime
    Pipeline --> Trace["Trace"]
    Pipeline --> Outputs["Structured Outputs + context snapshots"]
    Outputs --> Host
    Outputs --> Expression["Expression layer"]
    Expression --> LLM["LLM Adapter (optional)"]
    LLM -->|text only| Host
    Host -->|free text| Intent["Intent proposal"]
    Intent -->|validated event| Runtime
```

## 로컬 설정

이 프로젝트는 Elixir Mix 라이브러리입니다. Phoenix, 데이터베이스, vector store, LLM provider가 필요하지 않습니다.

권장 로컬 버전:

- Elixir 1.19+
- Erlang/OTP 28+

## 문서

- [docs/tutorial.ko.md](docs/tutorial.ko.md) - 몇 분 만에 나만의 세계 만들기
- [notebooks/tour.livemd](notebooks/tour.livemd) - Livebook 노트북으로 둘러보기 (영문)
- [docs/concept.md](docs/concept.md) - 아이디어와 공유 소셜 레이어
- [docs/rules.md](docs/rules.md) - 모든 기본 규칙과 수치, 직접 규칙 작성하기
- [docs/expression.md](docs/expression.md) - LLM 경계와 adapter
- [docs/scenarios.md](docs/scenarios.md) - 시나리오 형식
- [docs/api.md](docs/api.md) - 공개 API
- [docs/cookbook.md](docs/cookbook.md) - 컴패니언 앱, 게임 NPC, 여러 사람이 있는 세계, 직접 만든 규칙 패턴 (영문)
- [docs/architecture.md](docs/architecture.md) - 내부 구조 (기여자용, 영문)
- [docs/faq.md](docs/faq.md) - 왜 LLM이 아닌 규칙인가, 왜 캐릭터당 프로세스가 아닌가, 규모 (영문)
- [docs/roadmap.md](docs/roadmap.md) - 다음 계획
- [CHANGELOG.md](CHANGELOG.md)
