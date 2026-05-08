import fs from "node:fs";

const outputPath = "assets/demo/interactive-demo.cast";
const events = [];
let time = 0;

const ansi = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  cyan: "\x1b[36m",
  blue: "\x1b[34m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  magenta: "\x1b[35m",
};

const header = {
  version: 2,
  width: 112,
  height: 30,
  timestamp: 0,
  title: "Aethrion interactive demo",
  env: {
    SHELL: "/bin/zsh",
    TERM: "xterm-256color",
  },
};

function write(text, delay = 0.3) {
  time += delay;
  events.push([Number(time.toFixed(3)), "o", text]);
}

function line(text = "", delay = 0.2) {
  write(`${text}\r\n`, delay);
}

function streamLine(text = "", options = {}) {
  const tokenDelay = options.tokenDelay ?? 0.035;
  const lineDelay = options.lineDelay ?? 0.12;
  const parts = text.split(/(\x1b\[[0-9;]*m)/g).filter(Boolean);

  for (const part of parts) {
    if (part.startsWith("\x1b[")) {
      write(part, 0);
      continue;
    }

    for (const token of part.match(/\s+|\S+/g) ?? []) {
      write(token, tokenDelay);
    }
  }

  write("\r\n", lineDelay);
}

function block(lines, options = {}) {
  const beforeDelay = options.beforeDelay ?? 0.25;
  const lineDelay = options.lineDelay ?? 0.1;
  const tokenDelay = options.tokenDelay ?? 0.03;

  write("", beforeDelay);

  for (const item of lines) {
    streamLine(item, { tokenDelay, lineDelay });
  }
}

function prompt() {
  write(`${ansi.bold}${ansi.green}user${ansi.reset}${ansi.dim}> ${ansi.reset}`, 0.55);
}

function typeCommand(command) {
  for (const char of command) {
    write(char, 0.04);
  }

  write("\r\n", 0.15);
}

function tag(label, color, text) {
  return `${color}${ansi.bold}${label.padEnd(9)}${ansi.reset}${text}${ansi.reset}`;
}

function section(title) {
  return `${ansi.bold}${title}${ansi.reset}`;
}

function faint(text) {
  return `${ansi.dim}${text}${ansi.reset}`;
}

block(
  [
    `${ansi.bold}${ansi.cyan}Aethrion${ansi.reset}${ansi.dim}  early alpha${ansi.reset}`,
    faint("A shared social layer for persistent AI characters."),
    `${ansi.yellow}LLMs generate expression; deterministic rules drive the simulation.${ansi.reset}`,
  ],
  { beforeDelay: 0.15, tokenDelay: 0.035, lineDelay: 0.1 },
);

line("Type help for commands, quit to exit.", 0.45);
line("", 0.25);
block(
  [
    section("Characters"),
    faint("  name       mood       lonely  jealous"),
    faint("  ---------  ---------  ------  -------"),
    "  Haru     neutral    8       0",
    "  Mina     neutral    12      0",
    "  Yuna     neutral    26      0",
    "",
    section("Relationships"),
    faint("  edge         affinity  trust  tension"),
    faint("  -----------  --------  -----  -------"),
    "  mina->user   40        25     0",
    "  yuna->mina   10        10     0",
    "  yuna->user   38        20     0",
    "",
  ],
  { beforeDelay: 0.15, tokenDelay: 0.01, lineDelay: 0.04 },
);

prompt();
typeCommand("gift user mina flower observed_by yuna");
block(
  [
    tag("RULE", ansi.magenta, "Mina affinity toward user +10"),
    tag("MEMORY", ansi.green, 'Mina remembers: "user gave mina a flower."'),
    tag("RULE", ansi.magenta, "Yuna noticed the gift to Mina"),
    tag("STATE", ansi.yellow, "Yuna jealousy +15"),
    tag("STATE", ansi.yellow, "Yuna tension toward Mina +8"),
    tag("EFFECT", ansi.cyan, "relationship_changed mina->user %{affinity: 10}"),
    tag("EFFECT", ansi.cyan, "memory_created memory:mina:gift:flower:interactive:gift"),
    tag("EFFECT", ansi.cyan, "relationship_changed yuna->mina %{tension: 8}"),
  ],
  { beforeDelay: 0.25, tokenDelay: 0.02, lineDelay: 0.08 },
);
line("", 0.3);
block(
  [
    section("Characters"),
    faint("  name       mood       lonely  jealous"),
    faint("  ---------  ---------  ------  -------"),
    "  Haru     neutral    8       0",
    "  Mina     neutral    12      0",
    "  Yuna     neutral    26      15",
    "",
    section("Relationships"),
    faint("  edge         affinity  trust  tension"),
    faint("  -----------  --------  -----  -------"),
    "  mina->user   50        25     0",
    "  yuna->mina   10        10     8",
    "  yuna->user   38        20     0",
    "",
  ],
  { beforeDelay: 0.18, tokenDelay: 0.01, lineDelay: 0.04 },
);

prompt();
typeCommand("tick 2");
block(
  [
    tag("RULE", ansi.magenta, "time_tick increased loneliness +8 for active characters"),
    tag("OUTPUT", ansi.cyan, 'Yuna -> user: "You looked happy with Mina earlier. I wondered if you forgot about me."'),
    tag("EFFECT", ansi.cyan, "proactive_message yuna->user reason=jealous"),
  ],
  { beforeDelay: 0.25, tokenDelay: 0.02, lineDelay: 0.08 },
);
line("", 0.3);
block(
  [
    section("Characters"),
    faint("  name       mood       lonely  jealous"),
    faint("  ---------  ---------  ------  -------"),
    "  Haru     neutral    16      0",
    "  Mina     neutral    20      0",
    "  Yuna     neutral    34      15",
    "",
  ],
  { beforeDelay: 0.18, tokenDelay: 0.01, lineDelay: 0.04 },
);

prompt();
typeCommand("memories");
block(
  [
    section("Memories"),
    `  ${ansi.bold}mina${ansi.reset} remembers "user gave mina a flower." ${faint("importance=60")}`,
    "",
  ],
  { beforeDelay: 0.2, tokenDelay: 0.02, lineDelay: 0.08 },
);

prompt();
typeCommand("quit");
line("bye", 0.35);
write("", 4.0);

fs.writeFileSync(outputPath, `${JSON.stringify(header)}\n${events.map(JSON.stringify).join("\n")}\n`);
