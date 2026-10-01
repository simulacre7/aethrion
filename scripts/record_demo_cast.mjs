// Records a real `mix demo.interactive` session as an asciinema v2 cast.
//
//   node scripts/record_demo_cast.mjs
//
// Commands are typed into the running demo one at a time; everything shown is
// the demo's actual output, replayed with typing and streaming delays so it
// reads like a live session. Writes assets/demo/interactive-demo.cast and a
// plain-text transcript next to it.

import { spawn } from "node:child_process";
import fs from "node:fs";

const castPath = "assets/demo/interactive-demo.cast";
const transcriptPath = "assets/demo/interactive-demo.txt";

const commands = [
  "gift user mina flower observed_by yuna",
  "tick 2",
  "say haru thank you for looking after Yuna",
  "why yuna jealousy",
  "quit",
];

const strip = (text) => text.replace(/\x1b\[[0-9;]*m/g, "");
const isPrompt = (buffer) => strip(buffer).endsWith("user> ");

const child = spawn("mix", ["demo.interactive", "--no-status"], {
  env: { ...process.env, MIX_ENV: "dev", FORCE_COLOR: "1" },
  stdio: ["pipe", "pipe", "inherit"],
});

let buffer = "";
let waiting = null;

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  if (waiting && isPrompt(buffer)) {
    const done = waiting;
    waiting = null;
    done();
  }
});

const untilPrompt = () =>
  new Promise((resolve) => {
    if (isPrompt(buffer)) return resolve();
    waiting = resolve;
  });

const untilExit = () => new Promise((resolve) => child.on("close", resolve));

const takeBuffer = () => {
  const text = buffer;
  buffer = "";
  return text;
};

// Cast building.
const events = [];
let time = 0;
const write = (text, delay = 0) => {
  time += delay;
  events.push([Number(time.toFixed(3)), "o", text]);
};

const promptPattern = /(\x1b\[[0-9;]*m)*user(\x1b\[[0-9;]*m)*> (\x1b\[[0-9;]*m)*$/;

function streamOutput(text, { lineDelay = 0.07, tokenDelay = 0.012 } = {}) {
  const body = text.replace(promptPattern, "");
  const prompt = text.slice(body.length);

  for (const line of body.split("\n")) {
    const parts = line.split(/(\x1b\[[0-9;]*m)/g).filter(Boolean);
    for (const part of parts) {
      if (part.startsWith("\x1b[")) {
        write(part);
        continue;
      }
      for (const token of part.match(/\s+|\S+/g) ?? []) write(token, tokenDelay);
    }
    write("\r\n", lineDelay);
  }

  // The trailing newline of the last line is part of `split`; remove the extra one.
  events.pop();
  if (prompt) write(prompt, 0.6);
}

function typeCommand(command) {
  for (const char of command) write(char, 0.045);
  write("\r\n", 0.25);
}

const transcript = [];

await untilPrompt();
let output = takeBuffer();
streamOutput(output, { lineDelay: 0.12, tokenDelay: 0.02 });
transcript.push(strip(output));

for (const command of commands) {
  typeCommand(command);
  transcript.push(command + "\n");
  child.stdin.write(command + "\n");

  if (command === "quit") {
    await untilExit();
    output = takeBuffer();
  } else {
    await untilPrompt();
    output = takeBuffer();
  }

  streamOutput(output);
  transcript.push(strip(output));
}

write("", 4.0);

const header = {
  version: 2,
  width: 112,
  height: 34,
  timestamp: 0,
  title: "Aethrion interactive demo",
  env: { SHELL: "/bin/zsh", TERM: "xterm-256color" },
};

fs.writeFileSync(castPath, [JSON.stringify(header), ...events.map((e) => JSON.stringify(e))].join("\n") + "\n");
fs.writeFileSync(transcriptPath, transcript.join(""));
console.log(`wrote ${castPath} (${events.length} frames, ${time.toFixed(1)}s) and ${transcriptPath}`);
