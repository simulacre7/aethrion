# Aethrion 둘러보기

[English](tour.md)

규칙이 하는 일을 실제 출력으로 보여 줍니다. 서로를 보고, 털어놓고, 소문을 옮기고, 위로하는 캐릭터들, 세부 기억보다 오래 남는 평판, 그리고 "왜?"를 물어보는 도구까지.

## 직접 실행해 보기

여기 나오는 것은 모두 모델 없이 돌아갑니다:

```bash
mix deps.get
mix demo.drama                 # host 이벤트 2개와 그로부터 이어지는 모든 일
mix demo.interactive --locale ko   # 캐릭터와 대화하고(한국어 입력 가능), 왜 그렇게 느끼는지 물어보기 (--no-status로 출력 줄이기)
mix aethrion.scenario --all    # 번들 시나리오 실행 및 기대값 검증
mix aethrion.report priv/scenarios/01_the_flower.json --locale ko   # tmp/01_the_flower.ko.html에 한국어 HTML 리포트 생성
```

처음이라면 [튜토리얼](tutorial.ko.md)에서 몇 분 만에 세계, 규칙, what-if를 만들어 볼 수 있습니다. 아래는 interactive demo를 녹화한 세션입니다(실제 출력, [plain-text transcript](../assets/demo/interactive-demo.txt)):

![Aethrion interactive demo](../assets/demo/interactive-demo-readable.svg)

실제 모델과 함께 실행하려면(선택 사항이며, 모델이 없어도 시뮬레이션 결과는 같습니다): `ANTHROPIC_API_KEY=... mix demo.interactive --llm anthropic`.

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

모든 규칙과 수치는 [docs/rules.md](rules.md)에 있습니다.

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

<img src="../assets/report/the-flower.ko.png" alt="Aethrion 시나리오 리포트: 요약, 등장인물, 감정 변화, 관계 그래프, 타임라인" width="720">

번들 시나리오: the flower, the apology, words matter(톤), rumor mill(신뢰 그래프를 따라 퍼지는 소문), long silence(외로움과 희미해지는 기억), small town(같은 규칙, 다른 튜닝), crossroads(한 순간, 네 갈래의 분기를 나란히 비교), old friends(대화가 희미해지며 오래 남는 인상으로 통합됨), benefit of the doubt(같은 날카로운 말도 관계 이력에 따라 다르게 받아들여짐), company(사용자가 없는 동안 친구끼리 곁을 지켜 줌), two regulars(두 사람이 있을 때 메시지가 알맞은 사람에게 감), word gets around(친구 앞에서 한 모진 말이 평판이 됨), slowly closer(일주일간의 작은 친절로 관계 단계가 한 칸씩 가까워짐), 하숙집(한국어 캐스트, 한국어 리포트(`mix aethrion.report ... --locale ko`)로 보기 좋음). [docs/scenarios.md](scenarios.md)를 참고하세요.

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
