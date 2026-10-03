# The left side of assets/demo/reroll.png: the same campfire scene asked
# three times of the Claude Code CLI as a plain card would, with the model
# keeping the status window itself. The right side is the same scene sent
# three times to /v1/chat/completions (model "aethrion", --cast campfire).
#
# Usage: python3 scripts/reroll_demo/plain_card.py out.json
import json, subprocess, re, sys
system = """너는 판타지 롤플레이의 내레이터다. 등장인물: 세라(성직자, 플레이어의 동료), 도윤(장난기 많은 동료).
응답은 3~4문장의 서술로 쓰고, 맨 끝에 반드시 아래 형식의 상태창을 출력한다. 숫자는 이번 장면에 맞게 갱신한다.
[상태창]
세라 · 호감 N · 신뢰 N
도윤 · 호감 N · 신뢰 N
도윤 → 세라 · 긴장 N"""
history = """Assistant: (밤의 야영지. 모닥불이 탁탁 튄다.) 세라: 하린 씨가 돌아오려면 몇 시간은 걸릴 거예요.
[상태창]
세라 · 호감 40 · 신뢰 42
도윤 · 호감 45 · 신뢰 20
도윤 → 세라 · 긴장 0

User: 세라, 목걸이 사 왔어. 선물이야 (도윤도 옆에서 보고 있다)

Write the next assistant message only, without a label."""
out = []
for i in range(3):
    r = subprocess.run(["claude", "-p", history, "--system-prompt", system, "--output-format", "text",
                        "--tools", "", "--no-session-persistence"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=180)
    text = r.stdout.strip()
    status = text[text.find("[상태창]"):] if "[상태창]" in text else "(상태창 없음)"
    out.append({"narration": text[:text.find("[상태창]")].strip() if "[상태창]" in text else text, "status": status})
    print(f"--- reroll {i+1}\n{status}", flush=True)
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
