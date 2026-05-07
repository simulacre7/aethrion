# Contributing

Aethrion is currently an early alpha project. The core goal is to keep the social simulation deterministic while allowing LLMs to act as expression layers.

## Local Workflow

```bash
mix deps.get
mix format --check-formatted
mix test
mix demo.drama
```

## Contribution Guidelines

- Keep authoritative state in the deterministic runtime.
- Do not let LLM adapters directly mutate memory, relationships, emotion, or world state.
- Prefer small, scenario-driven changes with tests.
- Keep new dependencies minimal.
- Document public event and output shapes when changing them.

## Useful Entry Points

- `Aethrion.Runtime.dispatch/2`
- `Aethrion.State.new/1`
- `mix demo.drama`
- `mix demo.interactive`

## Before Opening A PR

- Run `mix format --check-formatted`.
- Run `mix test`.
- Include a short description of the scenario or behavior being changed.
