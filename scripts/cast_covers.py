# Renders the cover images of the bundled casts (priv/casts/<cast>.png),
# which the RisuAI card download embeds its card into. Needs Google Chrome.
#
# Usage: python3 scripts/cast_covers.py
import html, os, subprocess, tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

COVERS = {
    "campfire": ("불", "모닥불", "세라 · 도윤 · 하린", "선물 하나가 누가 누구를 지킬지 정하는 밤", ("#2b1408", "#7a2f0c")),
    "den": ("굴", "늑대 굴", "D&D 5e SRD 판정", "다이어 울프와 늑대 떼, 주사위는 규칙이 굴린다", ("#10161f", "#2f3d52")),
    "quest": ("왕", "늑대왕 토벌", "리아 · 카엘", "어떻게 싸웠고 동료를 어떻게 대했는지가 엔딩이 된다", ("#14101f", "#4a2f6b")),
    "summer": ("꿈", "서윤의 여름", "30일 육성 시뮬", "미술 입시까지 한 달, 하루하루가 엔딩을 정한다", ("#0f2420", "#2f7a68")),
    "academy": ("답", "방과 후 메신저", "하나 · 유키 · 미오", "답장 하나로 쌓이는 인연 스토리", ("#241020", "#8a3a6a")),
    "cafe": ("잔", "골목 카페", "지우 · 민호 · 서라", "단골들이 서로를 기억하는 작은 카페", ("#1f170f", "#6b4a2a")),
    "campfire_en": ("✶", "Campfire", "Sera · Doyun · Harin", "One gift decides who shields whom tonight", ("#2b1408", "#7a2f0c"), "Aethrion · rules keep the numbers, your model tells it"),
}

PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8"><style>
html,body{{margin:0;width:512px;height:768px}}
body{{background:linear-gradient(160deg,{c0},{c1});color:#f4efe6;font-family:"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif;
display:flex;flex-direction:column;justify-content:space-between;box-sizing:border-box;padding:56px 44px 44px}}
.glyph{{width:150px;height:150px;border-radius:50%;margin-top:40px;display:flex;align-items:center;justify-content:center;
font-size:84px;font-weight:700;color:#fff;border:2px solid rgba(255,255,255,.55);
background:radial-gradient(circle at 35% 30%,rgba(255,255,255,.28),rgba(255,255,255,.04) 70%);box-shadow:0 0 60px rgba(255,255,255,.12)}}
h1{{font-size:64px;margin:28px 0 8px;letter-spacing:-1px}}
.who{{font-size:24px;opacity:.85}}
.line{{font-size:22px;line-height:1.45;opacity:.9;margin-top:22px}}
.brand{{font-size:18px;opacity:.7;border-top:1px solid rgba(255,255,255,.25);padding-top:14px}}
</style></head><body><div><div class="glyph">{glyph}</div><h1>{title}</h1><div class="who">{who}</div><div class="line">{line}</div></div>
<div class="brand">{brand}</div></body></html>"""

for cast, (glyph, title, who, line, (c0, c1), *rest) in COVERS.items():
    brand = rest[0] if rest else "Aethrion · 숫자는 규칙이, 이야기는 모델이"
    page = PAGE.format(glyph=glyph, title=html.escape(title), who=html.escape(who), line=html.escape(line), c0=c0, c1=c1, brand=html.escape(brand))
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page)
    out = os.path.join("priv", "casts", cast + ".png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--window-size=512,768",
                    f"--screenshot={os.path.abspath(out)}", "file://" + f.name], check=True, capture_output=True)
    os.unlink(f.name)
    print(out, os.path.getsize(out))
