export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/status" && request.method === "POST") {
      return handleStatusPost(request, env);
    }
    if (url.pathname === "/api/status" && request.method === "GET") {
      return handleStatusGet(env);
    }
    if (url.pathname === "/api/status" && request.method === "DELETE") {
      return handleStatusDelete(request, env);
    }
    if (url.pathname === "/") {
      return handleDashboard(env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

// --- API Handlers ---

async function handleStatusPost(request, env) {
  const apiKey = request.headers.get("X-API-Key");
  if (apiKey !== env.API_KEY) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  if (!body.hostname) {
    return jsonResponse({ error: "hostname is required" }, 400);
  }

  const record = {
    hostname: body.hostname,
    os: body.os || "unknown",
    cpu_usage: body.cpu_usage ?? null,
    memory_total: body.memory_total ?? null,
    memory_used: body.memory_used ?? null,
    disk_total: body.disk_total ?? null,
    disk_used: body.disk_used ?? null,
    uptime_seconds: body.uptime_seconds ?? null,
    custom: body.custom || {},
    last_seen: new Date().toISOString(),
  };

  // Store with 5-minute TTL so stale entries auto-expire
  await env.STATUS_KV.put(`server:${body.hostname}`, JSON.stringify(record), {
    expirationTtl: 300,
  });

  // Also maintain a set of known hostnames (longer TTL)
  const hostsRaw = await env.STATUS_KV.get("hosts:index");
  const hosts = hostsRaw ? JSON.parse(hostsRaw) : [];
  if (!hosts.includes(body.hostname)) {
    hosts.push(body.hostname);
    await env.STATUS_KV.put("hosts:index", JSON.stringify(hosts));
  }

  return jsonResponse({ ok: true, hostname: body.hostname });
}

async function handleStatusGet(env) {
  const servers = await getAllServers(env);
  return jsonResponse(servers);
}

async function handleStatusDelete(request, env) {
  const apiKey = request.headers.get("X-API-Key");
  if (apiKey !== env.API_KEY) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const url = new URL(request.url);
  const hostname = url.searchParams.get("hostname");
  if (!hostname) {
    return jsonResponse({ error: "hostname query param required" }, 400);
  }

  await env.STATUS_KV.delete(`server:${hostname}`);

  const hostsRaw = await env.STATUS_KV.get("hosts:index");
  if (hostsRaw) {
    const hosts = JSON.parse(hostsRaw).filter((h) => h !== hostname);
    await env.STATUS_KV.put("hosts:index", JSON.stringify(hosts));
  }

  return jsonResponse({ ok: true, deleted: hostname });
}

// --- Helpers ---

async function getAllServers(env) {
  const hostsRaw = await env.STATUS_KV.get("hosts:index");
  const hosts = hostsRaw ? JSON.parse(hostsRaw) : [];
  const servers = [];

  for (const hostname of hosts) {
    const raw = await env.STATUS_KV.get(`server:${hostname}`);
    if (raw) {
      servers.push(JSON.parse(raw));
    }
  }

  return servers;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

// --- Dashboard ---

async function handleDashboard(env) {
  const servers = await getAllServers(env);
  const html = renderDashboard(servers);
  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function renderDashboard(servers) {
  const serverRows = servers
    .map((s) => {
      const lastSeen = new Date(s.last_seen);
      const ageMs = Date.now() - lastSeen.getTime();
      const isOnline = ageMs < 120_000; // seen within 2 minutes
      const status = isOnline ? "online" : "stale";
      const dot = isOnline ? "🟢" : "🟡";

      const memPct =
        s.memory_total && s.memory_used
          ? ((s.memory_used / s.memory_total) * 100).toFixed(1)
          : "—";
      const diskPct =
        s.disk_total && s.disk_used
          ? ((s.disk_used / s.disk_total) * 100).toFixed(1)
          : "—";
      const cpuPct = s.cpu_usage !== null ? s.cpu_usage.toFixed(1) : "—";
      const uptimeStr = s.uptime_seconds !== null ? formatUptime(s.uptime_seconds) : "—";

      return `
        <tr class="${status}">
          <td>${dot} ${escapeHtml(s.hostname)}</td>
          <td>${escapeHtml(s.os)}</td>
          <td>${cpuPct}%</td>
          <td>${memPct}%</td>
          <td>${diskPct}%</td>
          <td>${uptimeStr}</td>
          <td title="${escapeHtml(s.last_seen)}">${timeAgo(ageMs)}</td>
        </tr>`;
    })
    .join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Status Monitor</title>
  <meta http-equiv="refresh" content="30">
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
      background: #0d1117; color: #c9d1d9; margin: 0; padding: 2rem;
    }
    h1 { color: #58a6ff; font-size: 1.5rem; margin-bottom: 1rem; }
    .meta { color: #8b949e; font-size: 0.85rem; margin-bottom: 1.5rem; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 0.6rem 1rem; border-bottom: 1px solid #21262d; }
    th { color: #8b949e; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.05em; }
    tr.online td { color: #c9d1d9; }
    tr.stale td { color: #8b949e; }
    .empty { color: #8b949e; text-align: center; padding: 3rem; }
  </style>
</head>
<body>
  <h1>Server Status Monitor</h1>
  <p class="meta">${servers.length} server(s) reporting &mdash; auto-refreshes every 30s</p>
  ${
    servers.length === 0
      ? '<p class="empty">No servers reporting yet. Deploy the status-agent to start monitoring.</p>'
      : `<table>
    <thead>
      <tr><th>Host</th><th>OS</th><th>CPU</th><th>Memory</th><th>Disk</th><th>Uptime</th><th>Last Seen</th></tr>
    </thead>
    <tbody>${serverRows}</tbody>
  </table>`
  }
</body>
</html>`;
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function timeAgo(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return `${h}h ago`;
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
