// Captures a SillyTavern chat at twice the pixel density with a headless
// Chrome driven over the DevTools protocol, for the demo GIFs: the last
// reply as it is, after each of `--swipes` new swipes, and with "this
// turn" unfolded. SillyTavern must be running with its API set to Aethrion
// and the character's chat begun; no screen is needed.
//
// Usage: node scripts/demo/st_capture.mjs out-dir [--character Sinmarked]
//          [--swipes 2] [--lang en] [--url http://localhost:8000/]
//          [--new-chat] [--greeting 1] [--say "a line to send first"]...
//          [--size 820x1180]
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

const args = process.argv.slice(2);
const out = resolve(args[0]);
const opt = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const swipes = Number(opt("--swipes", "2"));
const lang = opt("--lang", "en");
const url = opt("--url", "http://localhost:8000/");
const say = args.flatMap((a, i) => (a === "--say" ? [args[i + 1]] : []));
const character = opt("--character", "Sinmarked");
const newChat = args.includes("--new-chat");
const greeting = Number(opt("--greeting", "0"));
const [width, height] = opt("--size", "820x1180").split("x").map(Number);
const port = 9333;

mkdirSync(out, { recursive: true });
const profile = join(out, ".profile");
rmSync(profile, { recursive: true, force: true });
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  `--lang=${lang}`, `--window-size=${width},${height}`, "--hide-scrollbars", "about:blank",
], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try {
    const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    target = pages.find((p) => p.type === "page");
  } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const waiting = new Map();
ws.onmessage = (m) => {
  const data = JSON.parse(m.data);
  if (data.id && waiting.has(data.id)) { waiting.get(data.id)(data); waiting.delete(data.id); }
};
const send = (method, params = {}) => new Promise((r) => { waiting.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result.result.value;
};
const until = async (expression, what, timeout = 180000) => {
  for (const start = Date.now(); Date.now() - start < timeout; await sleep(500)) if (await js(expression)) return;
  throw new Error("timed out waiting for " + what);
};
const shot = async (name) => {
  // A panel left open (importing a lorebook opens World Info) would cover the chat.
  await js(`document.querySelectorAll('.drawer-content.openDrawer').forEach(d => d.closest('.drawer')?.querySelector('.drawer-toggle')?.click())`);
  await sleep(600);
  await js(`(() => { const c = document.querySelector('#chat'); c.scrollTop = c.scrollHeight; })()`);
  await sleep(700);
  const r = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(out, name), Buffer.from(r.result.data, "base64"));
  console.log("wrote", name);
};
const idle = `(() => { const s = document.querySelector('#mes_stop'); return !s || getComputedStyle(s).display === 'none'; })()`;
const status = `document.querySelector('#chat .mes:last-child .mes_text')?.innerText.includes('·')`;

try {
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false });
  await send("Page.addScriptToEvaluateOnNewDocument", { source: `localStorage.setItem('language', ${JSON.stringify(lang)});` });
  await send("Page.navigate", { url });
  await until(`document.querySelectorAll('#rm_print_characters_block .character_select').length > 0`, "SillyTavern to load");
  await sleep(1500);
  await js(`[...document.querySelectorAll('#rm_print_characters_block .character_select')].find(e => e.querySelector('.ch_name')?.innerText === ${JSON.stringify(character)}).click()`);
  await until(`document.querySelector('#chat .mes .name_text')?.innerText === ${JSON.stringify(character)}`, "the character's chat to open");
  // A card with a lorebook asks whether to import it; a fresh browser profile is asked every time.
  for (let i = 0; i < 3; i++) {
    await sleep(1500);
    if (!(await js(`(() => { const ok = document.querySelector('dialog[open] .popup-button-ok'); if (ok) ok.click(); return !!ok; })()`))) break;
  }
  await js(`document.querySelector('#api_button_openai')?.click()`);
  await until(`[...document.querySelectorAll('.online_status_text')].some(e => e.innerText === 'Valid')`, "the API to connect", 30000);

  if (newChat) {
    await js(`document.querySelector('#option_start_new_chat').click()`);
    await sleep(1000);
    await js(`document.querySelector('dialog[open] .popup-button-ok')?.click()`);
    await until(`document.querySelectorAll('#chat .mes').length === 1`, "a new chat");
    await sleep(1500);
  }
  // An alternate first message: the card's other languages and openings.
  for (let i = 0; i < greeting; i++) {
    await js(`document.querySelector('#chat .mes .swipe_right').click()`);
    await sleep(1200);
  }

  for (const line of say) {
    const before = await js(`document.querySelectorAll('#chat .mes').length`);
    await js(`(() => { const t = document.querySelector('#send_textarea'); t.value = ${JSON.stringify(line)}; t.dispatchEvent(new Event('input', {bubbles: true})); document.querySelector('#send_but').click(); })()`);
    await until(`document.querySelectorAll('#chat .mes').length >= ${before + 2}`, "the reply to start");
    await sleep(2500);
    await until(idle, "the reply");
    await until(status, "the status block", 20000);
    await sleep(1200);
    console.log("said", line);
  }

  await shot("1.png");
  for (let n = 2; n <= swipes + 1; n++) {
    await js(`document.querySelector('#chat .mes:last-child .swipe_right').click()`);
    await sleep(2500);
    await until(idle, "swipe " + n);
    await until(status, "the status block of swipe " + n, 20000);
    await sleep(1200);
    await shot(n + ".png");
  }
  await js(`document.querySelectorAll('#chat .mes:last-child details').forEach(d => d.open = true)`);
  await shot("rulings.png");
  console.log(await js(`document.querySelector('#chat .mes:last-child .mes_text').innerText.slice(-600)`));
} finally {
  ws.close();
  chrome.kill();
}
