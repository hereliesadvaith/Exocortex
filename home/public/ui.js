// Exocortex shared script for apps under http://localhost/<app>/.
// Load it in <head> (not deferred) so the theme applies before the first paint:
//   <link rel="stylesheet" href="/ui.css"><script src="/ui.js"></script>
"use strict";

// The home page saves auto / light / dark in localStorage; apps are on the same
// origin, so they follow it.
try {
  const t = localStorage.getItem("theme");
  if (t === "light" || t === "dark") document.documentElement.dataset.theme = t;
} catch (e) { /* storage blocked: follow the system */ }

window.exo = {
  /**
   * Call a function in the app's schema through PostgREST (/api/rpc/<fn>).
   * read: true sends a GET (for STABLE functions), otherwise a POST with a JSON body.
   * Resolves to the function's result (null for void); rejects with an Error
   * carrying Postgres's message.
   */
  async rpc(schema, fn, args = {}, { read = false } = {}) {
    let url = `/api/rpc/${encodeURIComponent(fn)}`;
    const opts = { headers: { Accept: "application/json" }, cache: "no-store" };
    if (read) {
      opts.method = "GET";
      opts.headers["Accept-Profile"] = schema;
      const q = new URLSearchParams();
      for (const [k, v] of Object.entries(args)) if (v != null) q.set(k, v);
      if ([...q].length) url += `?${q}`;
    } else {
      opts.method = "POST";
      opts.headers["Content-Profile"] = schema;
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(args);
    }
    const res = await fetch(url, opts);
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = text; }
    if (!res.ok) {
      const msg = (data && typeof data === "object" && (data.message || data.hint)) || `HTTP ${res.status}`;
      throw new Error(String(msg).replace(/^plpy\.Error:\s*/, ""));
    }
    return data;
  },

  /** A short message at the bottom of the screen. */
  toast(msg, ms = 3000) {
    let t = document.getElementById("exo-toast");
    if (!t) {
      t = document.createElement("div");
      t.id = "exo-toast";
      t.className = "toast mono";
      t.setAttribute("role", "status");
      document.body.append(t);
    }
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(this._toastTimer);
    this._toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  },
};
