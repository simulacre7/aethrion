# Contributing

Aethrion is currently an early alpha project. The core goal is to keep the social simulation deterministic while allowing LLMs to act as expression layers.

## Local Workflow

```bash
mix deps.get
mix check                     # format, warnings, tests, and every scenario
MIX_ENV=dev mix dialyzer      # typespecs (CI runs it too)
mix demo.drama
```

## Contribution Guidelines

- Keep authoritative state in the deterministic runtime.
- Do not let LLM adapters directly mutate memory, relationships, emotion, or world state.
- Change state inside rules only through `Aethrion.Transition` helpers, so every change is traced.
- Keep rules pure: no I/O, wall clock, or randomness. Iterate characters with `State.sorted_characters/1`.
- Declare tunable numbers as rule `params` instead of module attributes.
- Prefer small, scenario-driven changes. A behavior change usually deserves a scenario in `priv/scenarios/` as well as unit tests.
- Keep new dependencies minimal. Runtime dependencies are currently just `jason`.
- Document public event and output shapes when changing them (`docs/api.md`, `docs/rules.md`).
- Give every new expressive line an English and a Korean template (`Aethrion.Expression.Templates`, `...Templates.Ko`); the tests render every bundled scenario in Korean.
- The READMEs quote real demo and scenario output, and the tests check it. If a change alters those lines, update the READMEs.
- Convert untrusted strings to atoms only through explicit maps or `String.to_existing_atom/1` after `Aethrion.Pipeline.ensure_loaded/1`; CI runs each scenario in a fresh VM to catch load-order bugs.

See [docs/architecture.md](docs/architecture.md) for how the pieces fit together.

## Layout

- `lib/` - the library, including the `mix aethrion.*` tasks that ship with it
- `dev/` - the `mix demo.*` tasks; compiled in dev and test only, not packaged
- `priv/scenarios/` - bundled scenarios, run by the test suite
- `examples/`, `bench/`, `scripts/` - runnable examples, the benchmark, demo recording

## Useful Entry Points

- `Aethrion.Runtime.step/3` and `Aethrion.Pipeline`
- `Aethrion.Transition` and `Aethrion.Rule`
- `mix aethrion.rules` - the pipeline and every parameter
- `mix demo.interactive` - `why <character>` explains any state
- `mix aethrion.report <scenario>` - see a scenario as a page

## Performance

`bench/dispatch.exs` builds a deterministic world of N characters and reports dispatch timings:

```bash
mix run bench/dispatch.exs 200 96
```

Rules run on every event, so avoid per-memory work that rescans all memories (quadratic in world size). Index once per rule application, or use `Transition.map_memories/3` for bulk memory updates.

## Before Opening A PR

- Run `mix check`.
- Optionally run `MIX_ENV=dev mix dialyzer` (CI runs it).
- Include a short description of the scenario or behavior being changed.
