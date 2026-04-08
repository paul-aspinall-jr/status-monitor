CREATE TABLE IF NOT EXISTS daily_uptime (
    hostname TEXT NOT NULL,
    date TEXT NOT NULL,
    total_seconds INTEGER NOT NULL DEFAULT 0,
    downtime_seconds INTEGER NOT NULL DEFAULT 0,
    ping_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hostname, date)
);

CREATE INDEX IF NOT EXISTS idx_daily_uptime_hostname ON daily_uptime (hostname, date);
