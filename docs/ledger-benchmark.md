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

Thirty turns a session. Where a row has several sessions, each is given.

| narrating model | the window is kept by | turns that break a rule | maxima / EXP max / bounds | no window | stat points | rerolls with other numbers | level after 30 turns |
|---|---|---|---|---|---|---|---|
| Claude Opus 5.5 | the model | 3 of 30 | 0 / 0 / 0 | 0 | 3 | 10 of 10 | 5 |
| Claude Haiku 4.5 | the model | 30 of 30 | 30 / 22 / 0 | 0 | 18 | 10 of 10 | 44 |
| Claude Haiku 4.5 | Aethrion, the card read by Haiku | 0 and 0 of 30 | 0 / 0 / 0 | 0 | 0 | 0 of 20 | 10 and 7 |
| Claude Haiku 4.5 | Aethrion, the card read by Opus (`--card-model`) | 0 of 30, four times | 0 / 0 / 0 | 0 | 0 | 0 of 40 | 4, 2, 5 and 6 |
| Claude Opus 5.5 | Aethrion | 0 of 30 | 0 / 0 / 0 | 0 | 0 | 0 of 10 | 3 |

Reading it:

- **The small model alone loses the window.** Its first window already has maximums the stats do not give, the EXP a level takes drifts from the formula, and levels come too fast: 44 after thirty turns, where the large model reached 5.
- **With the ledger, the same small model keeps the card's rules.** The maximums, the EXP formula, level-ups with what is left over carried on, the points a level gives, and the points a stat costs are worked out by the rules, so there is nothing for the model to get wrong there.
- **Stat points were the last thing to hold.** The card says that stat points raise stats and names no price. Left to say it itself, the small model raised the stat and forgot the points (the same five points were spent in six turns of one session), or raised more than it had. The large model alone slips in the same place. So the card reader now notes which pool of points the card says raises which numbers, and the price is one point each: held in a turn that has points, waived in a turn with none, since this card, like many, lets a stat rise by training too. Before that, sessions with the ledger had stat points unaccounted for in 0 to 16 turns of thirty.
- **No window.** The first window is the model's to print (there is none yet to keep). In two earlier sessions the small model's first reply had none; it printed one at the second turn, and the ledger went on from there. Asked alone, 7 first replies of 8 had the window. The note now asks for the window while the chat has none: 25 first replies of 25 had it, and every session since.
- **Rerolls.** Left to the model, every reroll gave other numbers, with the large model too: a reroll is a new roll of the dice for everything. With the ledger, a turn's changes are settled by its first answer, and a reroll tells the same outcome again.
- **The level reached** differs with the story, and with how much experience the model hands out: the rules see to it that a level takes what the card says, not that a kill gives a fair amount.

The rows with the ledger are from the builds at the end of the night it was measured in. Some thirty sessions on the builds before them gave the picture those builds were made from: no maximum, formula, or bound broken wherever the card's rules had been read, no reroll with other numbers, and what is told above of stat points, of the first window, and of [the story running ahead](#when-the-story-runs-ahead).

## The Reader Matters

The card's arithmetic is read from the card by a model, once, when the card is first played. A small model narrates well and reads less surely. Single readings of this card by Haiku left a rule out (each of three readings another one), wrote `HP.max = 100 + Vigor * 10` for "Max HP +10 per point" (the card's own example window, Vigor 13 and HP 121 / 130, says otherwise), and for another card took the window's opening text from the card's template with its blanks in it.

So a card is read three times at once, and what is read is checked against the card:

- the window's opening and closing text are what most readings say;
- a rule is kept only when the card bears it out: its own example windows agree with it, or its sentence is in the card with the rule's numbers;
- a rule that only adds a base the card's example contradicts is kept without the base;
- the rules of the three readings are put together, one rule for each thing.

Before these, the Haiku-read row was a matter of luck. In two of the night's sessions all three readings had written the maximums with a base of 100: the rules were thrown away with nothing in their place, the model's own first window stood, and every turn had a maximum that its stat did not give. In the two sessions of the table and in six more readings of the card, Haiku's reading had every maximum.

Later in the night a Haiku-read session gave no points for a level in thirty turns. Each reading had quoted the card's sentence about them only as far as "an extra 10 points for every level ending in 5 or 0", and written the rule with the 15 that the card's line goes on to say ("gaining 15 points in total"): the rule was dropped for a number its sentence did not have. A rule's number is now looked for in the whole line of the card that the quote begins in.

A stronger reader costs three calls a card, once (`--card-model`), and what was read can be looked over and set right on `/cards`.

## What The Model Leaves Out

The ledger applies what the model says changed. What the model does not say did not happen, as far as the window goes. How often is that?

One state of the [example card](../examples/cards) (HP 36 / 50, 42 gold, a bag of four things), three lines that each do several things (drink a potion and sell two things; buy a potion and climb a floor; rest until night and drink a potion), twelve answers each from Haiku, every answer a turn of its own. Of 120 changes those lines should make, 116 were in the window (96%). Of the 4 that were not, in 2 the story went otherwise (the player sold loot to pay for the potion), and in 2 the model's lines said something else than its story (a potion bought and not written; things already held written as gained).

At the start of the night the same test gave 85%, and 94% midway. Most of what was missing at first was written by the model and not read: things joined by a space or a semicolon (`-potion × 1 -rat fur × 1`), a thing named as if it were a field (`Potion: -1`), a sum (`42 + 8`), a move before a maximum (`+25 / 50`). Three wordings of a reminder to go through the fields made no difference (85%, 86%, 85%); reading what the model writes did.

For what is left, the reply's story is looked through: a thing of a list that the story says was drunk, eaten, thrown, sold, or handed over, with no line for it, is listed under this turn's rulings as not written, and nothing is changed (the story may speak of someone else's potion). In the run at 94%, five things spent in the story had no line (a potion drunk, things sold): it caught 4 of the 5. The model is then asked for the line next turn; in a test of that turn alone, 8 answers of 8 wrote it.

## When The Story Runs Ahead

The rules keep the level: it rises when the experience is there. The small model tells of a level gained when it is not: three kills at 12 EXP each, and "Level 4!" at 52 of 132. The window stays at 3, and the reply's own story is at odds with it. In one session this went on for four turns, and each time the model also raised stats with the points of the level it had told of.

So the note now says where each waiting rule stands (`Level stays at 3 (EXP is 52 / 132, 80 short)`), and a line the model wrote for what only the rules set is named next turn as something that did not happen (before, it was listed with the lines to write again).

Four turns of that session, each played again twelve times from the same history, on the note before and after:

| | before | after |
|---|---|---|
| replies with a line for Level, which is the rules' to set | 15 of 48 | 2 of 48 |
| stories that tell of a level-up the window does not have | 10 of 48 | 5 of 48 |
| stories that say how much EXP is still needed | 0 of 48 | 3 of 48 |

Half as often, not never. In the eleven full sessions the small model narrated after that, 1 turn of 330 had such a story (6 of 60 in the two before).

## Other Cards

The same code played eight to fourteen turns each of twenty-six community cards and the two example cards, with Haiku narrating and Opus reading. Fourteen have a window the ledger keeps. Their windows come in these shapes:

- a block of `- Name: value` lines between two markers (RPG windows with levels, pairs, and inventories);
- one line of `Name: value` pieces split by `|`, with a thought at the end;
- a heading of several parts (`[Day 1 · night · a place]`) over a table of rows, one person a row, with labelled numbers in the rows;
- lines led by a mark (`◈Time: ...`) with no closing text;
- a heading led by a mark (`🧭[Year 527 · morning · spring]`) over `- Name: value` lines;
- a record sheet with a heading that counts (`━━ RECORD No.4 ━━`) and fields split by `│`;
- one line of `name=value` pieces split by `|`.

And these are left to the model, as before the ledger:

- windows the card draws with its own scripts, the model being told not to write the numbers (three cards);
- a window that is mostly prose: a line for what each of five people is thinking, the day's news. Kept, with only the named fields changed, those lines stayed as they were for five turns; the model alone writes them anew with every reply;
- a window of cells with no names, told apart by their place (`[Status:image|title|summary|Time: 22:10|place|...]`);
- a window with a line for each character now in the scene, more or fewer as they come and go.

What unit tests had not found, these sessions and the thirty-turn ones did: an inventory replaced by `(no change)`, a list taken for a date because an item was of grade `(일반)` (which reads as a day of the week), a level that stayed at 1 because the model had wrapped the experience itself, a row emptied by `+10 (65 → 75)`, a closing tag spelled `</aetherion-ledger>`, a window in brackets cut at a bracket inside it (and the rest of it left in the middle of the reply), a window in parts cut at its first blank line, a line in brackets that lost its closing bracket. After each session every turn's window is checked for a field gone or a value that looks broken.

## What This Does Not Show

- One to four sessions a row, one card, one simulated player who fights and spends points. Nothing broken in thirty turns is not nothing ever: it is what these sessions showed. The rows differ in what the story did, so the level reached is a rough sign, not a measure.
- The ledger keeps the books; it does not judge. How much EXP a kill gives and how hard a blow lands are still the model's to say, once a turn. A small model that writes the level itself, with the experience counted down to fit, is taken at its word.
- The price of a stat point is read from a card that names none. A stat that rises while points are waiting is paid for with them, also when the story meant training.
- Nor does anything in the card price loot. The small model is generous with it: by the end of some sessions it had sold monster cores for hundreds of millions. The ledger added those sums up correctly.
- Time. With the ledger the model no longer writes the 37 lines of the window with every reply, and a turn took about 30 to 45 seconds where the small model alone took 42; but the sessions shared one machine, several at a time, so the seconds are not a measurement.
- The checks in RisuAI's own app are still to do for the ledger; it was checked in SillyTavern and through the API.

## Running It Again

The scripts are not in the repository (they play a card that is not ours to ship). The method in short: build the messages as the chat app would; for the model alone, send them to the model; for Aethrion, send them to `/v1/chat/completions` with the model `aethrion-auto`; have a second model write the player's next line from the last reply; parse the window between its `[Status Window]` lines; check the rules above.

```bash
mix aethrion.serve --llm claude --model haiku --card-model opus --locale ko
```
