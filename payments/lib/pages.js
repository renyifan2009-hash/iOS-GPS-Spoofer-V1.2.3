// The few pages a buyer sees in Safari, in the app's soft sage tones.
import { escapeHTML } from "./license.js";

function shell(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escapeHTML(title)} · AnyWhere</title>
<style>
  :root { --bg: #f4f2ee; --card: #ffffff; --text: #1f2a2b; --muted: #5d6b6a; --accent: #5e8b85; --accent-text: #38635e; --line: #e4e0d8; }
  @media (prefers-color-scheme: dark) { :root { --bg: #141b1c; --card: #1e2829; --text: #eef2f1; --muted: #a3b2b0; --accent: #7fa9a2; --accent-text: #9cc7bf; --line: #2c3839; } }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px; background: var(--bg); color: var(--text);
         font: 17px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  main { width: 100%; max-width: 420px; background: var(--card); border: 1px solid var(--line); border-radius: 24px; padding: 28px 24px; }
  h1 { font: 700 26px/1.2 ui-rounded, -apple-system, system-ui, sans-serif; margin: 0 0 8px; }
  p { margin: 0 0 16px; color: var(--muted); }
  .key { font: 600 15px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; padding: 14px; border-radius: 14px;
         background: var(--bg); border: 1px solid var(--line); color: var(--text); margin: 0 0 16px; user-select: all; }
  a.button, button { display: block; width: 100%; text-align: center; padding: 15px 18px; border-radius: 999px; border: 0; cursor: pointer;
         background: var(--accent); color: #fff; font: 600 17px/1 -apple-system, system-ui, sans-serif; text-decoration: none; margin: 0 0 10px; }
  button.quiet { background: transparent; color: var(--accent-text); }
  small { display: block; color: var(--muted); font-size: 13px; margin-top: 8px; }
</style>
</head>
<body><main>${body}</main></body>
</html>`;
}

export function successPage(key) {
  const link = `anywhere://activate?key=${encodeURIComponent(key)}`;
  return shell("You're in", `
  <h1>You're in.</h1>
  <p>Thanks for supporting AnyWhere. This is your license key. Keep it somewhere safe: it restores Pro on a new iPhone.</p>
  <div class="key" id="key">${escapeHTML(key)}</div>
  <a class="button" href="${escapeHTML(link)}">Open AnyWhere</a>
  <button class="quiet" type="button" onclick="navigator.clipboard.writeText(document.getElementById('key').textContent).then(()=>{this.textContent='Copied'})">Copy key</button>
  <small>If AnyWhere doesn't open, copy the key and paste it in AnyWhere ▸ Settings ▸ Enter License Key.</small>
  <script>setTimeout(function(){ location.href = ${JSON.stringify(link)}; }, 900);</script>`);
}

export function pendingPage() {
  return shell("Almost there", `
  <h1>Almost there.</h1>
  <p>Your payment is still being confirmed. This page will have your license key in a moment.</p>
  <script>setTimeout(function(){ location.reload(); }, 4000);</script>`);
}

export function messagePage(title, text) {
  return shell(title, `
  <h1>${escapeHTML(title)}</h1>
  <p>${escapeHTML(text)}</p>
  <a class="button" href="anywhere://">Back to AnyWhere</a>`);
}
