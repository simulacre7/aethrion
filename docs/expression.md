# Expression and LLMs

> LLMs generate expression; deterministic rules drive the simulation.

Aethrion lets a language model do two narrow jobs, and structurally prevents it from doing anything else.

| Job | Direction | Module | What the model can affect |
| --- | --- | --- | --- |
| **Render** | structured output -> words | `Aethrion.Expression` | the `text` of an output |
| **Interpret** | user's free text -> proposed event | `Aethrion.Intent` | a choice from a closed set: `message` with a tone, or `apology` |

Nothing else crosses the boundary. Adapters never receive `Aethrion.State` and cannot return one.

## Render: phrasing what the rules decided

Rules decide *that* Yuna messages the user and *why* (`reason: :jealous`). Every expressive output already carries:

- `text` - a deterministic fallback line from `Aethrion.Expression.Templates`
- `memory_refs` - ids of the memories the line draws on
- `context` - an `Aethrion.Expression.Request` snapshot: speaker profile, traits and mood, the relationship toward the listener (with its `bond`), the selected memories as plain maps, display names, the fallback line, and for replies and proactive messages `since_contact` (hours since the listener last talked to the speaker; `Request.reunion?/1` says whether that is a long absence), and `now`, the simulated clock (`Request.hours_ago/2` says how old a memory is), and `sequence`, the world's event count, which varies lines between several messages in one hour. In replies and proactive messages, `names` gives the person spoken to as "you"; in scenes, the user. Replies to gifts and apologies have tone `:gift` and `:apology`, `repeats` counts how many such messages the speaker remembers, and for harsh words `goodwill` says whether the rules gave the benefit of the doubt. `Request.harshness_to_others/1` tells an adapter whether the speaker saw or heard the listener be hostile to someone else, as the templates use it.

An adapter can re-render the text from that snapshot alone:

```elixir
{:ok, state, outputs, _log} = Aethrion.dispatch(state, event)

outputs = Aethrion.Expression.render(outputs, adapter: Aethrion.LLM.Anthropic)
```

`render/2` only touches the text of expressive outputs (`:proactive_message`, `:reply`, `:character_interaction`) and adds `expression: %{status: :ok | :fallback, adapter: ...}`. If the adapter returns an error, an empty line, a line of more than 400 characters, raises, or exits, the fallback text is kept and the reason is recorded. A returned line is kept to one line (line breaks become spaces, quotes wrapping the whole line are dropped), and a silent reply (`"..."`, a character who has stopped answering) is never sent to a model (`reason: :silence`). The simulation already advanced; rendering is optional.

The prompt (`Aethrion.Expression.Prompt`) asks the model to keep the meaning of the draft line, reference only the listed memories, stay in character, and never add events, promises, or facts. For replies it also says what the rules weighed ("History: The listener has done this 3 times recently... The speaker gives the listener the benefit of the doubt..."), so a model's wording escalates or softens where the draft does.

### Why a snapshot and not the state

The snapshot is taken when the rule fires. Rendering can therefore happen later, on another process, or never, and still describe the moment correctly. It also makes the boundary checkable: the tests assert that no request contains a `State`, and that rendering leaves every non-text field untouched.

## Interpret: proposing, not deciding

When a user types free text, a model may help decide what kind of event it is:

```elixir
{:ok, event, meta} =
  Aethrion.Intent.interpret(state, "sorry I disappeared yesterday", to: "yuna",
    adapter: Aethrion.LLM.Anthropic
  )

event.type
#=> :apology_offered

{:ok, state, outputs, log} = Aethrion.dispatch(state, event)
```

- The adapter may only propose `%{intent: :message, tone: tone}` or `%{intent: :apology}`. String values are normalized; anything else is rejected.
- The event is built by the normal constructors and returned, not dispatched. It still passes validation and rules like any host event.
- On errors or invalid proposals, the deterministic keyword interpreter in `Aethrion.LLM.FakeAdapter` is used and `meta.status` is `:fallback`.

## Languages

Because rendering only changes text, language is an expression concern. The fake adapter ships Korean templates, with particles chosen from each name's final sound:

```elixir
# yuna_output: Yuna's jealous proactive message from the example above
[rendered] = Aethrion.Expression.render([yuna_output], adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko])
rendered.text
#=> "아까 Mina랑 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?"
```

`mix demo.interactive --locale ko` shows every line in both languages. With a model, pass `adapter_opts: [language: "Korean"]` to `Expression.render/2` (the demo does this for `--llm ... --locale ko`): the prompt then asks for the line in that language.

## Adapters

| Adapter | Use |
| --- | --- |
| `Aethrion.LLM.FakeAdapter` | Default. Deterministic templates and a keyword lexicon. Used by tests and demos. `adapter_opts: [locale: :ko]` renders Korean templates. |
| `Aethrion.LLM.Anthropic` | Anthropic Messages API. Default model `claude-opus-5-5` at `low` effort, with the server-side refusal fallback enabled for models that support it. |
| `Aethrion.LLM.OpenAICompatible` | Any Chat Completions server: OpenAI, vLLM, Ollama, llama.cpp server, LM Studio. |

Both network adapters use Erlang's built-in `:httpc`, so Aethrion has no HTTP dependency.

### Configuration

```bash
# Anthropic
export ANTHROPIC_API_KEY=...
export AETHRION_ANTHROPIC_MODEL=claude-opus-5-5   # optional

# OpenAI-compatible (example: local Ollama)
export AETHRION_LLM_BASE_URL=http://localhost:11434/v1
export AETHRION_LLM_MODEL=llama3.2
export AETHRION_LLM_API_KEY=...                   # optional for local servers
```

Or in application config:

```elixir
config :aethrion, Aethrion.LLM.Anthropic, model: "claude-opus-5-5", effort: "low"
config :aethrion, Aethrion.LLM.OpenAICompatible, base_url: "http://localhost:11434/v1", model: "llama3.2"
```

Or per call with `adapter_opts: [...]`. Explicit options win over config, which wins over environment variables.

Try it interactively:

```bash
mix demo.interactive --llm anthropic
mix demo.interactive --llm openai
```

### Writing an adapter

```elixir
defmodule MyApp.LLM do
  @behaviour Aethrion.LLM.Adapter

  @impl true
  def render(%Aethrion.Expression.Request{} = request, opts) do
    {system, user} = Aethrion.Expression.Prompt.render_parts(request)
    MyApp.Provider.complete(system, user, opts)   # {:ok, text} | {:error, reason}
  end

  # Optional
  @impl true
  def interpret(%Aethrion.Intent.Request{} = request, opts) do
    {system, user} = Aethrion.Expression.Prompt.intent_parts(request)

    with {:ok, text} <- MyApp.Provider.complete(system, user, opts) do
      Aethrion.Expression.Prompt.decode_json_object(text)
    end
  end
end
```

## Rendering in a long-running world

In an `Aethrion.World` (or `Aethrion.RuntimeServer`) with `:expression` configured, rendering happens asynchronously in supervised tasks:

```elixir
{Aethrion.World,
 name: :garden,
 expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000]}
```

- `dispatch/2` returns immediately with fallback text; the simulation never waits on a model.
- Subscribers receive `{:aethrion, tag, {:expressed, output}}` when a line is rendered (`tag` is the world's name for an `Aethrion.World`).
- A slow adapter is terminated at `timeout`; a crashing or killed task is isolated. Either way subscribers receive the output with `expression.status == :fallback`, and the runtime keeps running.

This is where BEAM earns its place: not to make inference faster, but to keep a long-running world responsive and correct while the slowest, least reliable part of the system sits behind a supervised boundary.
