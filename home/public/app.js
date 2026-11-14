// Exocortex home: reads /api/rpc/status (PostgREST -> home.status()) and flips the
// MCP server with POST /api/rpc/mcp_set.
"use strict";

const API = "/api";
const POLL_MS = 5000;
const FAST_POLL_MS = 1000;
const SWITCH_TIMEOUT_MS = 45000;

const $ = (id) => document.getElementById(id);
let last = null;          // last status
let lastAt = 0;           // when it arrived (ms)
let timer = null;
let switching = null;     // {on, until} while a switch is in flight

// ---- tiny DOM helper ---------------------------------------------------------
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "style") el.style.cssText = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : String(kid));
  }
  return el;
}
const dot = (state) => h("span", { class: `st ${state || ""}` });

// ---- formatting ----------------------------------------------------------------
function bytes(n) {
  if (n == null) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}
function ago(epoch) {
  if (!epoch) return "—";
  const s = Math.max(0, Math.round(Date.now() / 1000 - epoch));
  if (s < 45) return "now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
function since(epoch) {
  if (!epoch) return "";
  const s = Math.max(0, Math.round(Date.now() / 1000 - epoch));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

// ---- API -------------------------------------------------------------------------
async function api(path, opts = {}) {
  const res = await fetch(API + path, {
    ...opts,
    headers: { Accept: "application/json", ...(opts.body ? { "Content-Type": "application/json" } : {}) },
    cache: "no-store",
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { /* not JSON */ }
  if (!res.ok) throw new Error((data && (data.message || data.hint)) || `HTTP ${res.status}`);
  return data;
}

async function refresh() {
  clearTimeout(timer);
  try {
    last = await api("/rpc/status");
    lastAt = Date.now();
    $("banner").hidden = true;
    render(last);
  } catch (e) {
    const b = $("banner");
    b.textContent = `Can't reach the home API (${e.message}). Is PostgREST running? home/services.sh status`;
    b.hidden = false;
  }
  updated();
  schedule();
}

function schedule() {
  clearTimeout(timer);
  if (document.hidden) return;
  timer = setTimeout(refresh, switching ? FAST_POLL_MS : POLL_MS);
}

// ---- render: apps ----------------------------------------------------------------
function renderApps(apps) {
  const box = $("apps");
  $("apps-count").textContent = apps.length ? String(apps.length).padStart(2, "0") : "";
  if (!apps.length) {
    box.replaceChildren(h("div", { class: "empty" },
      h("p", { class: "display" }, "No apps yet"),
      h("p", { class: "mono muted small" }, "Apps from their own branches appear here")));
    return;
  }
  box.replaceChildren(...apps.map((a) => {
    const icon = a.icon
      ? h("span", { class: "icon", style: `--icon:url("data:image/svg+xml,${encodeURIComponent(a.icon)}")` })
      : h("span", { class: "letter" }, (a.name || a.id).slice(0, 1).toUpperCase());
    const state = a.ok === null ? "off" : a.ok ? "" : "down";
    return h("a", { class: "app", href: a.path, title: a.description || a.name },
      h("span", { class: "tile" }, icon, dot(state)),
      h("span", { class: "name" }, a.name));
  }));
}

// ---- render: MCP ----------------------------------------------------------------
function renderMcp(m) {
  // While a switch is in flight, show where it's going until the server agrees.
  if (switching && (m.on === switching.on || Date.now() > switching.until)) switching = null;
  const pending = switching ? (switching.on ? "starting" : "stopping") : m.pending;

  const state = $("mcp-state");
  state.textContent = pending ? `${pending}…` : m.on ? "On" : "Off";
  state.classList.toggle("pending", !!pending);

  const sw = $("mcp-switch");
  const target = switching ? switching.on : m.on;
  sw.setAttribute("aria-checked", String(target));
  sw.disabled = !!pending;
  sw.classList.toggle("busy", !!pending);

  const url = $("mcp-url");
  url.hidden = !m.url;
  if (m.url) url.textContent = `${m.url}/mcp`;

  const srv = m.server, tun = m.tunnel;
  const stat = (k, st, v, d) => h("div", { class: "stat" },
    h("div", { class: "k mono small muted" }, st != null ? dot(st) : null, k),
    h("div", { class: "v" }, v), h("div", { class: "d" }, d || " "));
  $("mcp-stats").replaceChildren(
    stat("Server", srv.ok ? "" : m.on || srv.pid ? "down" : "off", srv.ok ? "Up" : "Down",
      srv.pid ? `pid ${srv.pid} · ${bytes(srv.mem)}` : `port ${srv.port}`),
    stat("Tunnel", tun.ok ? "" : tun.pid ? "down" : "off", tun.ok ? "Up" : "Down",
      tun.pid ? `ngrok · ${bytes(tun.mem)}` : "ngrok"),
    stat("Uptime", null, srv.since ? since(srv.since) : "—", srv.ms != null ? `${srv.ms} ms reply` : ""),
    stat("Last call", null, ago(m.last_request), m.last_request ? new Date(m.last_request * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : ""));

  const cmds = m.commands || [];
  $("mcp-commands").replaceChildren(...(cmds.length ? [
    h("h3", {}, "Recent shell commands"),
    ...cmds.map((c) => h("div", {
      class: "cmd", title: c.cwd,
      onclick: (e) => e.currentTarget.classList.toggle("open"),
    }, h("code", {}, c.command), h("time", {}, ago(c.at)))),
  ] : []));
}

// ---- render: system ---------------------------------------------------------------
function meter(label, used, total) {
  const n = 32;
  const frac = total ? used / total : 0;
  const on = Math.round(frac * n);
  return h("div", { class: "meter" },
    h("div", { class: "top-line" },
      h("span", { class: "mono small muted" }, label),
      h("span", { class: "v" }, `${bytes(used)} / ${bytes(total)}`)),
    h("div", { class: "dots", role: "img", "aria-label": `${label} ${Math.round(frac * 100)}% used` },
      Array.from({ length: n }, (_, i) => h("i", { class: i < on ? (frac > 0.9 && i >= n - 3 ? "hot" : "on") : "" }))));
}

function renderSystem(s, services, errors) {
  const mem = s.mem || {}, disk = s.disk || {};
  const box = $("system");
  const svcRows = services.map((v) => h("div", { class: "svc" },
    dot(v.ok ? "" : "down"),
    h("span", { class: "n" }, v.name),
    h("span", { class: "r" }, [v.mem ? bytes(v.mem) : null, v.ok && v.since ? since(v.since) : null].filter(Boolean).join(" · ")),
    h("span", { class: "d" }, v.ok ? v.detail : "not running")));

  const errCount = errors.reduce((n, e) => n + e.errors.length, 0);
  const errBlock = errCount
    ? h("details", { class: "errors" },
        h("summary", {}, dot("down"), `Recent errors · ${errCount}`),
        ...errors.map((e) => [
          h("div", { class: "src", title: e.file }, e.source),
          ...e.errors.map((x) => h("pre", {}, x.line, x.count > 1 ? h("span", { class: "x" }, `  ×${x.count}`) : null)),
        ]))
    : h("p", { class: "mono small muted", style: "margin:18px 0 0" }, "No recent errors");

  box.replaceChildren(
    h("div", { class: "device" },
      h("span", { class: "display" }, s.model || "Phone"),
      h("span", { class: "mono small muted" }, [s.android && `Android ${s.android}`, s.cpus && `${s.cpus} cores`].filter(Boolean).join(" · "))),
    h("div", { class: "meters" },
      meter("Memory", mem.total - mem.available, mem.total),
      meter("Storage", disk.total - disk.free, disk.total)),
    h("h3", {}, `Services · ${bytes(s.ours)} total`),
    ...svcRows,
    errBlock);
}

function render(d) {
  renderApps(d.apps || []);
  renderMcp(d.mcp);
  renderSystem(d.system || {}, d.services || [], d.errors || []);
}

// ---- MCP switch ---------------------------------------------------------------------
$("mcp-switch").addEventListener("click", async () => {
  if (!last) return;
  const on = !last.mcp.on;
  switching = { on, until: Date.now() + SWITCH_TIMEOUT_MS };
  renderMcp(last.mcp);
  try {
    await api("/rpc/mcp_set", { method: "POST", body: JSON.stringify({ enabled: on }) });
    toast(on ? "Starting the MCP server and tunnel…" : "Stopping the MCP server and tunnel…");
  } catch (e) {
    switching = null;
    renderMcp(last.mcp);
    toast(e.message);
  }
  schedule();
});

$("mcp-url").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("mcp-url").textContent);
    toast("URL copied");
  } catch (e) {
    toast("Couldn't copy");
  }
});

// ---- theme: auto -> light -> dark ----------------------------------------------------
const THEMES = ["auto", "light", "dark"];
function applyTheme(t) {
  if (t === "auto") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  $("theme").setAttribute("aria-label", `Theme: ${t}`);
  $("theme").title = `Theme: ${t}`;
}
let theme = "auto";
try { theme = localStorage.getItem("theme") || "auto"; } catch (e) { /* storage blocked */ }
if (!THEMES.includes(theme)) theme = "auto";
applyTheme(theme);
$("theme").addEventListener("click", () => {
  theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
  applyTheme(theme);
  try { localStorage.setItem("theme", theme); } catch (e) { /* storage blocked */ }
});

// ---- clock, "updated", toast ----------------------------------------------------------
function clock() {
  const d = new Date();
  $("clock").textContent = `${d.toLocaleDateString([], { weekday: "short", day: "2-digit", month: "short" })} · ${d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
}
function updated() {
  $("updated").textContent = lastAt ? `Updated ${Math.max(0, Math.round((Date.now() - lastAt) / 1000))}s ago` : "connecting…";
}
let toastTimer = null;
function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}

document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); else clearTimeout(timer); });
setInterval(() => { clock(); updated(); }, 1000);
clock();
refresh();
