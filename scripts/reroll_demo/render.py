# Draws assets/demo/reroll.png (ko) or reroll.en.png (en) as HTML from what
# plain_card.py and aethrion_side.py wrote; headless Chrome turns it into
# the image:
#
#   python3 scripts/reroll_demo/render.py plain.json aethrion.json en > reroll.en.html
#   chrome --headless=new --force-device-scale-factor=2 --window-size=1100,690 \
#          --screenshot=assets/demo/reroll.en.png reroll.en.html
import html, json, re, sys

TEXT = {
    "ko": {
        "font": '"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif',
        "title": "같은 장면을 세 번 리롤하면",
        "lead": '모닥불 앞, "세라, 목걸이 사 왔어. 선물이야" (도윤이 보고 있음). 같은 기록과 같은 대사로 세 번 다시 생성했습니다.',
        "plain": "모델이 상태창을 쓰는 카드",
        "plain_sub": "상태창 숫자도 모델이 갱신 · 빨간 숫자는 리롤마다 달라진 값",
        "aeth_sub": "숫자는 규칙이 계산, 서술만 모델이 씀 · 괄호는 이번 턴의 변화",
        "reroll": "리롤",
        "names": ["세라", "도윤"],
        "foot": "두 쪽 모두 같은 모델(Claude Code CLI)로 실제로 생성한 결과이고, 시작 값도 같습니다(세라 호감 40 · 신뢰 42, 도윤 호감 45 · 신뢰 20, 긴장 0). Aethrion v0.2 · priv/casts/campfire.json",
    },
    "en": {
        "font": '"Avenir Next","Inter",system-ui,sans-serif',
        "title": "The same scene, rerolled three times",
        "lead": 'By the campfire: "Sera, I bought you a necklace. It\'s a gift." (Doyun is watching.) The same history and the same line, generated three times.',
        "plain": "A card where the model keeps the status window",
        "plain_sub": "the model updates the numbers too · red: changed between rerolls",
        "aeth_sub": "rules compute the numbers · brackets are this turn's change",
        "reroll": "Reroll",
        "names": ["Sera", "Doyun"],
        "foot": "Both sides were generated with the same model (Claude Code CLI) from the same starting values (Sera affinity 40 · trust 42, Doyun affinity 45 · trust 20, tension 0). Aethrion v0.2 · priv/casts/campfire_en.json",
    },
}

plain, aethrion, lang = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
t = TEXT[lang]
a, b = t["names"]


def lines(status):
    """Sera's and Doyun's lines, and Doyun toward Sera, without the HP."""
    starts = (a + " ·", b + " ·", f"{b} → {a}")
    kept = [l for start in starts for l in status.splitlines() if l.startswith(start)]
    return [re.sub(r" · HP \d+/\d+.*$", "", l) for l in kept]


def cards(rerolls, mark):
    rows = [lines(r["status"]) for r in rerolls]
    out = []
    for i, (reroll, mine) in enumerate(zip(rerolls, rows)):
        drawn = []
        for n, line in enumerate(mine):
            parts = re.split(r"(\d+)", line)
            for k in range(1, len(parts), 2):
                others = {re.split(r"(\d+)", row[n])[k] for row in rows if n < len(row) and k < len(re.split(r"(\d+)", row[n]))}
                parts[k] = f'<b class="diff">{parts[k]}</b>' if mark and len(others) > 1 else parts[k]
            drawn.append('<div class="ln">' + "".join(p if p.startswith("<b") else html.escape(p) for p in parts) + "</div>")
        narration = " ".join(reroll["narration"].split())
        cut = 62 if lang == "en" else 34
        out.append(f'<div class="card"><div class="rr">{t["reroll"]} {i + 1}</div><div class="nar">{html.escape(narration[:cut])}…</div><div class="st">{"".join(drawn)}</div></div>')
    return "".join(out)


print(f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>
body{{margin:0;background:#15171c;color:#e8e6e1;font:15px/1.5 {t["font"]}}}
.wrap{{width:1100px;padding:28px 32px 22px;box-sizing:border-box}}
h1{{font-size:22px;margin:0 0 4px}} .lead{{color:#a9a69e;margin:0 0 18px;font-size:14px}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:20px}}
section{{background:#1d2027;border:1px solid #2c3039;border-radius:14px;padding:16px 16px 6px}}
h2{{font-size:17px;margin:0}} .sub{{color:#a9a69e;font-size:13px;margin:2px 0 12px}}
.card{{background:#23262e;border-radius:10px;padding:10px 12px;margin-bottom:10px}}
.rr{{font-size:12px;color:#8d8a83}} .nar{{color:#cfccc4;font-size:13px;margin:2px 0 6px;white-space:nowrap;overflow:hidden}}
.st{{border-top:1px dashed #3a3e48;padding-top:6px;font:13px/1.65 ui-monospace,"SF Mono",Menlo,monospace}}
.plain .ln{{color:#d8d5cd}} .aeth .ln{{color:#8fe3a8}} b.diff{{color:#ff8a7a;font-weight:700;text-decoration:underline;text-underline-offset:3px}}
.plain h2{{color:#ffb4a8}} .aeth h2{{color:#9ff0b6}}
.foot{{color:#8d8a83;font-size:12px;margin-top:10px}}
</style></head><body><div class="wrap">
<h1>{html.escape(t["title"])}</h1>
<p class="lead">{html.escape(t["lead"])}</p>
<div class="cols">
<section class="plain"><h2>{html.escape(t["plain"])}</h2><p class="sub">{html.escape(t["plain_sub"])}</p>{cards(plain, True)}</section>
<section class="aeth"><h2>Aethrion</h2><p class="sub">{html.escape(t["aeth_sub"])}</p>{cards(aethrion, False)}</section>
</div>
<p class="foot">{html.escape(t["foot"])}</p>
</div></body></html>""")
