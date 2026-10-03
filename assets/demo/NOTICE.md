# Third-party content in the demo images

`card.en.gif` and `card.ko.gif` show the character card **Sinmarked** by
ieungieung, published on RisuRealm under CC BY-SA 4.0
(https://realm.risuai.net/character/387a703e-8122-4d7a-8e34-069ebb26d0bc), played unchanged in SillyTavern with Aethrion as the model. The
card's text, its picture, and the narration written from it appear in those
two images, so the two images are shared under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) as well.
The card itself is not in this repository.

Everything else here (the campfire images, the comparison images, and the
scripts that make them) is Aethrion's own, under the repository's MIT
license.

## How the images are made

- `swipes.gif`: window captures of the RisuAI desktop app
  (`screencapture -l <window id>`), put together by
  `scripts/demo/swipes_gif.swift`.
- `swipes.en.gif`, `card.en.gif`, `card.ko.gif`,
  `sillytavern-campfire.en.png`: SillyTavern in a headless Chrome
  (`scripts/demo/st_capture.mjs`), then `scripts/demo/swipes_gif.swift`.
- `reroll.png`, `reroll.en.png`: `scripts/reroll_demo/` (`plain_card.py`,
  `aethrion_side.py`, `render.py`), from real runs kept in `reroll.json`
  and `reroll.en.json`.
