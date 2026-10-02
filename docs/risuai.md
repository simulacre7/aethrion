# Aethrion As A Model In RisuAI

Point RisuAI's (or SillyTavern's) "Custom API" at Aethrion, and what the player writes is read and applied by Aethrion's rules before a model narrates the result. Affinity and trust, hp, dice, and endings come from the rules, not from the model.

[한국어](risuai.ko.md)

## Why

Simulation and RPG cards shared in the RisuAI community mostly leave the state to the model: the prompt asks it to print a status window at the end of every reply, or chat variables and trigger scripts keep the numbers. The same problems keep coming up:

- **A reroll applies a move twice.** Regenerating an attack deals the damage again, or raises affinity again.
- **Models drift.** Over a long chat, hp quietly comes back, or numbers set earlier are forgotten.
- **Outcomes follow the model's mood.** The same move hits one time and misses the next.

Aethrion recomputes the state from the transcript, deterministically: the same history gives the same result, so a reroll applies once, and an edited line is recomputed as written.

## How It Works

```txt
RisuAI ──(the whole chat)──▶ Aethrion /v1/chat/completions
                              1. replays the player's lines into a world (readings are cached)
                              2. adds a note: what the rules decided this turn, and where things stand
                              3. the model (--llm) narrates from the card, lorebook, history, and note
RisuAI ◀──(narration + <aethrion-status>)──┘
```

- Chat apps send the whole chat every time, with no chat id, so the state follows the transcript. A reroll sends the history without the last reply and gets the same result; an edited line is recomputed as written.
- The `<aethrion-status id="...">` block at the end of a reply is drawn as a status window and taken out of the history on the next request. Its id is a checkpoint: the world after that turn. When RisuAI trims the oldest messages to fit its context, the replay starts from the checkpoints still in the chat, so the state does not rewind.
- What each line was read as is cached (`bridge-readings.jsonl` under `--data`, `tmp/worlds` by default), so only new lines go to the interpreting model. Checkpoints are kept beside it in `bridge-checkpoints.jsonl`.

## The Quick Way: Docker

No Elixir needed, and it works with RisuAI's desktop app or SillyTavern. The RisuAI web app (risuai.xyz) cannot reach a server on your computer ([why](#2-install-risuai)).

```bash
git clone https://github.com/simulacre7/aethrion && cd aethrion
cp .env.example .env     # set AETHRION_TOKEN, and your model's address and key
docker compose up -d
```

In `.env`:

- **`AETHRION_TOKEN`** is required. It is an access password for your Aethrion, not a model token, and costs nothing. Use any long random string, such as the output of `openssl rand -hex 16`. RisuAI sends it with every request, and it keeps other websites open in your browser from using the server and the model behind it.
- **The narrating model** is your choice: any OpenAI-compatible API (OpenRouter, for one), the Claude API, or a model served on this computer (Ollama, LM Studio, llama.cpp). `.env.example` shows each.
- **`AETHRION_CAST`** picks the cast. The default is `campfire`.

Then:

1. In RisuAI, set up the model as in [section 3](#3-set-the-model), with the URL `http://localhost:4848/v1` and your `AETHRION_TOKEN` as the Key/Password.
2. Get the card: open http://localhost:4848, put your `AETHRION_TOKEN` in Token, click **RisuAI**, then **Download the RisuAI card**. The same panel shows the URL and request model to copy. Import the card as in [section 4](#4-character-cards). By drag and drop, in the macOS desktop app.

`docker compose logs aethrion` shows what Aethrion is doing, and `docker compose down` stops it. The port is published only to this computer.

The rest of this page sets things up by hand, with Elixir installed.

## 1. Run Aethrion

```bash
export AETHRION_TOKEN=$(openssl rand -hex 16)   # the access password; put it in RisuAI's Key/Password
mix aethrion.serve --cast priv/casts/den.json --llm claude --locale ko --port 4848
```

`--llm` is the model that narrates and reads lines: `anthropic`, `openai`, `ollama`, `lmstudio`, `llamacpp`, `claude` (the Claude Code CLI), or `codex`. Without it, `/v1` answers 400: there is no model to narrate.

## 2. Install RisuAI

Use the **desktop app** ([releases](https://github.com/kwaroran/RisuAI/releases)): it calls `http://localhost:4848/v1` directly.

- **The web app (risuai.xyz) cannot reach Aethrion on your computer.** It refuses local addresses itself (localhost, 127.0.0.1, LAN addresses, `.local` names) with "You are trying local request on web version", and sends other addresses through RisuAI's own servers, which cannot see your computer.
- **The access password.** Run Aethrion with a token (`--token`, or `AETHRION_TOKEN`) and put the same value in RisuAI's Key/Password field. The token is a password for your Aethrion server, not a model token: it costs nothing. Without one, Aethrion answers only requests naming this machine (`localhost`, `127.0.0.1`, `host.docker.internal`, ...) and refuses other origins (403), since any site open in a browser could otherwise use the server and the model behind it.
- **A self-hosted RisuAI** also works, since its server makes the request. The official image (`ghcr.io/kwaroran/risuai`) is built without `VITE_RISU_LEGAL_CONFIGURED`, though, so it stops at a notice about legal documents. RisuAI's notice says that a personal self-hosted instance may set it to `TRUE` and build the image itself. Read the notice and decide for yourself.

```bash
git clone https://github.com/kwaroran/RisuAI
cd RisuAI
docker compose up -d     # http://localhost:6001
```

On first open it asks for a password for this server. `docker compose down` in the same folder stops it.

From RisuAI in Docker, Aethrion on the host is `http://host.docker.internal:4848/v1` (Docker Desktop). On Linux, add `extra_hosts: ["host.docker.internal:host-gateway"]` to `docker-compose.yml` and run Aethrion with `--bind 0.0.0.0 --token SECRET`.

## 3. Set The Model

In Settings → Chat Bot → Model:

| field | value |
| --- | --- |
| Model | `Custom API` |
| URL | `http://localhost:4848/v1` (a RisuAI running in Docker: `http://host.docker.internal:4848/v1`) |
| Key/Password | the access password (the `--token` or `AETHRION_TOKEN` value) |
| Request Model | `aethrion` (talks to whoever greets on the card; `aethrion:sera` names one) |
| Format | `OpenAI Compatible` |

Request model names (listed by `GET /v1/models`; foes are not listed):

- `aethrion:CHARACTER_ID`: lines are read as said to that character at first; calling another by name moves the talk to them (section 6).
- `aethrion`: the character who greets the player on the cast's card (the first who is not a foe and has a `greeting`), else the first who is not a foe.
- `aethrion-plain:CHARACTER_ID`: narration without the status block. Replies then carry no checkpoint ids: an untrimmed chat finds its checkpoints again from its lines, but a trimmed one is computed from what is left, and right after a change of character it may not tell itself apart from another chat on the server that began with the same words to someone else. `aethrion`, with status blocks, is exact.

**Do not set the auxiliary model to Custom API.** RisuAI hands summaries, emotion images, and translation to the auxiliary model; sent to Aethrion, the text to summarize would be read as the player's words.

## 4. Character Cards

Export an Aethrion cast as a narrator card and import it into RisuAI. Open http://localhost:4848, put the access password in Token, and click **RisuAI**, then **Download the RisuAI card**. From a terminal:

```bash
curl -s -H "Authorization: Bearer $AETHRION_TOKEN" 'localhost:4848/casts/card?name=Wolf%20Den' -o den.json
```

Import it with Import Character. If that opens no file picker (it does not in the macOS desktop app), drag the file onto the RisuAI window instead. The card holds the cast, the first message (the `greeting` of a character who is not a foe), the lorebook, and the status window's regex script, so the status window works with nothing else to set.

To keep using a card you already have, import just the status module: Settings → Modules → Import Module, open [`priv/risu/aethrion-status.json`](../priv/risu/aethrion-status.json), and enable it for that card. It is one display-only regex for the `<aethrion-status>` block.

The other way, a community card becomes an Aethrion cast to add numbers and endings to:

```bash
mix aethrion.card mycard.png --player Teacher --out casts/my.json
```

Description, personality, and scenario become the profile; example messages the voice; the first message the greeting; the lorebook world notes. Cards hold no game numbers: add stats, endings, and bond stories in `/editor`. RisuAI regex and trigger scripts, and lore built from macros (`{{getvar}}` and the like), are not run; the import says what it left out.

## 5. Play

The status window after attacking a goblin in the campfire cast, the turn after giving Sera the necklace. In brackets: what this turn changed.

```txt
You: 고블린 척후를 벤다   (I strike the goblin scout)

(the model's narration)
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

The scout is down, and Doyun, fighting beside you, took its blow. Doyun and Sera, who fought with you, trust you a little more (호감 is affinity, 신뢰 trust).

- **Reroll:** the same history, the same outcome; only the narration is new.
- **Edit:** the last line or an earlier one, everything from the edited line is recomputed.
- **Long chats:** trimmed history goes on from the checkpoints. Deleting a reply's status block loses that turn's checkpoint; the replay starts from the one before.
- **Continue:** not a new turn: the rules apply nothing again, and the continuation gets no second status block.
- **Lines in a row:** several lines sent before a reply all make this turn, and the model hears about all of them.
- **Another character:** switching the request model to `aethrion:doyun` goes on from the checkpoints so far; lines from then on are read as said to Doyun.
- **After editing the cast:** checkpoints remember their cast, so a changed cast is computed afresh from the chat.

## 6. The Whole Cast

One narrator card talks with every character in the cast; RisuAI's group chat is not used.

- **Whom a line is for:** a line that starts by calling someone ("도윤, 왜 그렇게 조용해?", "하린아 고마워") is said to them; a line without a name goes to whoever was spoken to last. Someone given a gift or an apology is next in line too.
- **Who sees it:** the characters there (not foes, not down, not `away`) witness what the player says and gives, so a gift for one can make another jealous, and harsh words disappoint the bystanders.
- **Time and word getting around:** with `turn_hours` in the cast's story, that much time passes each turn. Meanwhile a character who is jealous or lonely confides in their most trusted friend, and that is how news spreads. An `away` stat is the hours until someone is back: it counts down, and at 0 they return.
- **What the model hears:** who saw it, who was away and does not know, who told whom, how the characters now feel about each other, and who came back, as facts. The status window shows the changes between characters, such as `도윤 → 세라 · 긴장 +8`.
- **In fights too:** a companion who cares about someone in danger takes the blow for them, those who loved someone who falls are enraged, a companion who trusts the player deeply attacks beside them with advantage, and a healer passes over someone they resent. A companion who is away does not fight.

`priv/casts/campfire.json` (모닥불) shows all of it: night at camp, Sera and Doyun by the fire, Harin out scouting until three hours from now, goblins in the bushes.

```bash
mix aethrion.serve --cast priv/casts/campfire.json --llm claude --locale ko --port 4848
curl -s -H "Authorization: Bearer $AETHRION_TOKEN" 'localhost:4848/casts/card?name=Campfire' -o campfire.json
```

Give Sera a necklace and Doyun, who sees it, grows jealous and sends word to Harin, while Sera comes to care enough to take the goblins' blows for the player. Fight without the gift and she never does.

## Good To Know, And Limits

- **Streaming:** turn on Response Streaming in RisuAI (Settings → Chat Bot) to see the narration as it is written. The status block comes last. An OpenAI-compatible API, the Claude API, and the Claude Code CLI stream; the Codex CLI sends the reply whole.
- **Time:** a new line is first read by the model (a few seconds; a line already read is cached, so a reroll skips this), then narrated. With the Claude Code CLI a turn takes 15-40 s, depending on how long the narration is. API models are faster.
- **Cost:** each new line costs two model calls, one to read it and one to narrate. `--read-model NAME` (or `AETHRION_READ_MODEL`) reads with a smaller model of the same API. With the Claude Code CLI it does not make a turn faster, since starting the CLI takes most of a reading.
- **The server console** shows one line per turn: the line, the time the rules and the model took, and whether the model answered. If nothing shows up, RisuAI did not reach Aethrion.
- One request replays at most 300 lines; a longer chat without checkpoints is a 400 (`too_many_lines`).
- RisuAI's group chat is not used: one narrator card talks with the whole cast (section 6).
- Checkpoints store the whole world (without the cast's lore) every turn, so the file grows with use. Deleting it is safe: the state is then recomputed from the transcript.

## SillyTavern

SillyTavern connects the same way: API Chat Completion → Custom (OpenAI-compatible), endpoint `http://localhost:4848/v1`, model `aethrion`. Draw the status window with a script in the Regex extension:

- Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)<\/aethrion-status>/g`
- Replace With: `<div style="white-space:pre-line">$1</div>`
- Affects: AI Output; Other Options: Alter Chat Display

The SillyTavern side follows the OpenAI-compatible request format and has not been tested as RisuAI has.
