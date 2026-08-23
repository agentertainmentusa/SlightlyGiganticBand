/* =====================================================================
   Slightly Gigantic — Data layer
   Talks to Supabase for content + photos. Falls back to localStorage
   if Supabase is unreachable, so the site never appears broken.
   ===================================================================== */
(function (global) {
  const cfg = global.SG_CONFIG;
  if (!cfg) {
    console.error("[SG] config.js not loaded");
    return;
  }
  const URL = cfg.SUPABASE_URL;
  const KEY = cfg.SUPABASE_ANON_KEY;
  const BUCKET = cfg.PHOTO_BUCKET || "band-photos";

  const LS_CACHE_KEY = "SG_CONTENT_V1";   // fallback cache + legacy key

  function headers(extra) {
    return Object.assign(
      {
        "apikey": KEY,
        "Authorization": "Bearer " + KEY,
        "Content-Type": "application/json"
      },
      extra || {}
    );
  }

  async function fetchContent() {
    try {
      const r = await fetch(`${URL}/rest/v1/site_content?select=data&id=eq.1`, {
        headers: headers(),
        cache: "no-store"
      });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const rows = await r.json();
      const data = rows && rows[0] ? rows[0].data : null;
      if (data) {
        // cache locally for offline / fast reload
        try { localStorage.setItem(LS_CACHE_KEY, JSON.stringify(data)); } catch (e) {}
        return data;
      }
    } catch (e) {
      console.warn("[SG] Supabase read failed, using cache:", e.message);
    }
    // fall back to local cache
    try { return JSON.parse(localStorage.getItem(LS_CACHE_KEY) || "null"); }
    catch (e) { return null; }
  }

  async function saveContent(pass, payload) {
    const r = await fetch(`${URL}/rest/v1/rpc/save_site_content`, {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ pass: pass, payload: payload })
    });
    if (r.status === 204 || r.ok) {
      try { localStorage.setItem(LS_CACHE_KEY, JSON.stringify(payload)); } catch (e) {}
      return { ok: true };
    }
    let err;
    try { err = await r.json(); } catch (e) { err = { message: "HTTP " + r.status }; }
    if (err && err.code === "28000") return { ok: false, code: "unauthorized" };
    return { ok: false, code: "error", message: err.message || "Save failed" };
  }

  // Non-destructive password check. Used by the login probe so we don't write
  // anything to site_content just to verify credentials.
  async function verifyPassword(pass) {
    try {
      const r = await fetch(`${URL}/rest/v1/rpc/verify_admin_password`, {
        method: "POST",
        headers: headers(),
        body: JSON.stringify({ pass: pass })
      });
      if (!r.ok) {
        let err;
        try { err = await r.json(); } catch (e) { err = { message: "HTTP " + r.status }; }
        return { ok: false, code: "error", message: err.message || "Verify failed" };
      }
      const result = await r.json();
      if (result === true) return { ok: true };
      return { ok: false, code: "unauthorized" };
    } catch (e) {
      return { ok: false, code: "error", message: e.message };
    }
  }

  async function uploadFile(pass, file, opts) {
    opts = opts || {};
    const prefix = opts.prefix ? (opts.prefix.replace(/[^a-zA-Z0-9_-]/g, "") + "/") : "";
    // Sanitize and prefix the filename
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
    const stamp = new Date().toISOString().replace(/[-:T.Z]/g, "").slice(0, 14);
    const rand  = Math.random().toString(36).slice(2, 8);
    const path  = `${prefix}${stamp}-${rand}-${safeName}`;

    const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${encodePath(path)}`, {
      method: "POST",
      headers: {
        "apikey": KEY,
        "Authorization": "Bearer " + KEY,
        "Content-Type": file.type || "application/octet-stream",
        "x-admin-pass": pass,
        "x-upsert": "false"
      },
      body: file
    });
    if (!r.ok) {
      let err;
      try { err = await r.json(); } catch (e) { err = { message: "HTTP " + r.status }; }
      return { ok: false, message: err.message || "Upload failed" };
    }
    const publicUrl = `${URL}/storage/v1/object/public/${BUCKET}/${encodePath(path)}`;
    return { ok: true, path: path, url: publicUrl };
  }

  // Encode each path segment but keep the slashes
  function encodePath(p) {
    return p.split("/").map(encodeURIComponent).join("/");
  }

  // Backwards-compatible alias
  async function uploadPhoto(pass, file) {
    return uploadFile(pass, file);
  }

  async function deleteFile(pass, path) {
    if (!path) return { ok: true };
    const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${encodePath(path)}`, {
      method: "DELETE",
      headers: {
        "apikey": KEY,
        "Authorization": "Bearer " + KEY,
        "x-admin-pass": pass
      }
    });
    if (r.ok) return { ok: true };
    return { ok: false };
  }

  // Backwards-compatible alias
  async function deletePhoto(pass, path) {
    return deleteFile(pass, path);
  }

  // Migrate legacy localStorage data (with photos as base64 data URLs) to
  // Supabase the first time an admin saves. Photos that aren't already
  // uploaded URLs will be uploaded automatically.
  async function migrateBase64PhotosIfNeeded(pass, content) {
    if (!content || !Array.isArray(content.photos)) return content;
    let changed = false;
    for (const p of content.photos) {
      if (p.dataUrl && p.dataUrl.startsWith("data:")) {
        // Convert dataURL → Blob → upload
        try {
          const blob = await (await fetch(p.dataUrl)).blob();
          const ext = (blob.type.split("/")[1] || "jpg").split(";")[0];
          const file = new File([blob], `legacy.${ext}`, { type: blob.type });
          const up = await uploadPhoto(pass, file);
          if (up.ok) {
            p.url = up.url;
            p.path = up.path;
            delete p.dataUrl;
            changed = true;
          }
        } catch (e) {
          console.warn("[SG] migration upload failed", e);
        }
      }
    }
    return content;
  }

  /* ===== Analytics ============================================ */
  // Stable per-browser session id (random, not a personal identifier).
  function sessionId() {
    try {
      var k = "SG_SID";
      var v = localStorage.getItem(k);
      if (!v) {
        v = (crypto && crypto.randomUUID ? crypto.randomUUID()
          : Math.random().toString(36).slice(2) + Date.now().toString(36));
        localStorage.setItem(k, v);
      }
      return v;
    } catch (e) { return "anon"; }
  }

  // Fire-and-forget event recorder. Never blocks the UI, never throws.
  function trackEvent(event_type, fields) {
    try {
      var payload = Object.assign({
        event_type: event_type,
        session_id: sessionId(),
        page: location.pathname + location.hash,
        referrer: document.referrer || "",
        user_agent: (navigator.userAgent || "").slice(0, 280)
      }, fields || {});
      // Prefer sendBeacon so the request survives page navigations.
      var url = URL + "/rest/v1/rpc/track_event";
      var body = JSON.stringify({ payload: payload });
      // sendBeacon can't set custom headers, so use fetch (keepalive) for the
      // apikey + Authorization. keepalive ensures the call still completes
      // even if the user navigates away immediately after a click.
      fetch(url, {
        method: "POST",
        headers: headers(),
        body: body,
        keepalive: true
      }).catch(function () { /* swallow */ });
    } catch (e) { /* swallow */ }
  }

  async function fetchAnalytics(pass, startISO, endISO) {
    try {
      var r = await fetch(URL + "/rest/v1/rpc/get_analytics", {
        method: "POST",
        headers: headers(),
        body: JSON.stringify({
          pass: pass,
          start_ts: startISO,
          end_ts: endISO
        })
      });
      if (!r.ok) {
        var err; try { err = await r.json(); } catch (e) { err = { message: "HTTP " + r.status }; }
        if (err && err.code === "P0001" && /unauthorized/i.test(err.message || "")) {
          return { ok: false, code: "unauthorized" };
        }
        return { ok: false, code: "error", message: err.message || "Read failed" };
      }
      var data = await r.json();
      return { ok: true, data: data };
    } catch (e) {
      return { ok: false, code: "error", message: e.message };
    }
  }

  async function changeAdminPassword(oldPass, newPass) {
    try {
      var r = await fetch(URL + "/rest/v1/rpc/change_admin_password", {
        method: "POST",
        headers: headers(),
        body: JSON.stringify({
          old_pass: oldPass,
          new_pass: newPass
        })
      });
      if (!r.ok) {
        var err; try { err = await r.json(); } catch (e) { err = { message: "HTTP " + r.status }; }
        if (err) {
          if (/unauthorized/i.test(err.message || "")) return { ok: false, code: "wrong_password" };
          if (/too short/i.test(err.message || "")) return { ok: false, code: "too_short" };
          if (/too long/i.test(err.message || ""))  return { ok: false, code: "too_long" };
        }
        return { ok: false, code: "error", message: (err && err.message) || "Password change failed" };
      }
      return { ok: true };
    } catch (e) {
      return { ok: false, code: "error", message: e.message };
    }
  }

  global.SGData = {
    fetchContent,
    saveContent,
    verifyPassword,
    uploadFile,
    deleteFile,
    uploadPhoto,         // alias of uploadFile
    deletePhoto,         // alias of deleteFile
    migrateBase64PhotosIfNeeded,
    trackEvent,
    fetchAnalytics,
    changeAdminPassword,
    sessionId
  };
})(window);
