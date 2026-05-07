# Aethrion MVP

The v0 goal is to prove that a small social drama can emerge from deterministic state transitions.

## Scope

The first demo includes:

- 3 characters: Mina, Yuna, Haru
- relationship graph
- memory store
- deterministic rules
- proactive messaging
- fake LLM adapter
- CLI scenario demo
- branched scenario demo

Out of scope for v0:

- Phoenix or web UI
- database persistence
- vector search
- distributed runtime
- real LLM integration
- generic rule DSL

## Demo Scenario

```txt
1. The user gives Mina a flower.
2. Mina's affinity toward the user increases.
3. Mina stores a memory about the gift.
4. Yuna notices the gift.
5. Yuna's jealousy and tension increase.
6. Time passes.
7. Yuna becomes lonely enough to proactively message the user.
```

Run it with:

```bash
mix demo.drama
```

## Branch Scenario

The branch demo shows the same social setup diverging after the user's next choice:

```txt
Shared setup:
1. The user gives Mina a flower.
2. Yuna observes it and becomes jealous.

Branch A:
3. The user ignores Yuna.
4. Time passes.
5. Yuna proactively messages the user.

Branch B:
3. The user apologizes to Yuna.
4. Yuna stores a reconciliation memory.
5. Yuna's jealousy decreases and trust toward the user increases.
6. Time passes without a jealous proactive message.
```

Run it with:

```bash
mix demo.branches
```

## Acceptance Criteria

- The same event sequence always produces the same final state and structured outputs.
- The fake LLM can be replaced without changing authoritative simulation state.
- The demo logs show why each relationship, memory, and proactive output happened.
- Tests cover rule behavior, scenario behavior, and basic invariants.
