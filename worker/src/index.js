const DOWNTIME_THRESHOLD_S = 120; // gap > 2 minutes = downtime

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/status" && request.method === "POST") {
      return handleStatusPost(request, env);
    }
    if (url.pathname === "/api/status" && request.method === "GET") {
      return handleStatusGet(url, env);
    }
    if (url.pathname === "/api/status" && request.method === "DELETE") {
      return handleStatusDelete(request, env);
    }
    if (url.pathname === "/api/history" && request.method === "GET") {
      return handleHistoryGet(url, env);
    }
    if (url.pathname === "/api/uptime" && request.method === "GET") {
      return handleUptimeGet(url, env);
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

  const now = new Date();
  const nowISO = now.toISOString();
  const today = nowISO.slice(0, 10);

  // Get previous last_seen for downtime calculation
  const prev = await env.status_monitor_db.prepare(
    "SELECT last_seen FROM status WHERE hostname = ?"
  ).bind(body.hostname).first();

  // Upsert current status
  await env.status_monitor_db.prepare(`
    INSERT INTO status (hostname, os, cpu_usage, memory_total, memory_used, disk_total, disk_used, uptime_seconds, last_seen)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(hostname) DO UPDATE SET
      os = excluded.os,
      cpu_usage = excluded.cpu_usage,
      memory_total = excluded.memory_total,
      memory_used = excluded.memory_used,
      disk_total = excluded.disk_total,
      disk_used = excluded.disk_used,
      uptime_seconds = excluded.uptime_seconds,
      last_seen = excluded.last_seen
  `).bind(
    body.hostname,
    body.os || "unknown",
    body.cpu_usage ?? null,
    body.memory_total ?? null,
    body.memory_used ?? null,
    body.disk_total ?? null,
    body.disk_used ?? null,
    body.uptime_seconds ?? null,
    nowISO,
  ).run();

  // Record history
  await env.status_monitor_db.prepare(`
    INSERT INTO status_history (hostname, cpu_usage, memory_total, memory_used, disk_total, disk_used, uptime_seconds, recorded_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(
    body.hostname,
    body.cpu_usage ?? null,
    body.memory_total ?? null,
    body.memory_used ?? null,
    body.disk_total ?? null,
    body.disk_used ?? null,
    body.uptime_seconds ?? null,
    nowISO,
  ).run();

  // Update daily uptime tracking
  let downtimeToAdd = 0;
  let elapsedSinceLastPing = 0;

  if (prev?.last_seen) {
    const lastSeen = new Date(prev.last_seen);
    elapsedSinceLastPing = Math.floor((now - lastSeen) / 1000);

    if (elapsedSinceLastPing > DOWNTIME_THRESHOLD_S) {
      // The entire gap is downtime — attribute to the days it spans
      const gapStart = lastSeen;
      const gapEnd = now;
      await attributeDowntime(env, body.hostname, gapStart, gapEnd);
    }
  }

  // Ensure today's row exists and increment ping count
  await env.status_monitor_db.prepare(`
    INSERT INTO daily_uptime (hostname, date, total_seconds, downtime_seconds, ping_count)
    VALUES (?, ?, 86400, 0, 1)
    ON CONFLICT(hostname, date) DO UPDATE SET
      ping_count = daily_uptime.ping_count + 1
  `).bind(body.hostname, today).run();

  return jsonResponse({ ok: true, hostname: body.hostname });
}

async function attributeDowntime(env, hostname, gapStart, gapEnd) {
  // Split downtime across day boundaries
  let cursor = new Date(gapStart);
  while (cursor < gapEnd) {
    const dayStr = cursor.toISOString().slice(0, 10);
    const dayEnd = new Date(dayStr + "T23:59:59.999Z");
    const segmentEnd = gapEnd < dayEnd ? gapEnd : dayEnd;
    const segmentSeconds = Math.floor((segmentEnd - cursor) / 1000);

    if (segmentSeconds > 0) {
      await env.status_monitor_db.prepare(`
        INSERT INTO daily_uptime (hostname, date, total_seconds, downtime_seconds, ping_count)
        VALUES (?, ?, 86400, ?, 0)
        ON CONFLICT(hostname, date) DO UPDATE SET
          downtime_seconds = daily_uptime.downtime_seconds + ?
      `).bind(hostname, dayStr, segmentSeconds, segmentSeconds).run();
    }

    // Move to start of next day
    cursor = new Date(dayStr + "T00:00:00.000Z");
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
}

async function handleStatusGet(url, env) {
  const hostname = url.searchParams.get("hostname");
  if (hostname) {
    const row = await env.status_monitor_db.prepare("SELECT * FROM status WHERE hostname = ?").bind(hostname).first();
    if (!row) return jsonResponse({ error: "Not found" }, 404);
    return jsonResponse(row);
  }
  const { results } = await env.status_monitor_db.prepare("SELECT * FROM status ORDER BY hostname").all();
  return jsonResponse(results);
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

  await env.status_monitor_db.batch([
    env.status_monitor_db.prepare("DELETE FROM status WHERE hostname = ?").bind(hostname),
    env.status_monitor_db.prepare("DELETE FROM status_history WHERE hostname = ?").bind(hostname),
    env.status_monitor_db.prepare("DELETE FROM daily_uptime WHERE hostname = ?").bind(hostname),
  ]);

  return jsonResponse({ ok: true, deleted: hostname });
}

async function handleHistoryGet(url, env) {
  const hostname = url.searchParams.get("hostname");
  if (!hostname) {
    return jsonResponse({ error: "hostname query param required" }, 400);
  }
  const limit = Math.min(parseInt(url.searchParams.get("limit") || "60", 10), 1440);

  const { results } = await env.status_monitor_db.prepare(
    "SELECT * FROM status_history WHERE hostname = ? ORDER BY recorded_at DESC LIMIT ?"
  ).bind(hostname, limit).all();

  return jsonResponse(results);
}

async function handleUptimeGet(url, env) {
  const hostname = url.searchParams.get("hostname");
  const days = Math.min(parseInt(url.searchParams.get("days") || "90", 10), 365);

  if (hostname) {
    const { results } = await env.status_monitor_db.prepare(
      "SELECT * FROM daily_uptime WHERE hostname = ? ORDER BY date DESC LIMIT ?"
    ).bind(hostname, days).all();
    return jsonResponse(results);
  }

  // All hostnames
  const { results } = await env.status_monitor_db.prepare(`
    SELECT * FROM daily_uptime WHERE date >= date('now', '-' || ? || ' days') ORDER BY hostname, date
  `).bind(days).all();
  return jsonResponse(results);
}

// --- Helpers ---

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
  const { results: servers } = await env.status_monitor_db.prepare(
    "SELECT * FROM status ORDER BY hostname"
  ).all();

  // Get 90 days of uptime data for all servers
  const { results: uptimeData } = await env.status_monitor_db.prepare(`
    SELECT * FROM daily_uptime WHERE date >= date('now', '-90 days') ORDER BY hostname, date
  `).all();

  // Group uptime by hostname
  const uptimeByHost = {};
  for (const row of uptimeData) {
    if (!uptimeByHost[row.hostname]) uptimeByHost[row.hostname] = [];
    uptimeByHost[row.hostname].push(row);
  }

  const html = renderDashboard(servers, uptimeByHost);
  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function renderDashboard(servers, uptimeByHost) {
  // Build 90-day date array
  const days = [];
  for (let i = 89; i >= 0; i--) {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() - i);
    days.push(d.toISOString().slice(0, 10));
  }

  const serverSections = servers.map((s) => {
    const lastSeen = new Date(s.last_seen);
    const ageMs = Date.now() - lastSeen.getTime();
    const isOnline = ageMs < 120_000;

    const hostUptime = uptimeByHost[s.hostname] || [];
    const uptimeMap = {};
    for (const row of hostUptime) {
      uptimeMap[row.date] = { ...row };
    }

    // Account for live gap: if server is currently down, add ongoing
    // downtime from last_seen to now across the affected days
    if (!isOnline) {
      let cursor = new Date(lastSeen);
      const now = new Date();
      while (cursor < now) {
        const dayStr = cursor.toISOString().slice(0, 10);
        const dayEnd = new Date(dayStr + "T23:59:59.999Z");
        const segmentEnd = now < dayEnd ? now : dayEnd;
        const segmentSeconds = Math.floor((segmentEnd - cursor) / 1000);
        if (segmentSeconds > 0) {
          if (!uptimeMap[dayStr]) {
            uptimeMap[dayStr] = { hostname: s.hostname, date: dayStr, total_seconds: 86400, downtime_seconds: 0, ping_count: 0 };
          }
          uptimeMap[dayStr].downtime_seconds += segmentSeconds;
        }
        cursor = new Date(dayStr + "T00:00:00.000Z");
        cursor.setUTCDate(cursor.getUTCDate() + 1);
      }
    }

    // Calculate overall uptime percentage across all days with data
    let totalSeconds = 0;
    let totalDowntime = 0;
    for (const day of days) {
      const row = uptimeMap[day];
      if (!row) continue;
      totalSeconds += row.total_seconds;
      totalDowntime += Math.min(row.downtime_seconds, row.total_seconds);
    }
    const overallUptime = totalSeconds > 0
      ? ((totalSeconds - totalDowntime) / totalSeconds * 100)
      : 100;

    // Build bars
    const bars = days.map((day) => {
      const row = uptimeMap[day];
      if (!row) {
        return `<div class="bar no-data" title="${day}: No data"><div class="bar-fill" style="height:100%"></div></div>`;
      }
      const effectiveDowntime = Math.min(row.downtime_seconds, row.total_seconds);
      const upPct = row.total_seconds > 0
        ? ((row.total_seconds - effectiveDowntime) / row.total_seconds * 100)
        : 100;
      const barClass = upPct >= 99.9 ? "good" : upPct >= 95 ? "degraded" : "down";
      const title = `${day}: ${upPct.toFixed(2)}% uptime (${row.ping_count} pings, ${formatDuration(row.downtime_seconds)} downtime)`;
      return `<div class="bar ${barClass}" title="${escapeHtml(title)}"><div class="bar-fill" style="height:${upPct}%"></div></div>`;
    }).join("");

    const statusDot = isOnline ? "green" : "red";
    const statusText = isOnline ? "Operational" : `Last seen ${timeAgo(ageMs)}`;

    return `
    <div class="server-section">
      <div class="server-header">
        <div class="server-name">
          <span class="status-dot ${statusDot}"></span>
          ${escapeHtml(s.hostname)}
          <span class="status-label">${statusText}</span>
        </div>
        <div class="uptime-pct">${overallUptime.toFixed(3)}% uptime</div>
      </div>
      <div class="uptime-chart">${bars}</div>
      <div class="chart-labels">
        <span>${days[0]}</span>
        <span>Today</span>
      </div>
    </div>`;
  }).join("\n");

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
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0d1117; color: #c9d1d9; margin: 0; padding: 0;
    }
    .container { max-width: 1000px; margin: 0 auto; padding: 2rem 1.5rem; }
    h1 { color: #f0f6fc; font-size: 1.6rem; margin: 0 0 0.25rem 0; font-weight: 600; }
    .subtitle { color: #8b949e; font-size: 0.9rem; margin-bottom: 2rem; }

    .overall-status {
      background: #161b22; border: 1px solid #30363d; border-radius: 8px;
      padding: 1.25rem 1.5rem; margin-bottom: 2rem; display: flex;
      align-items: center; gap: 0.75rem;
    }
    .overall-dot {
      width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0;
    }
    .overall-dot.green { background: #3fb950; box-shadow: 0 0 8px rgba(63,185,80,0.4); }
    .overall-dot.yellow { background: #d29922; box-shadow: 0 0 8px rgba(210,153,34,0.4); }
    .overall-dot.red { background: #f85149; box-shadow: 0 0 8px rgba(248,81,73,0.4); }
    .overall-text { font-size: 1.1rem; font-weight: 500; }

    .server-section {
      background: #161b22; border: 1px solid #30363d; border-radius: 8px;
      padding: 1.25rem 1.5rem; margin-bottom: 1rem;
    }
    .server-header {
      display: flex; justify-content: space-between; align-items: center;
      margin-bottom: 0.75rem;
    }
    .server-name { display: flex; align-items: center; gap: 0.5rem; font-weight: 500; }
    .status-dot {
      width: 10px; height: 10px; border-radius: 50%; display: inline-block;
    }
    .status-dot.green { background: #3fb950; }
    .status-dot.red { background: #f85149; }
    .status-label { color: #8b949e; font-weight: 400; font-size: 0.85rem; margin-left: 0.5rem; }
    .uptime-pct { color: #8b949e; font-size: 0.9rem; }

    .uptime-chart {
      display: flex; gap: 2px; height: 34px; align-items: flex-end;
    }
    .bar {
      flex: 1; height: 100%; border-radius: 2px; position: relative;
      cursor: pointer; display: flex; align-items: flex-end;
    }
    .bar-fill {
      width: 100%; border-radius: 2px; transition: height 0.2s;
    }
    .bar.good .bar-fill { background: #3fb950; }
    .bar.degraded .bar-fill { background: #d29922; }
    .bar.down .bar-fill { background: #f85149; }
    .bar.no-data .bar-fill { background: #21262d; }
    .bar:hover { opacity: 0.8; }

    .chart-labels {
      display: flex; justify-content: space-between;
      font-size: 0.75rem; color: #484f58; margin-top: 0.35rem;
    }

    .empty {
      color: #8b949e; text-align: center; padding: 3rem;
      background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    }

    .legend {
      display: flex; gap: 1.5rem; margin-bottom: 1.5rem;
      font-size: 0.8rem; color: #8b949e;
    }
    .legend-item { display: flex; align-items: center; gap: 0.4rem; }
    .legend-swatch {
      width: 12px; height: 12px; border-radius: 2px;
    }
    .legend-swatch.good { background: #3fb950; }
    .legend-swatch.degraded { background: #d29922; }
    .legend-swatch.down { background: #f85149; }
    .legend-swatch.no-data { background: #21262d; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Status</h1>
    <p class="subtitle">${servers.length} server(s) monitored &mdash; auto-refreshes every 30s</p>
    ${servers.length === 0
      ? '<div class="empty">No servers reporting yet. Deploy the status-agent to start monitoring.</div>'
      : renderOverallStatus(servers) + `
    <div class="legend">
      <div class="legend-item"><div class="legend-swatch good"></div> Operational</div>
      <div class="legend-item"><div class="legend-swatch degraded"></div> Degraded</div>
      <div class="legend-item"><div class="legend-swatch down"></div> Major outage</div>
      <div class="legend-item"><div class="legend-swatch no-data"></div> No data</div>
    </div>` + serverSections}
  </div>
</body>
</html>`;
}

function renderOverallStatus(servers) {
  const allOnline = servers.every((s) => {
    const ageMs = Date.now() - new Date(s.last_seen).getTime();
    return ageMs < 120_000;
  });
  const anyOnline = servers.some((s) => {
    const ageMs = Date.now() - new Date(s.last_seen).getTime();
    return ageMs < 120_000;
  });

  let dotClass, text;
  if (allOnline) {
    dotClass = "green";
    text = "All Systems Operational";
  } else if (anyOnline) {
    dotClass = "yellow";
    text = "Partial System Outage";
  } else {
    dotClass = "red";
    text = "Major System Outage";
  }

  return `
    <div class="overall-status">
      <div class="overall-dot ${dotClass}"></div>
      <div class="overall-text">${text}</div>
    </div>`;
}

function formatDuration(seconds) {
  if (seconds === 0) return "none";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
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
