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

## 1. Run Aethrion

```bash
mix aethrion.serve --cast priv/casts/den.json --llm claude --locale ko --port 4848
```

`--llm` is the model that narrates and reads lines: `anthropic`, `openai`, `ollama`, `lmstudio`, `llamacpp`, `claude` (the Claude Code CLI), or `codex`. Without it, `/v1` answers 400: there is no model to narrate.

## 2. Install RisuAI

The tested setup is a self-hosted RisuAI (Docker); the desktop app sends the same requests. The web version (risuai.xyz) sends most requests through RisuAI's servers, but calls `localhost` and `127.0.0.1` from the browser directly, so it can reach `http://localhost:4848/v1`. For that, run Aethrion with `--token` and put the token in as the key: without a token, Aethrion sends no CORS headers to other origins, since any site the user opens could otherwise use the server and the model behind it. Answering the browser's preflight (OPTIONS) needs Erlang/OTP 29 or later (older `:httpd` refuses OPTIONS with 501). The browser may also ask before allowing local network access, and this path is untested.

```bash
git clone https://github.com/kwaroran/RisuAI
cd RisuAI
docker compose up -d     # http://localhost:6001
```

On first open it asks for a password for this server. `docker compose down` in the same folder stops it.

From RisuAI in Docker, Aethrion on the host is `http://host.docker.internal:4848/v1` (Docker Desktop). On Linux, add `extra_hosts: ["host.docker.internal:host-gateway"]` to `docker-compose.yml` and run Aethrion with `--bind 0.0.0.0 --token SECRET`.

## 3. Set The Model

In Settings → Bot Settings:

| field | value |
| --- | --- |
| Model | `Custom API` |
| URL | `http://host.docker.internal:4848/v1` (desktop app: `http://localhost:4848/v1`) |
| Key/Password | the `--token` or `AETHRION_TOKEN` value (blank when none) |
| Request Model | `aethrion:sera` (the player talks to Sera) |
| Format | `OpenAI Compatible` |

Request model names (listed by `GET /v1/models`; foes are not listed):

- `aethrion:CHARACTER_ID`: lines are read as said to that character.
- `aethrion`: the first character who is not a foe.
- `aethrion-plain:CHARACTER_ID`: narration without the status block. Without it there are no checkpoints, so a trimmed chat is computed from what is left.

**Do not set the auxiliary model to Custom API.** RisuAI hands summaries, emotion images, and translation to the auxiliary model; sent to Aethrion, the text to summarize would be read as the player's words.

## 4. Character Cards

Export an Aethrion cast as a narrator card and import it into RisuAI:

```bash
curl -s 'localhost:4848/casts/card?name=Wolf%20Den' -o den.json
```

Import it with Import Character. The card holds the cast, the first message (the `greeting` of a character who is not a foe), the lorebook, and the status window's regex script, so the status window works with nothing else to set.

To keep using a card you already have, import just the status module: Settings → Modules → Import Module, open [`priv/risu/aethrion-status.json`](../priv/risu/aethrion-status.json), and enable it for that card. It is one display-only regex for the `<aethrion-status>` block.

The other way, a community card becomes an Aethrion cast to add numbers and endings to:

```bash
mix aethrion.card mycard.png --player Teacher --out casts/my.json
```

Description, personality, and scenario become the profile; example messages the voice; the first message the greeting; the lorebook world notes. Cards hold no game numbers: add stats, endings, and bond stories in `/editor`. RisuAI regex and trigger scripts, and lore built from macros (`{{getvar}}` and the like), are not run; the import says what it left out.

## 5. Play

- **Reroll:** the same history, the same outcome; only the narration is new.
- **Edit:** the last line or an earlier one, everything from the edited line is recomputed.
- **Long chats:** trimmed history goes on from the checkpoints. Deleting a reply's status block loses that turn's checkpoint; the replay starts from the one before.
- **Continue:** not a new turn: the rules apply nothing again, and the continuation gets no second status block.
- **Lines in a row:** several lines sent before a reply all make this turn, and the model hears about all of them.
- **Another character:** switching the request model to `aethrion:doyun` goes on from the checkpoints so far; lines from then on are read as said to Doyun.
- **After editing the cast:** checkpoints remember their cast, so a changed cast is computed afresh from the chat.

## Limits

- Replies come whole; with `stream: true` they come as one server-sent event.
- A CLI model (`--llm claude`) takes about 10-15 s a turn; API models are faster.
- One request replays at most 300 lines; a longer chat without checkpoints is a 400 (`too_many_lines`).
- Group chats are not supported yet; the model name says who the player talks to.
- Checkpoints store the whole world (without the cast's lore) every turn, so the file grows with use. Deleting it is safe: the state is then recomputed from the transcript.

## SillyTavern

SillyTavern connects the same way: API Chat Completion → Custom (OpenAI-compatible), endpoint `http://localhost:4848/v1`, model `aethrion:sera`. Draw the status window with a script in the Regex extension:

- Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)<\/aethrion-status>/g`
- Replace With: `<div style="white-space:pre-line">$1</div>`
- Affects: AI Output; Other Options: Alter Chat Display

The SillyTavern side follows the OpenAI-compatible request format and has not been tested as RisuAI has.
