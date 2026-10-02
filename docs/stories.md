# Stories, Fights, And Chat

[한국어](stories.ko.md)

Endings decided by the numbers, fights with companions who remember how you treated them, messenger-style bond stories, D&D 5e SRD dice, a cast editor, and how a chat line becomes an event.

## Endings And Fights

Two things AI chat and games keep asking for, decided the same way as everything else: by rules over numbers, so the same play always ends the same way and the reason can be shown.

**Endings by the numbers**, the way a raising sim decides them. A world's `story` holds activities (what "study" or "paint" does to stats and feelings), endings in priority order with their conditions, and when the ending is decided (a deadline, or the moment a condition holds):

```json
"stats": {"mina": {"art": 10, "intelligence": 10}},
"story": {
  "deadline": 720,
  "activities": {"paint": {"art": 3, "joy": 4, "stress": 2}},
  "endings": [
    {"id": "lovers", "title": "Together",
     "when": [{"relationship": ["mina", "user"], "field": "affinity", "at_least": 80},
              {"bond": ["mina", "user"], "is": "close"}]},
    {"id": "painter", "title": "The painter", "when": [{"stat": ["mina", "art"], "at_least": 70}]},
    {"id": "ordinary", "title": "An ordinary summer", "when": []}
  ]
}
```

`Aethrion.Story.progress/1` says how close each ending is and what is missing ("mina art 55 (needs at least 70)"), so a game can hint at a route; `examples/endings.exs` plays thirty days four ways to four endings. `priv/casts/summer.json` is a Korean raising sim to play in the chat page: thirty days with Seoyun before her art school exam, where what you suggest she spend each day on ("오늘은 같이 그림 그리자", "내일은 좀 쉬자") and how you talk to her decide one of six endings; push her to 100 stress and it ends before the deadline, and once an ending is decided no more days can be spent. The page's Story button shows how close each ending is and what is missing.

```bash
mix aethrion.serve --cast priv/casts/summer.json --locale ko --llm claude   # then just chat at http://localhost:4848
```

**No commands in a chat.** `POST /worlds/{key}/chat` takes a line the way a player types it, and the model reads what it does (see [Reading Chat Lines](#reading-chat-lines)): a move while a fight is on, a story activity when the player suggests one, a gift when they hand something over, and otherwise talk and its tone. A line that both talks and acts in a fight ("리아, 고마워! 늑대왕의 목을 노려 벤다") does both: Ria is thanked, then the wolf is struck. The response says how it was read (`interpreted.as`). Once read, the events replay exactly. The lines below are the built-in templates' (no model); with `--llm`, the model writes them in each character's voice:

```txt
You:  서윤아, 오늘은 같이 그림 그리자         -> activity 그림, a day passes (Day 1 of 30)
You:  네 그림 진짜 좋다. 색이 예뻐            -> talk (warm)   서윤: 정말? ...그렇게 말해 줘서 고마워.
You:  물감 새로 사 왔어                       -> gift 물감     서윤: 물감... 나 주려고 챙긴 거야? 고마워.
You:  내일은 좀 쉬자. 요즘 너무 무리했어      -> activity 휴식, a day passes
```

**Fights** for actors with an `hp` stat, players included: attack, guard, heal, flee, with damage from attack, defense, and a roll derived from who acts on whom and where the fight stands (their hp), so a fight replays exactly and chatting in between does not change the dice. Guarding or healing gives the enemies (actors with an `enemy` stat) their turn, and they go for the weakest of your side, so shielding a companion ("리아를 감싸며 방패를 든다") matters; the fallen are not revived; once the ending is decided, nobody fights. Characters feel it: the attacked resent it, witnesses who care about them trust you less, companions who fight beside you trust you more, the healed grow fonder. And it runs the other way: party members (a `party` stat) fight beside a player whose trust they hold, above a threshold (`combat.party_trust`, 10 by default; the quest uses 15), with a healer tending a hurt player first, and otherwise hold back (saying so once), so how you talked to your companions decides who stands with you. Companions gain trust by joining in, not by watching. In a chat, the player just types: "늑대왕의 목을 노려 벤다" is a blow, "리아를 감싸며 방패를 든다" shields Ria, "리아, 치료해 줘" has her heal you, and "카엘, 고마워" is talk. `priv/casts/quest.json` is a Korean party against the wolf king whose ending depends on how the fight went and how you treated your companions:

```bash
mix run examples/combat.exs                                   # the quest, five ways to five endings
mix aethrion.serve --cast priv/casts/quest.json --locale ko --llm claude   # then just chat at http://localhost:4848
```

**Messenger-style chats.** Modeled on how messenger features in character games work (a student messages their teacher first, replies are picked from a few choices, and the next bond story unlocks as the bond grows), with original characters and text: a story's `milestones` unlock once when their conditions hold, with the line the character sends first, and the story goes on (`Aethrion.Rules.Milestone`, `:milestone_reached`); `GET /worlds/{key}/replies?character=hana` offers three replies with their tones (`Aethrion.Replies`), and unlike in many games the choice moves the relationship; characters with the `polite` trait write in 존댓말 to 선생님 even without a model. `priv/casts/academy.json` has three students (하나, 유키, 미오) and six bond stories (the replies below are the built-in templates'; with `--llm` the model writes them):

```txt
You:  하나야, 어제 만든 거 정말 대단하더라!    하나: 에이, 갑자기 왜 이래요? 기분은 좋네요.
You:  고마워, 덕분에 수업 준비가 금방 끝났어.  하나: 헤헤, 그런 말은 더 해 줘도 돼요.
      ♥ 인연 스토리 · 하나 1: 고장 난 오르골
      하나: 선생님! 혹시 방과 후에 시간 있어요? 보여 드릴 게 있어요!
```

```bash
mix aethrion.serve --cast priv/casts/academy.json --locale ko --llm claude --tick-every 30
```

**Tabletop rules (D&D 5e SRD).** Give fighters an `attack_bonus` and an `ac` (and damage dice: `damage_dice`, `damage_die`, `damage_bonus`) and attacks follow the d20 rules of the System Reference Document 5.1: d20 + bonus against armor class, a natural 20 hits and rolls the damage dice twice, a natural 1 misses, a guarding (dodging) target is attacked with disadvantage, healers roll their dice (`heal_dice` 1, `heal_die` 8, `heal_bonus` 3 is a Cure Wounds), and a potion can be the SRD's Potion of Healing (2d4+2). The dice come from the fight itself, so they replay exactly, and every line shows them the way a table reads them out: `[d20 13+5=18 vs AC 14, 명중. 1d8+3 (3)] 네가 다이어 울프에게 6의 피해를 입혔다.` `priv/casts/den.json` is a wolf den with the SRD's Dire Wolf and Wolves against a fighter (you), a cleric, and a rogue; `examples/den.exs` plays it in plain Korean three ways to three endings. SRD material is used under CC-BY-4.0 (`priv/casts/SRD-NOTICE.md`). Dice are bounded (at most 20 dice of at most 100 sides a roll, in casts and in the rules). A Dodge lasts until the next blow rather than a full round, and save effects such as a wolf knocking someone prone are not modeled.

```bash
mix run examples/den.exs
mix aethrion.serve --cast priv/casts/den.json --locale ko --llm claude   # then just chat at http://localhost:4848
```

**Fights that follow feelings.** How the fighters feel about each other changes the fight, by numbers a cast can tune: a companion who cares about someone in danger (affinity 50 or more, they below half their hp) steps in front of the blow, once a round, and is liked and trusted more for it; when someone falls, the companions who loved them fight on enraged (+2 to their attacks); a companion who trusts you deeply (trust 40 or more) strikes beside you with advantage, as the SRD's Help action gives; and a healer passes over someone they resent (tension 50 or more) until that one falls. So what happened before the fight decides who shields whom in it. In `priv/casts/campfire.json`, a necklace for Sera by the fire lifts her care for you just past the line where she takes the goblins' blows for you; without it she never does (`test/aethrion/campfire_test.exs` plays both).

## Authoring Worlds

A world is a cast file (JSON): characters with a profile, a voice, and traits; relationships; stats; a story with activities, endings, and bond stories; and tuning for the rules' numbers. `mix aethrion.serve` also serves a **cast editor** at `/editor`: characters, relationships, stats, endings, and bond stories in forms (conditions with a builder: stat, relationship, bond, mood, time), checked by the server as you type (the problem and where it is), and downloaded as JSON. Its **route simulator** plays the story along routes written the way a player chats, and shows where each ends, on which day, and how close the other endings came:

```txt
오늘은 같이 그림 그리자
3일마다: 내일은 좀 쉬자
10일째: 너 주려고 물감 사 왔어
```

`Aethrion.Simulator` and `POST /casts/simulate` do the same from code. Every route is deterministic, so a changed number shows its effect at once.

## Reading Chat Lines

What a line does is decided by an interpreter (`Aethrion.Interpreter`), the seam between free text and the rules: it proposes events with a confidence, and the rules check and apply them, so a replay never asks it again. The built-in `Interpreter.Rules` reads keywords and patterns. A model plugs in by answering `Interpreter.questions/1`, typed choices drawn from the cast (what the line does, at whom, in what tone, which activity, who should heal), and `Interpreter.from_answers/2` turns the answers into events; a decision model that returns choices with probabilities (such as Jev) or an LLM with structured output fits this shape, and the rules stand in when it fails, answers outside the choices, or is unsure.

`mix aethrion.interpret.eval` scores an interpreter on 170 Korean chat lines labeled with what a person means (`priv/eval/interpret.ko.json`, quest, den, summer, and academy casts). The keyword rules read 105 of them right (62%): they miss phrasings they have no words for ("ㄱㄱ 늑대왕 잡자", "수채화 연습하자", "쿠키 구워 왔어"). `Interpreter.LLM` with the Claude Code CLI (`--llm claude`) reads 158 (93%); most of what it misses is close ("새 붓" for "붓", or a farewell read as warm). `--llm NAME` scores any backend. `--interpreter MyApp.Interpreter` scores another one on the same lines.
