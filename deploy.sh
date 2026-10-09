#!/usr/bin/env bash
# WAHA single-session sender — one-file deploy.
# Copy ONLY this file to your VPS and run:  bash deploy.sh
# It writes all project files, pulls devlikeapro/waha, builds the app, starts everything.
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/waha-single}"
WAHA_PORT="${WAHA_PORT:-3000}"
APP_PORT="${APP_PORT:-3102}"
WRITE_ONLY=0
if [[ "${1:-}" == "--write-only" ]]; then WRITE_ONLY=1; fi

echo "==> App dir: $APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "==> Writing server.js"
cat > server.js <<'DEPLOY_SERVER_EOF'
// Single-session WAHA wrapper: CRUD + canned QR + send + serves UI (index.html)
// ONE session only - name locked, no multi-session support. Zero dependencies.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function loadEnvFile(p) {
  try {
    const txt = fs.readFileSync(p, "utf8");
    for (const line of txt.split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const i = t.indexOf("=");
      if (i === -1) continue;
      const k = t.slice(0, i).trim();
      const v = t.slice(i + 1).trim();
      if (!process.env[k]) process.env[k] = v;
    }
  } catch {}
}
loadEnvFile(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 3102);
const WAHA_URL = (process.env.WAHA_URL || "http://localhost:3002").replace(/\/$/, "");
const WAHA_API_KEY = process.env.WAHA_API_KEY || "";
// THE one and only session - everything is locked to this name
const SESSION = process.env.SINGLE_SESSION || process.env.DEFAULT_SESSION || "default";

if (!WAHA_API_KEY) console.warn("[warn] WAHA_API_KEY is empty - set it in .env");

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

function toChatId(phone) {
  phone = String(phone || "").trim();
  if (phone.includes("@")) return phone;
  return `${phone.replace(/\D/g, "")}@c.us`;
}

async function waha(pathname, options = {}) {
  const r = await fetch(`${WAHA_URL}${pathname}`, {
    ...options,
    headers: { "Content-Type": "application/json", "X-Api-Key": WAHA_API_KEY, ...(options.headers || {}) },
  });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  return { status: r.status, body: json };
}

async function getSession() {
  const s = await waha(`/api/sessions/${SESSION}`);
  if (s.status === 404) return { exists: false, status: null, raw: s.body };
  const st = s.body?.status || null;
  return { exists: true, status: st, working: st === "WORKING", needsQr: st === "SCAN_QR_CODE", raw: s.body };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname;

  // ---- UI ----
  if (req.method === "GET" && (p === "/" || p === "/index.html")) {
    try {
      const html = fs.readFileSync(path.join(__dirname, "index.html"));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Content-Length": html.length });
      return res.end(html);
    } catch {
      return send(res, 500, { ok: false, error: "index.html missing next to server.js" });
    }
  }

  if (req.method === "GET" && p === "/health") {
    return send(res, 200, { ok: true, waha: WAHA_URL, session: SESSION, singleSession: true });
  }

  // ---- SESSION CRUD (single session) ----
  if (req.method === "GET" && (p === "/session" || p === "/status")) {
    const s = await getSession();
    return send(res, 200, { ok: true, session: SESSION, ...s });
  }

  if (req.method === "POST" && p === "/session") {
    const cur = await getSession();
    if (cur.exists && !["STOPPED", "FAILED"].includes(cur.status)) {
      return send(res, 200, { ok: true, created: false, session: SESSION, ...cur });
    }
    const r = await waha(`/api/sessions/start`, { method: "POST", body: JSON.stringify({ name: SESSION }) });
    const after = await getSession();
    return send(res, r.status >= 400 ? r.status : 200, { ok: r.status < 400, created: true, session: SESSION, waha: r.body, current: after });
  }

  if (req.method === "POST" && p === "/session/restart") {
    await waha(`/api/sessions/stop`, { method: "POST", body: JSON.stringify({ name: SESSION }) });
    const r = await waha(`/api/sessions/start`, { method: "POST", body: JSON.stringify({ name: SESSION }) });
    const after = await getSession();
    return send(res, r.status >= 400 ? r.status : 200, { ok: r.status < 400, session: SESSION, waha: r.body, current: after });
  }

  if (req.method === "POST" && p === "/session/stop") {
    const r = await waha(`/api/sessions/stop`, { method: "POST", body: JSON.stringify({ name: SESSION }) });
    return send(res, r.status >= 400 ? r.status : 200, { ok: r.status < 400, session: SESSION, waha: r.body });
  }

  if (req.method === "DELETE" && p === "/session") {
    const logout = await waha(`/api/sessions/logout`, { method: "POST", body: JSON.stringify({ name: SESSION }) });
    const del = await waha(`/api/sessions/${SESSION}`, { method: "DELETE" });
    return send(res, 200, { ok: true, session: SESSION, logout: logout.body, delete: del.body });
  }

  // ---- CANNED QR ----
  if (req.method === "GET" && (p === "/session/qr" || p === "/qr")) {
    const s = await getSession();
    if (!s.exists) return send(res, 404, { ok: false, session: SESSION, error: "No session. POST /session first." });
    if (s.working) return send(res, 200, { ok: true, session: SESSION, working: true, needsQr: false });
    if (!s.needsQr) return send(res, 200, { ok: true, session: SESSION, status: s.status, needsQr: false, hint: "QR not ready yet - poll again in 2s" });
    const qr = await fetch(`${WAHA_URL}/api/${SESSION}/auth/qr?format=image`, {
      headers: { "X-Api-Key": WAHA_API_KEY },
    });
    const buf = Buffer.from(await qr.arrayBuffer());
    if (url.searchParams.get("format") === "image") {
      res.writeHead(200, { "Content-Type": "image/png", "Content-Length": buf.length });
      return res.end(buf);
    }
    return send(res, 200, {
      ok: true, session: SESSION, status: s.status, needsQr: true,
      qrDataUrl: `data:image/png;base64,${buf.toString("base64")}`,
      hint: "Show qrDataUrl in <img src>, or use ?format=image for raw PNG",
    });
  }

  // ---- SEND (locked to the single session) ----
  if (req.method === "POST" && p === "/send") {
    let payload;
    try { payload = JSON.parse((await readBody(req)) || "{}"); }
    catch { return send(res, 400, { ok: false, error: "Invalid JSON" }); }
    if (payload.session && payload.session !== SESSION) {
      return send(res, 400, { ok: false, error: `Single-session mode: only '${SESSION}' allowed` });
    }
    const phone = payload.phone || payload.phoneNumber || payload.to;
    const message = payload.message || payload.text || payload.msg;
    if (!phone) return send(res, 400, { ok: false, error: "Missing 'phone'. Example: { phone: '919876543210', message: 'Hi' }" });
    if (!message) return send(res, 400, { ok: false, error: "Missing 'message'. Example: { phone: '919876543210', message: 'Hi' }" });

    const s = await getSession();
    if (!s.exists) return send(res, 409, { ok: false, error: "No session. POST /session first, then scan QR via the UI" });
    if (!s.working) return send(res, 409, { ok: false, error: `Session '${SESSION}' is ${s.status} - scan QR via the UI`, status: s.status });

    const chatId = toChatId(phone);
    const result = await waha(`/api/sendText`, { method: "POST", body: JSON.stringify({ chatId, text: message, session: SESSION }) });
    if (result.status >= 400) return send(res, result.status, { ok: false, chatId, session: SESSION, waha: result.body });
    return send(res, 200, { ok: true, phone: String(phone), chatId, session: SESSION, waha: result.body });
  }

  return send(res, 404, {
    ok: false,
    error: "Use: GET /, GET /session, POST /session, POST /session/restart, POST /session/stop, DELETE /session, GET /session/qr, POST /send {phone,message}",
  });
});

server.listen(PORT, () => {
  console.log(`WAHA single-session app on http://localhost:${PORT} (session='${SESSION}', waha=${WAHA_URL})`);
});
DEPLOY_SERVER_EOF

echo "==> Writing index.html"
cat > index.html <<'DEPLOY_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>WAHA Sender — Single Session</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; display: flex; justify-content: center; padding: 24px 12px; }
  .wrap { width: 100%; max-width: 520px; display: flex; flex-direction: column; gap: 16px; }
  h1 { font-size: 20px; text-align: center; }
  h1 span { color: #25d366; }
  .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 16px; }
  .card h2 { font-size: 14px; text-transform: uppercase; letter-spacing: .05em; color: #94a3b8; margin-bottom: 12px; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .badge { display: inline-block; padding: 4px 12px; border-radius: 999px; font-size: 13px; font-weight: 600; }
  .b-work { background: #14532d; color: #86efac; }
  .b-qr { background: #713f12; color: #fde68a; }
  .b-off { background: #3f3f46; color: #d4d4d8; }
  button { background: #334155; color: #e2e8f0; border: 1px solid #475569; border-radius: 8px; padding: 8px 14px; font-size: 14px; cursor: pointer; }
  button:hover { background: #475569; }
  button.primary { background: #25d366; border-color: #25d366; color: #052e16; font-weight: 700; }
  button.primary:hover { background: #1fb857; }
  button.danger { background: transparent; border-color: #7f1d1d; color: #fca5a5; }
  input, textarea { width: 100%; background: #0f172a; border: 1px solid #334155; border-radius: 8px; color: #e2e8f0; padding: 10px 12px; font-size: 15px; margin-bottom: 10px; }
  textarea { min-height: 80px; resize: vertical; }
  label { display: block; font-size: 13px; color: #94a3b8; margin-bottom: 4px; }
  #qr { display: block; margin: 12px auto 0; width: 240px; height: 240px; border-radius: 8px; background: #fff; }
  .hint { font-size: 13px; color: #94a3b8; margin-top: 8px; text-align: center; }
  #log { font-family: monospace; font-size: 12px; background: #020617; border-radius: 8px; padding: 10px; max-height: 180px; overflow-y: auto; white-space: pre-wrap; word-break: break-word; }
  .ok { color: #86efac; } .err { color: #fca5a5; }
</style>
</head>
<body>
<div class="wrap">
  <h1><span>WAHA</span> Sender — one session</h1>

  <div class="card">
    <h2>Session</h2>
    <div class="row">
      <span id="badge" class="badge b-off">…</span>
      <button onclick="api('POST','/session').then(refresh)">Start</button>
      <button onclick="api('POST','/session/restart').then(refresh)">Restart</button>
      <button onclick="api('POST','/session/stop').then(refresh)">Stop</button>
      <button class="danger" onclick="api('DELETE','/session').then(refresh)">Delete</button>
      <button onclick="refresh()">↻</button>
    </div>
    <img id="qr" style="display:none" alt="Scan with WhatsApp" />
    <div id="qrhint" class="hint"></div>
  </div>

  <div class="card">
    <h2>Send message</h2>
    <label>Phone number (digits only, with country code)</label>
    <input id="phone" placeholder="919876543210" inputmode="tel" />
    <label>Message</label>
    <textarea id="msg" placeholder="Hello!"></textarea>
    <button class="primary" onclick="sendMsg()" style="width:100%">Send</button>
  </div>

  <div class="card">
    <h2>Log</h2>
    <div id="log"></div>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
function log(msg, cls) {
  const el = document.createElement('div');
  if (cls) el.className = cls;
  el.textContent = (cls === 'err' ? '✗ ' : '✓ ') + msg;
  $('log').prepend(el);
}
async function api(method, path, body) {
  const r = await fetch(path, { method, headers: {'Content-Type':'application/json'}, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok && !j.ok) log(`${method} ${path} → ${j.error || r.status}`, 'err');
  return j;
}
async function refresh() {
  try {
    const s = await api('GET', '/session');
    const b = $('badge');
    b.textContent = s.exists ? s.status : 'NO SESSION';
    b.className = 'badge ' + (s.working ? 'b-work' : s.needsQr ? 'b-qr' : 'b-off');
    const qr = $('qr'), hint = $('qrhint');
    if (s.needsQr) {
      qr.src = '/session/qr?format=image&t=' + Date.now();
      qr.style.display = 'block';
      hint.textContent = 'Scan with WhatsApp → Linked devices → Link a device';
    } else {
      qr.style.display = 'none';
      hint.textContent = s.working ? 'Connected ✓ — you can send messages' : (s.exists ? 'Waiting… auto-refreshing' : 'Press Start to create the session');
    }
    return s;
  } catch (e) { log('refresh failed: ' + e.message, 'err'); }
}
async function sendMsg() {
  const phone = $('phone').value.trim(), message = $('msg').value.trim();
  if (!phone || !message) return log('Enter phone + message', 'err');
  const j = await api('POST', '/send', { phone, message });
  if (j.ok) { log(`Sent to ${j.chatId}`); $('msg').value = ''; }
  else if (j.error) log(j.error, 'err');
}
refresh();
setInterval(async () => {
  const b = $('badge').textContent;
  if (b !== 'WORKING') refresh();
}, 3000);
</script>
</body>
</html>
DEPLOY_HTML_EOF

echo "==> Writing Dockerfile"
cat > Dockerfile <<'DEPLOY_DOCKER_EOF'
FROM node:20-alpine
WORKDIR /app
COPY server.js index.html ./
ENV PORT=3102
EXPOSE 3102
CMD ["node", "server.js"]
DEPLOY_DOCKER_EOF

echo "==> Writing docker-compose.yml"
cat > docker-compose.yml <<'DEPLOY_COMPOSE_EOF'
services:
  waha:
    image: devlikeapro/waha:latest
    env_file: .env
    volumes:
      - waha-sessions:/app/.sessions
    ports:
      - "${WAHA_PORT:-3000}:3000"
    restart: unless-stopped

  app:
    build: .
    env_file: .env
    environment:
      WAHA_URL: http://waha:3000
      PORT: 3102
    ports:
      - "${APP_PORT:-3102}:3102"
    depends_on:
      - waha
    restart: unless-stopped

volumes:
  waha-sessions:
DEPLOY_COMPOSE_EOF

if [[ ! -f .env ]]; then
  echo "==> Generating .env with fresh secrets"
  randhex() { openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32; }
  API_KEY="$(randhex)"
  DASH_PASS="$(randhex)"
  cat > .env <<EOF
WAHA_API_KEY=$API_KEY
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=$DASH_PASS
WHATSAPP_SWAGGER_USERNAME=admin
WHATSAPP_SWAGGER_PASSWORD=$DASH_PASS
WAHA_DASHBOARD_ENABLED=True
WHATSAPP_SWAGGER_ENABLED=True
SINGLE_SESSION=default
WAHA_PORT=$WAHA_PORT
APP_PORT=$APP_PORT
WAHA_URL=http://waha:3000
PORT=3102
EOF
else
  echo "==> .env exists, keeping it"
fi

if [[ "$WRITE_ONLY" == "1" ]]; then
  echo "==> --write-only: files written, skipping docker"
  exit 0
fi

command -v docker >/dev/null || { echo "ERROR: docker not found. Install docker first."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' plugin not found."; exit 1; }

echo "==> Pulling WAHA image (devlikeapro/waha)"
docker pull devlikeapro/waha:latest

echo "==> Building + starting (waha + app)"
docker compose up -d --build

echo "==> Waiting for app..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null "http://localhost:$APP_PORT/health"; then break; fi
  sleep 2
done

echo ""
echo "================ DONE ================"
echo "UI + API : http://$(curl -s ifconfig.me 2>/dev/null || echo '<server-ip>'):$APP_PORT  (local: http://localhost:$APP_PORT)"
echo "WAHA dash: port $WAHA_PORT (/dashboard, user admin, pass in .env)"
echo "Send test: curl -X POST http://localhost:$APP_PORT/send -H 'Content-Type: application/json' -d '{\"phone\":\"919876543210\",\"message\":\"Hi\"}'"
echo " creds  : cat $APP_DIR/.env | grep -E 'API_KEY|PASSWORD'"
echo " logs   : cd $APP_DIR && docker compose logs -f"
echo "Open the UI, press Start, scan the QR, then send."
