# A Long Session With A Status-Window Card

Does a card's own status window hold over a long session, and what changes when Aethrion keeps it? One card, thirty turns, a simulated player who fights every turn, and the card's own rulebook as the yardstick. A small sample (one session a row), written down with its method so that it can be run again.

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
- **shape**: a number field that holds something else (`7 / 207` for a level, a sentence for HP);
- **bounds**: a number past its maximum, or EXP left full with no level gained;
- **level gifts**: from one turn to the next, stat points and stats together did not grow by what the levels gained give.

And each reroll: whether the window's numbers and inventory came out the same in all three answers.

## Results

| narrating model | the window is kept by | turns that break a rule | maxima / EXP max / shape / bounds / gifts | rerolls with other numbers | level after 30 turns | seconds a turn |
|---|---|---|---|---|---|---|
| Claude Opus 5.5 | the model | 3 of 30 | 0 / 0 / 0 / 0 / 3 | 10 of 10 | 5 | 59 |
| Claude Haiku 4.5 | the model | 30 of 30 | 30 / 22 / 0 / 0 / 18 | 10 of 10 | 44 | 42 |
| Claude Haiku 4.5 | Aethrion, the card read by Haiku | 6 of 30 | 0 / 0 / 0 / 0 / 6 | 0 of 10 | 4 | 32 |
| Claude Haiku 4.5 | Aethrion, the card read by Opus (`--card-model`) | 3 of 30 | 0 / 0 / 0 / 0 / 3 | 0 of 10 | 5 | 33 |

Reading it:

- **The small model alone loses the window.** Its first window already has maximums the stats do not give, the EXP a level takes drifts from the formula, and levels come too fast: 44 after thirty turns, where the large model reached 5.
- **With the ledger, the same small model keeps the card's rules.** The maximums, the EXP formula, level-ups with what is left over carried on, and the points a level gives are worked out by the rules, so there is nothing for the model to get wrong there. What is left is the model's own account of spending stat points: stats raised with no points taken, or by more than was spent. The large model alone slips in the same place, as often.
- **Rerolls.** Left to the model, every reroll gave other numbers, with the large model too: a reroll is a new roll of the dice for everything. With the ledger, a turn's changes are settled by its first answer, and a reroll tells the same outcome again.
- **Time.** The model no longer writes the 37 lines of the window with every reply, so a turn takes less time and fewer output tokens.

## What This Does Not Show

- One session a row. The rows differ in what the story did, so the level reached is a rough sign, not a measure.
- The ledger keeps the books; it does not judge. How much EXP a kill gives and how hard a blow lands are still the model's to say, once a turn.
- What the card states only in words stays the model's. This card says stat points raise stats and gives no price, so no rule charges for a point spent. The gifts column counts the turns where the model's own account of spending did not add up. A price can be added by hand on `/cards` (`when Strength rises: Stat Point -= 1`, one line a stat).
- Nor does anything in the card price loot. The small model is generous with it: by the end of its sessions it had sold monster cores for hundreds of millions. The ledger added those sums up correctly.
- The reader matters. Haiku reads this card's rules less surely than Opus (it leaves some out; what it cannot ground in the card is dropped). The card is read once, so a stronger reader costs one call a card.

## Running It Again

The scripts are not in the repository (they play a card that is not ours to ship). The method in short: build the messages as the chat app would; for the model alone, send them to the model; for Aethrion, send them to `/v1/chat/completions` with the model `aethrion-auto`; have a second model write the player's next line from the last reply; parse the window between its `[Status Window]` lines; check the rules above.

```bash
mix aethrion.serve --llm claude --model haiku --card-model opus --locale ko
```
