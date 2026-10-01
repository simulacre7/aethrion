"""A chat backend's side of Aethrion's HTTP API, standard library only.

    mix aethrion.serve --tick-every 10        # in one terminal
    python3 examples/http_client.py           # in another

Talks to Mina as one user, lets time pass, and polls for what characters
say on their own. Set AETHRION_URL and AETHRION_TOKEN to point it elsewhere.
"""

import json
import os
import time
import urllib.error
import urllib.request

BASE = os.environ.get("AETHRION_URL", "http://127.0.0.1:4848")
TOKEN = os.environ.get("AETHRION_TOKEN")


def call(method, path, body=None):
    headers = {"content-type": "application/json"}
    if TOKEN:
        headers["authorization"] = "Bearer " + TOKEN
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Errors come back as {"error": {"code": ..., "message": ...}}.
        raise RuntimeError(json.load(error)["error"]) from None


def show(lines):
    for line in lines:
        if line["type"] == "character_interaction":
            print(f"  ({line['text']})")
        else:
            print(f"  {line['character_id']}: {line['text']}")


world = "/worlds/python-demo-" + str(int(time.time()))

print("== Chatting with Mina")
for text in ["Good morning, Mina!", "What are you up to today?", "Thanks, that sounds lovely."]:
    print(f"  you: {text}")
    step = call("POST", world + "/say", {"to": "mina", "text": text})
    show(step["lines"])
    cursor = step["last_event_id"]

print("\n== A gift, seen by Yuna, then six hours pass")
step = call("POST", world + "/events", {"type": "gift_received", "from": "user", "to": "mina", "item": "flower", "observed_by": ["yuna"]})
show(step["lines"])
step = call("POST", world + "/events", {"type": "time_tick", "hours": 6})
show(step["lines"])
cursor = step["last_event_id"]

print("\n== How everyone feels about you")
for character in call("GET", world + "/characters")["characters"]:
    toward = character["toward"]
    print(f"  {character['name']}: {character['mood']}, {toward['bond']} (affinity {toward['affinity']}, trust {toward['trust']})")

print("\n== Polling for what characters say on their own (with --tick-every)")
for _ in range(3):
    time.sleep(5)
    for turn in call("GET", f"{world}/conversation?after={cursor}")["turns"]:
        cursor = turn["event_id"] or cursor
        if turn["from"] != "user":
            print(f"  {turn['from']}: {turn['text']}")
