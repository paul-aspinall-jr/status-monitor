CREATE TABLE IF NOT EXISTS status (
    hostname TEXT PRIMARY KEY,
    os TEXT NOT NULL DEFAULT 'unknown',
    cpu_usage REAL,
    memory_total INTEGER,
    memory_used INTEGER,
    disk_total INTEGER,
    disk_used INTEGER,
    uptime_seconds INTEGER,
    last_seen TEXT NOT NULL,
    alert_sent INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS daily_uptime (
    hostname TEXT NOT NULL,
    date TEXT NOT NULL,
    total_seconds INTEGER NOT NULL DEFAULT 0,
    downtime_seconds INTEGER NOT NULL DEFAULT 0,
    ping_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hostname, date)
);

CREATE INDEX IF NOT EXISTS idx_daily_uptime_hostname ON daily_uptime (hostname, date);
