# 튜토리얼: 나만의 세계 만들기

[English](tutorial.md) | 한국어

[examples/tutorial_cafe.exs](../examples/tutorial_cafe.exs)를 단계별로 따라갑니다. 끝까지 따라오면 작은 세계를 만들고, 직접 규칙을 추가하고, 두 가지 미래를 비교하고, 리포트까지 렌더링하게 됩니다. 전체 예제는 이렇게 실행합니다.

```bash
mix run examples/tutorial_cafe.exs
```

## 1. 세계 만들기

세계는 평범한 데이터입니다: 캐릭터들과 방향이 있는 관계들.

```elixir
alias Aethrion.{Character, CharacterState, Event, Pipeline, Relationship, Runtime, State}

state =
  State.new(
    characters: [
      %Character{id: "sol", name: "Sol", profile: "Owner. Remembers every regular's order.", traits: [:calm]},
      %Character{id: "ivy", name: "Ivy", profile: "Barista. Loves attention from the regulars.", traits: [:sensitive]},
      %Character{id: "tae", name: "Tae", profile: "Weekend baker. Hears all the gossip.",
                 traits: [:talkative], state: %CharacterState{loneliness: 20}}
    ],
    relationships: [
      %Relationship{from: "ivy", to: "user", affinity: 35, trust: 20},
      %Relationship{from: "sol", to: "user", affinity: 25, trust: 30},
      %Relationship{from: "tae", to: "ivy", affinity: 30, trust: 45},
      %Relationship{from: "ivy", to: "tae", affinity: 30, trust: 40}
    ]
  )
```

이미 몇 가지가 중요합니다.

- `traits`는 규칙이 읽습니다. `:sensitive`는 Ivy를 더 쉽게 질투하게, `:calm`은 Sol을 덜 질투하게, `:talkative`는 Tae가 소식을 전하게 만듭니다.
- 관계에는 방향이 있습니다. `ivy -> user`는 Ivy가 사용자를 어떻게 느끼는지입니다. `user`는 캐릭터가 아니라 행위자 id일 뿐입니다.
- Ivy는 사용자를 아끼므로(affinity 35 >= 30) 사용자가 다른 사람을 챙기는 걸 보면 질투합니다. Ivy는 Tae를 신뢰하므로(40 >= 30) 힘들 때 Tae에게 털어놓습니다.

## 2. 규칙 추가하기

규칙은 모듈입니다. `Transition`을 받아서 그 헬퍼로만 상태를 바꾸므로 모든 변화가 추적됩니다. 수치는 `params`에 두어, 세계마다 코드 없이 조정할 수 있게 합니다.

```elixir
defmodule Cafe.Rules.Tip do
  use Aethrion.Rule,
    id: :tip,
    description: "A tip makes the barista feel appreciated and earns the owner's trust.",
    params: [joy_delta: 12, owner_trust: 3]

  alias Aethrion.Transition

  @impl true
  def apply(%Transition{event: event} = transition) do
    transition
    |> Transition.adjust_character(event.to, :joy, Transition.param(transition, :joy_delta))
    |> Transition.adjust_relationship("sol", event.from, :trust, Transition.param(transition, :owner_trust))
    |> Transition.note("#{Transition.name(transition, event.to)} got a tip from #{event.from}")
  end
end
```

새 이벤트 타입에 등록합니다. 기본 규칙들은 그대로 돌고, 반응형 규칙(기분, 관계 단계, 먼저 연락하기)도 여러분의 이벤트 뒤에 실행됩니다.

```elixir
pipeline = Pipeline.append(Pipeline.default(), :tip_left, Cafe.Rules.Tip)
run = fn state, events -> Runtime.run(state, events, pipeline: pipeline) end
```

## 3. 아침 하나를 돌려보기

```elixir
{:ok, morning, steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.time_tick("11:00", hours: 2)
  ])

steps |> Enum.flat_map(& &1.log) |> Enum.each(&IO.puts/1)
```

host 이벤트 세 개가 처리된 이벤트 다섯 개로 돌아옵니다. 로그가 이유를 보여줍니다.

```txt
[State] Ivy joy +12
[Relation] Sol trust toward user +3
[Rule] Ivy got a tip from user
...
[Rule] Ivy noticed the gift to Sol
[State] Ivy jealousy +15
[Mood] Ivy neutral -> jealous
...
[Event] Ivy confides in Tae
[Scene] Ivy tells Tae about the pastry box you gave Sol.
[Event] Tae comforts Ivy
[Mood] Ivy jealous -> neutral
```

마지막 네 줄은 아무도 스크립트하지 않았습니다. Ivy는 질투했고, Tae를 신뢰했기에 털어놓았습니다. Tae는 Ivy를 아꼈기에 위로했습니다. 각 `step.trace`에는 어떤 규칙이 어떤 값을 무엇에서 무엇으로 바꿨는지가 모두 기록됩니다.

## 4. 두 가지 미래 비교하기

같은 이벤트는 항상 같은 세계를 만들기 때문에, what-if는 같은 상태에서 한 번 더 돌리는 것일 뿐입니다.

```elixir
{:ok, noticed, _steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.apology_offered("user", "ivy", "I didn't mean to leave you out.", at: "09:12"),
    Event.time_tick("11:00", hours: 2)
  ])
```

```txt
as it happened  Ivy jealousy=10 trust->user=20 confided_in_tae=true
with apology    Ivy jealousy=0 trust->user=28 confided_in_tae=false
```

남겨둘 비교라면 시나리오에 `branches`를 쓰세요([scenarios.md](scenarios.md#branches)). 리포트가 분기들을 나란히 비교해 줍니다.

## 5. 페이지로 보기

시나리오는 JSON이므로 어떤 세계든 시나리오가 될 수 있습니다. `:tip_left` 같은 커스텀 이벤트도 같은 파이프라인을 넘기면(`Scenario.from_data(data, pipeline: pipeline)`) 시나리오에서 쓸 수 있습니다. 여기서는 기본 이벤트만 사용합니다.

```elixir
{:ok, scenario} =
  Aethrion.Scenario.from_data(%{
    "name" => "Cafe morning",
    "world" => state |> State.to_data() |> Map.delete("version"),
    "events" => [
      Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"]) |> Event.to_data(),
      Event.time_tick("11:00", hours: 2) |> Event.to_data()
    ]
  })

{:ok, result} = Aethrion.Scenario.run(scenario)
path = Path.join(System.tmp_dir!(), "cafe-morning.html")
File.write!(path, Aethrion.Report.html(result))
```

`Aethrion.Report.html(result, locale: :ko)`를 쓰면 제목, 이벤트 설명, 대사까지 모두 한국어로 된 리포트가 만들어집니다.

## 6. 목소리 입히기

캐릭터의 모든 대사에는 이미 결정론적인 텍스트가 있습니다. 모델이 대신 문장을 다듬게 하려면 adapter로 출력을 렌더링하면 됩니다. 렌더링은 텍스트만 바꾸며, 세계는 어느 쪽이든 동일합니다.

```elixir
{:ok, step} = Runtime.step(morning, Event.message_sent("user", "ivy", "Your latte art made my day.", tone: :warm))

step.outputs
|> Aethrion.Expression.render(adapter: Aethrion.LLM.Anthropic)   # ANTHROPIC_API_KEY 필요
|> Enum.filter(&Aethrion.Output.expressive?/1)
|> Enum.each(&IO.puts(&1.text))
```

모델 없이 한국어 대사를 보고 싶다면 내장 한국어 템플릿을 쓰면 됩니다.

```elixir
step.outputs
|> Aethrion.Expression.render(adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko])
```

키가 없으면 adapter는 조용히 실패하고 모든 대사는 결정론적 텍스트를 그대로 씁니다. 어느 쪽이었는지는 `output.expression.status`(`:ok` 또는 `:fallback`)로 알 수 있습니다. adapter, 설정, 의도 해석 방식은 [expression.md](expression.md)를 참고하세요.

## 다음으로

- [rules.md](rules.md) - 모든 기본 규칙과 수치
- [scenarios.md](scenarios.md) - 시나리오, 분기, 튜닝, 세션 녹화
- [api.md](api.md) - 오래 실행되는 세계를 위한 supervised `Aethrion.World`
