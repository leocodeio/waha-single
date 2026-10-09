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
