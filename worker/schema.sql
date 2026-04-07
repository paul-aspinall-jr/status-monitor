CREATE TABLE IF NOT EXISTS status (
    hostname TEXT PRIMARY KEY,
    os TEXT NOT NULL DEFAULT 'unknown',
    cpu_usage REAL,
    memory_total INTEGER,
    memory_used INTEGER,
    disk_total INTEGER,
    disk_used INTEGER,
    uptime_seconds INTEGER,
    last_seen TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS status_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hostname TEXT NOT NULL,
    cpu_usage REAL,
    memory_total INTEGER,
    memory_used INTEGER,
    disk_total INTEGER,
    disk_used INTEGER,
    uptime_seconds INTEGER,
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_history_hostname_time ON status_history (hostname, recorded_at);
