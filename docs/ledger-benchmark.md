# A Long Session With A Status-Window Card

Does a card's own status window hold over a long session, and what changes when Aethrion keeps it? One card, thirty turns, a simulated player who fights every turn, and the card's own rulebook as the yardstick. A small sample (one or two sessions a row), written down with its method so that it can be run again.

## The Card

[Pyros](https://realm.risuai.net/character/7b551da5-f76d-454b-b361-d3720bc85752) from RisuRealm (by risukr, CC BY-NC-ND 4.0), a tower-climbing RPG and one of the most downloaded simulation cards there. Its model prints a status window of 37 fields with every reply, and the card states the arithmetic of some of them:

- the maximum of HP, MP, SP, SAN, and inventory load is a stat times 10;
- the EXP a level takes is `100 × 1.15^(Level − 1)`, cut to a whole number;
- a level gives 5 stat points, 15 at every fifth level.

The card is not in this repository. Its prompt, constant lorebook entries, and one of its opening scenes were sent as RisuAI would send them, with a history of the last sixteen messages.

## The Session

A second model plays the player: one or two sentences a turn, written from the last reply, told to go into the tower and fight, to drink a potion or rest when hurt, and to spend stat points when it has them. Every third turn the reply is generated two more times from the same history, as a player rerolls.

Each turn's window is then checked against the card's rules:

- **maxima**: a maximum that is not its stat times 10;
- **EXP max**: the EXP a level takes is not what the formula gives;
- **no window**: a reply with no window, or a number field that holds something else (`7 / 207` for a level, a sentence for HP);
- **bounds**: a number past its maximum, or EXP left full with no level gained;
- **stat points**: from one turn to the next, stat points and stats together did not grow by what the levels gained give (a stat raised with no point taken for it, or a level that gave nothing).

And each reroll: whether the window's numbers and inventory came out the same in all three answers.

## Results

Thirty turns a session. Where a row has two sessions, both are given.

| narrating model | the window is kept by | turns that break a rule | maxima / EXP max / bounds | no window | stat points | rerolls with other numbers | level after 30 turns |
|---|---|---|---|---|---|---|---|
| Claude Opus 5.5 | the model | 3 of 30 | 0 / 0 / 0 | 0 | 3 | 10 of 10 | 5 |
| Claude Haiku 4.5 | the model | 30 of 30 | 30 / 22 / 0 | 0 | 18 | 10 of 10 | 44 |
| Claude Haiku 4.5 | Aethrion, the card read by Haiku | 2 and 6 of 30 | 0 / 0 / 0 | 0 and 1 | 2 and 5 | 0 of 20 | 4 and 3 |
| Claude Haiku 4.5 | Aethrion, the card read by Opus (`--card-model`) | 1 and 14 of 30 | 0 / 0 / 0 | 1 and 0 | 0 and 14 | 0 of 20 | 3 and 20 |
| Claude Haiku 4.5 | Aethrion, and a price for stat points added by hand | 0 of 30 | 0 / 0 / 0 | 0 | 0 | 0 of 10 | 14 |
| Claude Opus 5.5 | Aethrion | 0 of 30 | 0 / 0 / 0 | 0 | 0 | 0 of 10 | 3 |

Reading it:

- **The small model alone loses the window.** Its first window already has maximums the stats do not give, the EXP a level takes drifts from the formula, and levels come too fast: 44 after thirty turns, where the large model reached 5.
- **With the ledger, the same small model keeps the card's rules.** The maximums, the EXP formula, level-ups with what is left over carried on, and the points a level gives are worked out by the rules, so there is nothing for the model to get wrong there: none of those was broken in any turn of these sessions.
- **What is left is the model's account of spending stat points**: a stat raised with no point taken for it, or by more than was spent. The card says that stat points raise stats and names no price, so no rule charges for them. The large model alone slips in the same place. How often depends on the story: a session where the player levels fast and spends at every turn broke the rule in 14 turns, one that levels slowly in none. With a price added on `/cards` (`when Strength rises: Stat Point -= 1`, one line a stat), a point that is not there cannot be spent, and nothing was broken in thirty turns.
- **No window.** The first window is the model's to print (there is none yet to keep). In two sessions the small model's first reply had none; it printed one at the second turn, and the ledger went on from there.
- **Rerolls.** Left to the model, every reroll gave other numbers, with the large model too: a reroll is a new roll of the dice for everything. With the ledger, a turn's changes are settled by its first answer, and a reroll tells the same outcome again.

The table is from the last build of the night it was measured in. On the builds before it, some twenty more sessions with the ledger gave the same picture: no maximum, formula, or bound broken wherever the card's rules had been read, no reroll with other numbers, and between 0 and 16 turns of thirty with stat points unaccounted for.

## The Reader Matters

The card's arithmetic is read from the card by a model, once, when the card is first played. A small model narrates well and reads less surely. Single readings of this card by Haiku left a rule out (each of three readings another one), wrote `HP.max = 100 + Vigor * 10` for "Max HP +10 per point" (the card's own example window, Vigor 13 and HP 121 / 130, says otherwise), and for another card took the window's opening text from the card's template with its blanks in it.

So a card is read three times at once, and what is read is checked against the card:

- the window's opening and closing text are what most readings say;
- a rule is kept only when the card bears it out: its own example windows agree with it, or its sentence is in the card with the rule's numbers;
- a rule that only adds a base the card's example contradicts is kept without the base;
- the rules of the three readings are put together, one rule for each thing.

Before these, the Haiku-read row was a matter of luck. In two of the night's sessions all three readings had written the maximums with a base of 100: the rules were thrown away with nothing in their place, the model's own first window stood, and every turn had a maximum that its stat did not give. In the two sessions of the table and in six more readings of the card, Haiku's reading had every maximum.

A stronger reader costs three calls a card, once (`--card-model`), and what was read can be looked over and set right on `/cards`.

## What The Model Leaves Out

The ledger applies what the model says changed. What the model does not say did not happen, as far as the window goes. How often is that?

One state of the [example card](../examples/cards) (HP 36 / 50, 42 gold, a bag of four things), three lines that each do several things (drink a potion and sell two things; buy a potion and climb a floor; rest until night and drink a potion), twelve answers each from Haiku, every answer a turn of its own. Of 120 changes those lines should make, 116 were in the window (96%). Of the 4 that were not, in 2 the story went otherwise (the player sold loot to pay for the potion), and in 2 the model's lines said something else than its story (a potion bought and not written; things already held written as gained).

At the start of the night the same test gave 85%, and 94% midway. Most of what was missing at first was written by the model and not read: things joined by a space or a semicolon (`-potion × 1 -rat fur × 1`), a thing named as if it were a field (`Potion: -1`), a sum (`42 + 8`), a move before a maximum (`+25 / 50`). Three wordings of a reminder to go through the fields made no difference (85%, 86%, 85%); reading what the model writes did.

For what is left, the reply's story is looked through: a thing of a list that the story says was drunk, eaten, thrown, sold, or handed over, with no line for it, is listed under this turn's rulings as not written, and nothing is changed (the story may speak of someone else's potion). In the run at 94%, five things spent in the story had no line (a potion drunk, things sold): it caught 4 of the 5. The model is then asked for the line next turn; in a test of that turn alone, 8 answers of 8 wrote it.

## Other Cards

The same code played eight to fourteen turns each of eleven community cards and the example card, with Haiku narrating and Opus reading. Their windows come in these shapes, all kept by the ledger:

- a block of `- Name: value` lines between two markers (RPG windows with levels, pairs, and inventories);
- one line of `Name: value` pieces split by `|`, with a thought at the end;
- a heading of several parts (`[Day 1 · night · a place]`) over a table of rows, one person a row, with labelled numbers in the rows;
- lines led by a mark (`◈Time: ...`) with no closing text;
- `<status>` with `NAME=value` lines;
- a record sheet with a heading that counts (`━━ RECORD No.4 ━━`) and fields split by `│`;
- one line of `name=value` pieces split by `|`.

Two more cards draw their windows with their own scripts and tell the model not to write the numbers: those are left alone.

What unit tests had not found, these sessions and the thirty-turn ones did: an inventory replaced by `(no change)`, a list taken for a date because an item was of grade `(일반)` (which reads as a day of the week), a level that stayed at 1 because the model had wrapped the experience itself, a row emptied by `+10 (65 → 75)`, a closing tag spelled `</aetherion-ledger>`. After each session every turn's window is checked for a field gone or a value that looks broken.

## What This Does Not Show

- One or two sessions a row. The rows differ in what the story did, so the level reached is a rough sign, not a measure.
- The ledger keeps the books; it does not judge. How much EXP a kill gives and how hard a blow lands are still the model's to say, once a turn.
- Nor does anything in the card price loot. The small model is generous with it: by the end of some sessions it had sold monster cores for hundreds of millions. The ledger added those sums up correctly.
- Time. With the ledger the model no longer writes the 37 lines of the window with every reply, and a turn took about 30 to 45 seconds where the small model alone took 42; but the sessions shared one machine, several at a time, so the seconds are not a measurement.
- The checks in RisuAI's own app are still to do for the ledger; it was checked in SillyTavern and through the API.

## Running It Again

The scripts are not in the repository (they play a card that is not ours to ship). The method in short: build the messages as the chat app would; for the model alone, send them to the model; for Aethrion, send them to `/v1/chat/completions` with the model `aethrion-auto`; have a second model write the player's next line from the last reply; parse the window between its `[Status Window]` lines; check the rules above.

```bash
mix aethrion.serve --llm claude --model haiku --card-model opus --locale ko
```
