# Aethrion

[English](README.md) | [한국어](README.ko.md)

[![CI](https://github.com/simulacre7/aethrion/actions/workflows/ci.yml/badge.svg)](https://github.com/simulacre7/aethrion/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Rules keep the story straight. Your model tells it.**

Aethrion keeps the facts of an AI role-play in deterministic rules: affinity and trust, HP and dice, who saw what, who told whom, and which ending you are heading for. Any model then narrates the result. Use it as the Custom API in RisuAI or SillyTavern, or put it behind your own chat app or game.

![One turn rerolled three times in RisuAI: the narration changes, the status window and this turn's dice rolls do not](assets/demo/swipes.gif)

<sub>One turn of the Korean campfire cast, rerolled three times in the RisuAI desktop app. The last frame unfolds "this turn's rulings" under the status window.</sub>

<sub>Pronounced ay-three-on (에이트리온). A personal project, not affiliated with RisuAI or SillyTavern. MIT licensed, early alpha.</sub>

## The Problem

Long role-play and simulation chats usually leave the state to the model: the card asks it to print a status window at the end of every reply and to remember it. That breaks in familiar ways.

- **A reroll (regenerating the reply) counts twice.** Regenerate an attack and the damage lands again. Regenerate a compliment and affinity rises again.
- **Numbers drift.** Fifty turns in, HP has quietly come back and the trust you earned is gone.
- **Characters know what they never saw.** A gift given in private is suddenly common knowledge.
- **The dice follow the model's mood.** The same blow hits once and misses the next time.

## What Aethrion Does

Aethrion reads each line the player types, applies it with rules, and hands the model the outcome as facts to narrate. The same chat always gives the same state, so:

- a reroll changes the wording, never the outcome
- an edited line is recomputed from that point on
- characters know only what they saw or were told, and pass it on to the people they trust
- the status window shows what this turn changed (`Sera · affinity 50 (+10)`)
- under it, this turn's rulings show the rules' work: how the line was read, who saw it, and every dice roll (`[d20 6+5=11 vs AC 15, miss.]`), proof that the numbers are computed, not written by the model

![The same scene rerolled three times. When the model writes the status window, its numbers change with each reroll; with Aethrion only the narration changes.](assets/demo/reroll.png)

<sub>The same scene from the Korean campfire cast, rerolled three times with the same model (the Claude Code CLI) and the same starting values. Left: a plain card where the model updates the status window. Right: Aethrion. Raw outputs: [assets/demo/reroll.json](assets/demo/reroll.json)</sub>

From a play of the bundled campfire cast, with the Claude Code CLI as the narrator. The prose is the model's; every number, and who did what, is the rules':

```txt
나:   세라, 목걸이 사 왔어. 선물이야
      …그 모습을 지켜보던 도윤은 "와, 형, 나는 육포 한 조각도 안 사 왔으면서~" 하고 낄낄 웃었지만,
      세라 쪽으로 향한 눈길은 어딘가 비뚜름했다. …
      세라 · 호감 50 · 신뢰 42   도윤 → 하린 · 호감 +3 · 신뢰 +7   도윤 → 세라 · 긴장 +8
나:   고블린 척후를 벤다
      …세라는 새벽의 신께 짧게 기도하며 네 옆구리의 상처에 다시 빛을 얹고는 곧바로 네 앞을 막아섰고, …
```

Doyun saw the necklace, so he grows jealous and sends word to Harin, who is out scouting. The gift lifts Sera's care for you just past the line where she takes the goblins' blows for you. Fight without giving it and she never does.

A real play in RisuAI's desktop app (Korean cast). The narration streams in as it is written, and the status window comes last:

<img src="assets/demo/risuai-campfire.jpg" alt="The campfire cast in RisuAI: narration, then a status window with this turn's changes in brackets" width="720">

## Who It Is For

| You are | Start here |
| --- | --- |
| A RisuAI or SillyTavern player or card maker | [Use Aethrion as a Custom API](docs/risuai.md): the status window comes with it, and your existing cards can be imported |
| Building a character chat app or a game | [Run it as an HTTP server](docs/embedding.md#chat-apps-and-games): one world per user, from any language |
| An Elixir developer | [Embed the runtime](docs/embedding.md#embedding-aethrion) and write your own rules |

## Quick Start

**With Docker, no Elixir needed.** It works with RisuAI's desktop app or SillyTavern (RisuAI's web app cannot reach a server on your computer):

```bash
git clone https://github.com/simulacre7/aethrion && cd aethrion
cp .env.example .env     # an access password, and your model: OpenRouter, the Claude API, Ollama, ...
docker compose up -d
```

Then open http://localhost:4848 and click **RisuAI**: it shows the values to copy and downloads the character card. Point RisuAI's Custom API at `http://localhost:4848/v1`, with the access password as its key ([step by step](docs/risuai.md#the-quick-way-docker)). Tested with RisuAI's desktop app 2026.8.250 on macOS and SillyTavern 1.19.0.

**With Elixir** (1.19+ and Erlang/OTP 28+; `brew install elixir` on macOS). No database or vector store is needed, and a model is optional.

```bash
mix deps.get
mix demo.drama      # two events in, a small social drama out; no model needed
mix aethrion.serve --cast priv/casts/campfire_en.json --llm claude   # campfire.json --locale ko for Korean
```

Then open http://localhost:4848 to chat, or http://localhost:4848/editor to edit the cast, or point RisuAI at `http://localhost:4848/v1` ([setup](docs/risuai.md)).

`--llm` picks the narrator:

- `claude` or `codex`: the CLI on this machine, as signed in, with no key
- `ollama`, `lmstudio`, or `llamacpp`: a local model
- `anthropic`: the Claude API
- `openai --base-url ...`: any OpenAI-compatible API

Without `--llm`, keyword rules and templates stand in. That is for tests and development, not what play looks like.

## What You Can Build

- **Characters who affect each other.** A gift makes someone else jealous, a confidence spreads as a rumor, and friends comfort each other while you are away. ([tour](docs/tour.md))
- **Reputation and bonds.** How you treat one character reaches the others. Relationships have names that change along the way: strained, friendly, close. ([tour](docs/tour.md#word-gets-around))
- **Endings by the numbers.** Raising-sim stats and activities, endings with a hint of what is still missing, and messenger-style bond stories. ([stories](docs/stories.md))
- **Fights.** HP, guarding, healing, and the d20 rules of the D&D 5e SRD. Companions fight beside you only if they trust you. ([stories](docs/stories.md#endings-and-fights))
- **A cast editor and route simulator** at `/editor`. Write a route the way a player chats and see which ending it reaches. ([stories](docs/stories.md#authoring-worlds))
- **Bundled casts**, most in Korean:
  - `campfire_en`: the campfire party in English
  - `summer`: a raising sim
  - `quest`: a hunt for the wolf king
  - `den`: a D&D wolf den
  - `academy`: a messenger academy
  - `campfire`: a party by the fire

## How It Works

```txt
player's line -> read as an event -> rules -> new state + a trace of every change
                                                  |
                                     the model narrates the outcome (text only)
```

A model does two things, and neither changes the state directly. It reads what a line means, by picking from a closed set of choices that the rules then check. It also writes how the outcome sounds. If it fails or times out, fallback text is used and the world still moves on. See [the LLM boundary](docs/embedding.md#the-llm-boundary).

## Status

Aethrion is **early alpha** (v0.2). The API may change; see the [changelog](CHANGELOG.md). It is not production-ready. Feedback is welcome, especially from people who play long role-play chats or build character apps: [open an issue](https://github.com/simulacre7/aethrion/issues).

## Documentation

- [docs/risuai.md](docs/risuai.md): Aethrion as the model in RisuAI or SillyTavern
- [docs/tour.md](docs/tour.md): the simulation with real output (cascades, reputation, scenarios, the interactive demo)
- [docs/stories.md](docs/stories.md): endings, fights, bond stories, the cast editor, how chat lines are read
- [docs/embedding.md](docs/embedding.md): Aethrion in an Elixir app, the HTTP API, the LLM boundary, architecture
- [docs/tutorial.md](docs/tutorial.md): build a world of your own in a few minutes
- [notebooks/tour.livemd](notebooks/tour.livemd): the same ideas as a Livebook notebook
- [docs/concept.md](docs/concept.md): the idea and the shared social layer
- [docs/rules.md](docs/rules.md): every built-in rule, its numbers, and how to write your own
- [docs/expression.md](docs/expression.md): the LLM boundary and adapters
- [docs/scenarios.md](docs/scenarios.md): the scenario format
- [docs/api.md](docs/api.md): the public API
- [docs/cookbook.md](docs/cookbook.md): patterns for companion apps, game NPCs, multiplayer worlds, custom rules
- [docs/architecture.md](docs/architecture.md): how it is built, for contributors
- [docs/faq.md](docs/faq.md): why rules and not the LLM, why not a process per character, scale
- [docs/roadmap.md](docs/roadmap.md): what's next
- [CHANGELOG.md](CHANGELOG.md)
