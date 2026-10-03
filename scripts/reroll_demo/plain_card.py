# The left side of assets/demo/reroll.png (and reroll.en.png): the same
# campfire scene asked three times of the Claude Code CLI as a plain card
# would, with the model keeping the status window itself. The right side
# comes from aethrion_side.py.
#
# Usage: python3 scripts/reroll_demo/plain_card.py out.json [ko|en]
import json, subprocess, sys

TEXT = {
    "ko": {
        "mark": "[상태창]",
        "none": "(상태창 없음)",
        "system": """너는 판타지 롤플레이의 내레이터다. 등장인물: 세라(성직자, 플레이어의 동료), 도윤(장난기 많은 동료).
응답은 3~4문장의 서술로 쓰고, 맨 끝에 반드시 아래 형식의 상태창을 출력한다. 숫자는 이번 장면에 맞게 갱신한다.
[상태창]
세라 · 호감 N · 신뢰 N
도윤 · 호감 N · 신뢰 N
도윤 → 세라 · 긴장 N""",
        "history": """Assistant: (밤의 야영지. 모닥불이 탁탁 튄다.) 세라: 하린 씨가 돌아오려면 몇 시간은 걸릴 거예요.
[상태창]
세라 · 호감 40 · 신뢰 42
도윤 · 호감 45 · 신뢰 20
도윤 → 세라 · 긴장 0

User: 세라, 목걸이 사 왔어. 선물이야 (도윤도 옆에서 보고 있다)

Write the next assistant message only, without a label.""",
    },
    "en": {
        "mark": "[Status]",
        "none": "(no status window)",
        "system": """You are the narrator of a fantasy role-play. Characters: Sera (a cleric, the player's companion) and Doyun (a playful companion).
Write three or four sentences of narration, and always end with a status window in the format below. Update the numbers to fit this scene.
[Status]
Sera · affinity N · trust N
Doyun · affinity N · trust N
Doyun → Sera · tension N""",
        "history": """Assistant: (Night at camp. The fire crackles.) Sera: Harin won't be back for a few hours.
[Status]
Sera · affinity 40 · trust 42
Doyun · affinity 45 · trust 20
Doyun → Sera · tension 0

User: Sera, I bought you a necklace. It's a gift. (Doyun is watching from beside the fire.)

Write the next assistant message only, without a label.""",
    },
}

lang = sys.argv[2] if len(sys.argv) > 2 else "ko"
text = TEXT[lang]
out = []
for i in range(3):
    r = subprocess.run(["claude", "-p", text["history"], "--system-prompt", text["system"], "--output-format", "text",
                        "--tools", "", "--no-session-persistence"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=180)
    reply = r.stdout.strip()
    at = reply.find(text["mark"])
    status = reply[at:] if at >= 0 else text["none"]
    out.append({"narration": reply[:at].strip() if at >= 0 else reply, "status": status})
    print(f"--- reroll {i+1}\n{status}", flush=True)
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
