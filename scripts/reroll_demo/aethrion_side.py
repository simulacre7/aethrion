# The right side of assets/demo/reroll.png (and reroll.en.png): the same
# campfire scene sent three times to a running Aethrion
# (`mix aethrion.serve --cast priv/casts/campfire[_en].json --llm claude`),
# as a chat app's reroll would send it.
#
# Usage: AETHRION_TOKEN=... python3 scripts/reroll_demo/aethrion_side.py out.json [ko|en] [port]
import json, os, re, sys, urllib.request

TEXT = {
    "ko": {"greeting": "(밤의 야영지. 모닥불이 탁탁 튄다. 하린은 정찰을 나갔다.)\n세라: 하린 씨가 돌아오려면 몇 시간은 걸릴 거예요. …그런데 저 덤불, 아까부터 뭔가 움직여요.",
           "line": "세라, 목걸이 사 왔어. 선물이야"},
    "en": {"greeting": "(Night at camp. The fire crackles. Harin is out scouting.)\nSera: Harin won't be back for a few hours. …But that bush over there. Something has been moving in it for a while.",
           "line": "Sera, I bought you a necklace. It's a gift."},
}
lang = sys.argv[2] if len(sys.argv) > 2 else "ko"
port = sys.argv[3] if len(sys.argv) > 3 else "4848"
text = TEXT[lang]
body = json.dumps({"model": "aethrion", "messages": [
    {"role": "assistant", "content": text["greeting"]}, {"role": "user", "content": text["line"]}]}).encode()
out = []
for i in range(3):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", body,
                                 {"content-type": "application/json", "authorization": "Bearer " + os.environ["AETHRION_TOKEN"]})
    reply = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]["content"]
    m = re.search(r"<aethrion-status[^>]*>(.*?)(<aethrion-turn.*)?</aethrion-status>", reply, re.S)
    status = m.group(1).strip()
    out.append({"narration": reply[:m.start()].strip(), "status": status})
    print(f"--- reroll {i+1}\n{status}", flush=True)
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
