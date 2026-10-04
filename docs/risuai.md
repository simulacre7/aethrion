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
- **`AETHRION_CAST`** picks the cast. The default is `campfire`, in Korean. For the English campfire, set `AETHRION_CAST=campfire_en` and `AETHRION_LOCALE=en`.
- **`AETHRION_CAST_FILE`** plays a cast of your own. Edit one at http://localhost:4848/editor, download its JSON into the `casts` folder, set `AETHRION_CAST_FILE=/casts/my.json`, and run `docker compose up -d` again.

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
- `aethrion-auto`: instead of the server's cast, the card in the request is read and used as the cast ([Keep The Card You Already Use](#keep-the-card-you-already-use)). `aethrion-auto-plain` answers without the status block.

**Do not set the auxiliary model to Custom API.** RisuAI hands summaries, emotion images, and translation to the auxiliary model; sent to Aethrion, the text to summarize would be read as the player's words.

## 4. Character Cards

Export an Aethrion cast as a narrator card and import it into RisuAI. Open http://localhost:4848, put the access password in Token, and click **RisuAI**, then **Download the RisuAI card**. From a terminal:

```bash
curl -s -H "Authorization: Bearer $AETHRION_TOKEN" 'localhost:4848/casts/card?name=Wolf%20Den' -o den.json
```

Import it with Import Character. If that opens no file picker (it does not in the macOS desktop app), drag the file onto the RisuAI window instead. The card holds the cast, the first message (the `greeting` of a character who is not a foe), the lorebook, and the status window's regex script, so the status window works with nothing else to set.

To keep using a card you already have, import just the status module: in Settings → Modules, use the import button under the list to open [`priv/risu/aethrion-status.json`](../priv/risu/aethrion-status.json) (dropping this file on the window fails: RisuAI tries to read it as a card). Then click the globe next to the module's name to turn it on for every chat, or enable it for that card only. It is one display-only regex for the `<aethrion-status>` block.

The other way, a community card becomes an Aethrion cast to add numbers and endings to:

```bash
mix aethrion.card mycard.png --player Teacher --out casts/my.json
```

Description, personality, and scenario become the profile; example messages the voice; the first message the greeting; the lorebook world notes. Cards hold no game numbers: add stats, endings, and bond stories in `/editor`. RisuAI regex and trigger scripts, and lore built from macros (`{{getvar}}` and the like), are not run; the import says what it left out.

## Keep The Card You Already Use

A card can be played as it is in RisuAI, without importing it into Aethrion. In [3. Set The Model](#3-set-the-model), set the request model to `aethrion-auto`. Whatever cast the server was started with, the card that comes in the request is the cast.

- **Reading the card.** On a new card's first reply the model reads the card's prompt and first message once, and settles who the player meets (six at most) and each one's affinity and trust at the start. That is kept, so the same card is not read again. The server's console prints `Aethrion read a new card: ...`.
- **Finding the chat again.** RisuAI's prompt changes from turn to turn as lorebook entries come and go. So the cast is found by the checkpoint in a reply's status block, not by the prompt, and before the first reply by the card's first message.
- **People coming and going.** The model ends each reply with a line naming who is with the player now. Aethrion takes that line out of the reply, keeps it in the status block's opening tag (it is not shown), and reads the next line in that scene. Someone new joins the cast with affinity 0 and trust 0; someone not named is away and does not see what the player does. The status window lists who is there now. The cast grows to sixteen people at most.
- **The card's status window.** A card that has the model print a status window with every reply (level, HP, money, a date) keeps it, and from the second reply on the rules keep it, not the model. The model is asked only for what changed (`HP: -12`, `Item: +mana stone × 2`). Aethrion applies that to the window of the reply before and writes the window back in the card's own format, so the card's display scripts still draw it. A number moves by what was said, a pair such as `96 / 140` stays within its maximum, a list keeps whatever nobody mentioned, and a field nobody named stays as it was. This turn's rulings say what was recorded (`기록 · HP 121 / 130 → 109 / 130 · Item +마정석 × 2`) and what was refused. Nothing is kept on the server for this: the window in the last reply is the ledger. So a window you correct by hand in the chat app is the one the next turn goes on from.
- **Rerolls.** What a turn changes in the window is settled by its first answer. A reroll is told those changes as facts and tells the turn again: the story differs, the window comes out the same. To have a turn judged anew, change your line.
- **The card's arithmetic.** Where the card states arithmetic for its window ("Max HP +10 per point of Vigor", "100 × 1.15^(Level − 1) = Max EXP", "Trust changes by at most 2 a turn"), the model that reads the card writes it down once as rules, each with the sentence of the card it comes from. A rule is checked before it is used: against the examples of the window the card itself gives (a rule they contradict is dropped, or kept without a base the card does not have), and against its sentence (a rule whose sentence or numbers are not in the card is dropped). From then on the rules work those out: maximums, a level-up with what is left over carried on, the points a level gives, ranges, and how far a number may move in one turn (`규칙 · Level 1 → 2 · EXP 114 / 100 → 14 / 115 · Stat Point 0 → 5`). Where the card says that a pool of points is what raises other numbers (stat points for stats) and names no price, the reader notes the pool and what it raises, and the price is one point each, held in a turn that has points and waived in a turn with none, since such a card often lets a stat rise by training too (`when Strength rises: Stat Point -= if(Stat Point > 0 or Stat Point.before > 0, 1, 0)`): without it a model raises the stat and forgets the points, and the same points are spent again. A card is read three times, at once, since one reading may leave a rule out, take the window's opening text wrongly, or miss the window: the window's opening and closing text are what most readings say, and the rules are those the card bears out, of the three readings together. The console prints the rules it took with `Aethrion read a new card: ...`. A small model narrates well and reads a card's rules less surely: `--card-model NAME` (or `AETHRION_CARD_MODEL`) has a stronger model of the same API read each card, once.
- **Looking over what was read.** http://localhost:4848/cards lists the cards read so far: who is in each, the texts that open and close its status window, and its rules. Set right what the model got wrong (a rule is one line; the page says how to write one), turn the ledger off for a card whose window should stay the model's, or have a card read again. Changes hold from the next turn.
- **Aethrion's status window.** Without the status module, the numbers and this turn's rulings show as plain lines at the end of the reply. For the box and the fold, import the status module from [4. Character Cards](#4-character-cards) and turn it on.
- **Letter case.** On macOS the settings field may rewrite the name as `Aethrion-auto`. Case does not matter.

Checked in the RisuAI desktop app 2026.8.250 with a raising-sim card that has its own status window and assets and with an ensemble card (rerolls included), and in SillyTavern 1.19.0 with an ensemble card. The ledger was checked in SillyTavern 1.19.0 with the example card under [`examples/cards`](../examples/cards) (the window in the card's format, the record under it, streaming, and a swipe, which keeps the window), and through the API with twelve community cards, sending what RisuAI sends. In the RisuAI app itself the ledger has not been checked yet. Limits:

- A line said on the turn someone first appears is not read as said to them; from the turn after the model has named them, it is. A card with no fixed characters starts with no one.
- Who comes in depends on the line the model writes. When the model leaves it out, the scene stays as it was.
- A thirty-turn session, measured: [A Long Session With A Status-Window Card](ledger-benchmark.md). A small model alone broke the card's rules in every turn; with the ledger none of the card's rules was broken in thirty turns, and rerolls gave the same window.
- The ledger keeps the books, not the judgment. How much EXP a kill gives or how hard a blow lands is the model's to say, the first time a turn is answered. What stops is the window drifting by itself: a maximum that changes, a level that jumps, an inventory that loses what was never used, damage that is forgotten a turn later.
- A small model may tell of a level gained when the experience for it is not there. The window, kept by the card's rule, stays, and for that turn the story is ahead of it. So the model is told each turn how far the window is from such a rule (`Level stays at 3 (EXP is 52 / 132, 80 short)`), and when it writes a line for what only the rules set, it is told next turn that it did not happen. ([How much that helps](ledger-benchmark.md#when-the-story-runs-ahead).)
- The window is written at the end of the reply, also for a card that puts it first.
- A window is kept when its fields read as `Name: value` or `NAME=value` lines, several of those on one line split by `|`, rows of a table (`Name | 62 | calm | ...`, or `Name | Rank 10 | L 0 | C 0 | ...` with labelled numbers), lines led by a symbol, or a heading that says something (`[Day 3/30 · noon]`; one of several parts, `[Day 1 · night · the keep]`, keeps the parts a change leaves out). A line wrapped in a tag is read as what is inside it (`<hp>Health: 100 | Status: fine<hp>`), a field the window names as someone's (`Kim's Health Points`) is found when a change names it without the owner, fields joined by `&` on a line are read apart (`Item: a sword & Currency: 3 silver`), a window may be in parts under titles in brackets (`[Player Character]`), and a bracket inside a window that is itself in brackets does not end it. A window in another shape stays the model's, as before: a window that is mostly prose (lines of what someone is thinking, or of news, and no number, or more such lines than numbers and one; kept, with only what is named changed, such lines go stale), cells with no names, told apart by their place alone (`[Status:image|title|summary|...]`), a window with a line for each character now in the scene (more lines or fewer as they come and go), and one the card draws with its own scripts.
- A change the ledger cannot read is refused, not guessed at, and listed under this turn's rulings with the reason; the model is told next turn, to write it again. A number with no sign for a pair is one such (`HP: 8` may be eight lost or eight left), and so is a bare `0` (said for no change as often as for nothing left): changes are `+N` or `-N`, and `=N` sets a number outright. For a number that stands alone, a number with no sign is its new value (`Level: 11`, `Gold: 35`), unless several numbers are given lesser ones in one reply (that may be a list of what moved). An edit that would leave the window with a field less, or one more, is refused as well.
- What the model does not write did not happen, as far as the window goes: a potion drunk in the story and left out of the model's lines is still in the bag. The ledger cannot know, but it looks: a thing of a list that the story says was drunk, eaten, thrown, sold, or handed over, with no line for it, is listed under this turn's rulings as not written, and the model is asked about it next turn. Nothing is changed for it meanwhile (the story may speak of someone else's potion). Or correct the window by hand in the chat app, and the next turn goes on from it. (How often: [the benchmark](ledger-benchmark.md#what-the-model-leaves-out).)
- Of Aethrion's own there is affinity, trust, memories, and who saw what. Fights with dice, activities, and endings are not added to a card played this way. For those, import the card as below, add them at `/editor`, and play with the request model `aethrion`.
- `aethrion-auto-plain`, with no status block, has nowhere to carry the scene, so no one joins; and it reads the card again when the chat has been trimmed past its first message and the prompt has changed.

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

- **This turn's rulings:** under the status window, a folded section shows how the line was read, who saw it and who was away, every roll against armor class, and gossip or comfort between characters.
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
- **What the model hears:** who saw it, who was away and does not know, who told whom, how the characters now feel about each other, and who came back, as facts. Also what each character remembers about the player from earlier turns (lived through, seen, or heard from someone), so the narration can recall it. The status window shows the changes between characters, such as `도윤 → 세라 · 긴장 +8`.
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

Tested with SillyTavern 1.19.0: the card with its cover and lorebook, streaming, the status window, and swipes, which keep the numbers.

1. **Connect.** API Connections → API: Chat Completion → Chat Completion Source: Custom (OpenAI-compatible).
   - Custom Endpoint `http://localhost:4848/v1`
   - Custom API Key: the access password
   - Model ID `aethrion`
   - Click Connect. "Valid" and the model list mean it reached Aethrion.
2. **The card.** Download the PNG card from the chat page's **RisuAI** panel, and import it as a character (Import Character, or drop the file into `data/default-user/characters/`). When SillyTavern asks to import the embedded lorebook, say yes.
3. **The status window.** In the Regex extension, add two global scripts, in this order. Both use Affects: AI Output, and Other Options: Alter Chat Display.
   - The window with this turn's rulings folded under it:
     - Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)\n?<aethrion-turn title="([^"]*)">([\s\S]*?)<\/aethrion-turn><\/aethrion-status>/g`
     - Replace With: `<div style="white-space:pre-line;border:1px solid rgba(127,127,127,.35);border-radius:10px;padding:8px 12px;margin-top:10px">$1<details><summary>$2</summary><div style="white-space:pre-line">$3</div></details></div>`
   - The window alone, for a turn with nothing to rule on:
     - Find Regex: `/<aethrion-status[^>]*>([\s\S]*?)<\/aethrion-status>/g`
     - Replace With: `<div style="white-space:pre-line;border:1px solid rgba(127,127,127,.35);border-radius:10px;padding:8px 12px;margin-top:10px">$1</div>`

To keep a card you already use, set the Model ID to `aethrion-auto` ([Keep The Card You Already Use](#keep-the-card-you-already-use)). The card stays as it is in SillyTavern; only the two Regex scripts above are needed. Checked with the RisuRealm card [Sinmarked](https://realm.risuai.net/character/387a703e-8122-4d7a-8e34-069ebb26d0bc) (by ieungieung, CC BY-SA 4.0), imported and played unchanged: swipes keep the numbers and the rulings. Import the card's embedded lorebook when SillyTavern asks.

Streaming is on by default in SillyTavern's Chat Completion settings.
