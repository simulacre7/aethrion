import fs from "node:fs";

const outputPath = "assets/demo/interactive-demo.cast";
const events = [];
let time = 0;

const header = {
  version: 2,
  width: 120,
  height: 34,
  timestamp: 0,
  title: "Aethrion interactive demo",
  env: {
    SHELL: "/bin/zsh",
    TERM: "xterm-256color",
  },
};

function write(text, delay = 0.35) {
  time += delay;
  events.push([Number(time.toFixed(3)), "o", text]);
}

function writeBlock(text, delay = 0.35) {
  write(`${text.replace(/\n/g, "\r\n")}\r\n`, delay);
}

function typeCommand(command) {
  for (const char of command) {
    write(char, 0.035);
  }

  write("\r\n", 0.08);
}

writeBlock("Aethrion interactive demo\nType help for commands, quit to exit.");
writeBlock(
  [
    "[Status]",
    "  Haru: mood=neutral loneliness=8 jealousy=0",
    "  Mina: mood=neutral loneliness=12 jealousy=0",
    "  Yuna: mood=neutral loneliness=26 jealousy=0",
    "[Relationships]",
    "  mina->user: affinity=40 trust=25 tension=0",
    "  yuna->mina: affinity=10 trust=10 tension=0",
    "  yuna->user: affinity=38 trust=20 tension=0",
  ].join("\n"),
  0.45,
);

write("> ", 0.35);
typeCommand("status");
writeBlock(
  [
    "[Status]",
    "  Haru: mood=neutral loneliness=8 jealousy=0",
    "  Mina: mood=neutral loneliness=12 jealousy=0",
    "  Yuna: mood=neutral loneliness=26 jealousy=0",
    "[Relationships]",
    "  mina->user: affinity=40 trust=25 tension=0",
    "  yuna->mina: affinity=10 trust=10 tension=0",
    "  yuna->user: affinity=38 trust=20 tension=0",
  ].join("\n"),
  0.45,
);

write("> ", 0.4);
typeCommand("gift user mina flower observed_by yuna");
writeBlock(
  [
    "[Rule] Mina affinity toward user +10",
    '[Memory] Mina remembers: "user gave mina a flower."',
    "[Rule] Yuna noticed the gift to Mina",
    "[State] Yuna jealousy +15",
    "[State] Yuna tension toward Mina +8",
    "[Output] relationship_changed mina->user %{affinity: 10}",
    "[Output] memory_created memory:mina:gift:flower:interactive:gift",
    "[Output] relationship_changed yuna->mina %{tension: 8}",
  ].join("\n"),
  0.5,
);
writeBlock(
  [
    "[Status]",
    "  Haru: mood=neutral loneliness=8 jealousy=0",
    "  Mina: mood=neutral loneliness=12 jealousy=0",
    "  Yuna: mood=neutral loneliness=26 jealousy=15",
    "[Relationships]",
    "  mina->user: affinity=50 trust=25 tension=0",
    "  yuna->mina: affinity=10 trust=10 tension=8",
    "  yuna->user: affinity=38 trust=20 tension=0",
  ].join("\n"),
  0.5,
);

write("> ", 0.45);
typeCommand("tick 2");
writeBlock(
  [
    "[Rule] time_tick increased loneliness +8 for active characters",
    '[Output] Yuna -> user: "You seemed really happy with Mina earlier. I guess I was just wondering if you forgot about me."',
  ].join("\n"),
  0.55,
);
writeBlock(
  [
    "[Status]",
    "  Haru: mood=neutral loneliness=16 jealousy=0",
    "  Mina: mood=neutral loneliness=20 jealousy=0",
    "  Yuna: mood=neutral loneliness=34 jealousy=15",
    "[Relationships]",
    "  mina->user: affinity=50 trust=25 tension=0",
    "  yuna->mina: affinity=10 trust=10 tension=8",
    "  yuna->user: affinity=38 trust=20 tension=0",
  ].join("\n"),
  0.5,
);

write("> ", 0.45);
typeCommand("memories");
writeBlock("[Memories]\n  mina: user gave mina a flower. importance=60", 0.45);

write("> ", 0.45);
typeCommand("quit");
writeBlock("bye", 0.25);

fs.writeFileSync(outputPath, `${JSON.stringify(header)}\n${events.map(JSON.stringify).join("\n")}\n`);
