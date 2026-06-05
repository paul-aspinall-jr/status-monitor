const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Mozilla CA root bundle snapshot, embedded at build time.
///
/// The agent trusts the union of this bundle and the OS certificate store.
/// This exists because on Windows, Zig's TLS stack can only see roots already
/// cached in the ROOT store and never triggers Windows' automatic root update.
/// When Cloudflare rotated workers.dev onto a chain anchored at a root no box
/// had cached, every Windows agent failed with TlsInitializationFailed
/// (2026-06-05 outage). Refresh with: ./build.sh ca-bundle
const embedded_ca_pem = @embedFile("ca_bundle.pem");

const Config = struct {
    endpoint: []const u8,
    api_key: []const u8,
    interval_seconds: u64,
    hostname_override: ?[]const u8,
};

const SystemMetrics = struct {
    hostname: []const u8,
    os: []const u8,
    cpu_usage: ?f64,
    memory_total: ?u64,
    memory_used: ?u64,
    disk_total: ?u64,
    disk_used: ?u64,
    uptime_seconds: ?u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const config = loadConfig(init.arena.allocator(), io, init.environ_map) catch |err| {
        std.log.err("Failed to load config: {t}", .{err});
        std.log.err("Set STATUS_ENDPOINT and STATUS_API_KEY environment variables, or create config.ini", .{});
        return err;
    };

    std.log.info("status-agent starting", .{});
    std.log.info("  endpoint: {s}", .{config.endpoint});
    std.log.info("  interval: {}s", .{config.interval_seconds});

    while (true) {
        var tick_arena = std.heap.ArenaAllocator.init(allocator);
        defer tick_arena.deinit();

        if (collectMetrics(tick_arena.allocator(), io, config, init.environ_map)) |metrics| {
            sendMetrics(allocator, io, config, metrics) catch |err| {
                std.log.err("Failed to send metrics: {t}", .{err});
            };
        } else |err| {
            std.log.err("Failed to collect metrics: {t}", .{err});
        }

        io.sleep(.fromSeconds(@intCast(config.interval_seconds)), .awake) catch {};
    }
}

// --- Config loading ---

fn loadConfig(arena: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) !Config {
    const endpoint = environ.get("STATUS_ENDPOINT");
    const api_key = environ.get("STATUS_API_KEY");

    if (endpoint != null and api_key != null) {
        const interval: u64 = if (environ.get("STATUS_INTERVAL")) |s|
            std.fmt.parseInt(u64, s, 10) catch 60
        else
            60;
        return Config{
            .endpoint = try arena.dupe(u8, endpoint.?),
            .api_key = try arena.dupe(u8, api_key.?),
            .interval_seconds = interval,
            .hostname_override = if (environ.get("STATUS_HOSTNAME")) |h| try arena.dupe(u8, h) else null,
        };
    }

    return loadConfigFile(arena, io);
}

fn loadConfigFile(arena: std.mem.Allocator, io: Io) !Config {
    var buf: [8192]u8 = undefined;
    const content = Io.Dir.cwd().readFile(io, "config.ini", &buf) catch {
        return error.ConfigNotFound;
    };

    var endpoint: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var interval: u64 = 60;
    var hostname_override: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, &[_]u8{ '\r', ' ', '\t' });
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], &[_]u8{ ' ', '\t' });
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], &[_]u8{ ' ', '\t' });

            if (std.mem.eql(u8, key, "endpoint")) {
                endpoint = try arena.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "api_key")) {
                api_key = try arena.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "interval")) {
                interval = std.fmt.parseInt(u64, val, 10) catch 60;
            } else if (std.mem.eql(u8, key, "hostname")) {
                hostname_override = try arena.dupe(u8, val);
            }
        }
    }

    if (endpoint == null or api_key == null) {
        return error.ConfigIncomplete;
    }

    return Config{
        .endpoint = endpoint.?,
        .api_key = api_key.?,
        .interval_seconds = interval,
        .hostname_override = hostname_override,
    };
}

// --- Metrics collection ---

fn collectMetrics(arena: std.mem.Allocator, io: Io, config: Config, environ: *std.process.Environ.Map) !SystemMetrics {
    const hostname = config.hostname_override orelse try getHostname(arena, environ);
    const os_name = getOsName();

    var metrics = SystemMetrics{
        .hostname = hostname,
        .os = os_name,
        .cpu_usage = null,
        .memory_total = null,
        .memory_used = null,
        .disk_total = null,
        .disk_used = null,
        .uptime_seconds = null,
    };

    if (comptime builtin.os.tag == .linux) {
        metrics.memory_total, metrics.memory_used = readLinuxMemory(io) catch .{ null, null };
        metrics.cpu_usage = readLinuxCpuUsage(io) catch null;
        metrics.uptime_seconds = readLinuxUptime(io) catch null;
        metrics.disk_total, metrics.disk_used = readLinuxDisk() catch .{ null, null };
    } else if (comptime builtin.os.tag == .windows) {
        metrics.memory_total, metrics.memory_used = readWindowsMemory();
        metrics.uptime_seconds = readWindowsUptime();
    }

    return metrics;
}

fn getHostname(arena: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        const name = environ.get("COMPUTERNAME") orelse "unknown-windows";
        return try arena.dupe(u8, name);
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&buf);
        return try arena.dupe(u8, hostname);
    }
}

fn getOsName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "macos",
        else => "unknown",
    };
}

// --- Linux metrics ---

fn readFileContents(io: Io, path: []const u8, buf: []u8) ![]const u8 {
    return Io.Dir.cwd().readFile(io, path, buf) catch return error.ReadFailed;
}

fn readLinuxMemory(io: Io) !struct { ?u64, ?u64 } {
    var buf: [4096]u8 = undefined;
    const content = try readFileContents(io, "/proc/meminfo", &buf);

    var total: ?u64 = null;
    var available: ?u64 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available = parseMemInfoValue(line);
        }
        if (total != null and available != null) break;
    }

    if (total != null and available != null) {
        return .{ total.?, total.? - available.? };
    }
    return .{ null, null };
}

fn parseMemInfoValue(line: []const u8) ?u64 {
    const colon_idx = std.mem.indexOf(u8, line, ":") orelse return null;
    const rest = std.mem.trim(u8, line[colon_idx + 1 ..], &[_]u8{ ' ', '\t' });
    const num_end = std.mem.indexOf(u8, rest, " ") orelse rest.len;
    const val = std.fmt.parseInt(u64, rest[0..num_end], 10) catch return null;
    return val * 1024; // convert kB to bytes
}

fn readLinuxCpuUsage(io: Io) !?f64 {
    const sample1 = try readCpuSample(io);
    io.sleep(.fromSeconds(1), .awake) catch {};
    const sample2 = try readCpuSample(io);

    const total_diff = sample2.total - sample1.total;
    const idle_diff = sample2.idle - sample1.idle;

    if (total_diff == 0) return null;
    return (1.0 - @as(f64, @floatFromInt(idle_diff)) / @as(f64, @floatFromInt(total_diff))) * 100.0;
}

const CpuSample = struct { total: u64, idle: u64 };

fn readCpuSample(io: Io) !CpuSample {
    var buf: [512]u8 = undefined;
    const content = try readFileContents(io, "/proc/stat", &buf);

    // Get just the first line
    const nl = std.mem.indexOf(u8, content, "\n") orelse content.len;
    const line = content[0..nl];

    if (!std.mem.startsWith(u8, line, "cpu ")) return error.InvalidFormat;

    // cpu  user nice system idle iowait irq softirq steal
    var it = std.mem.tokenizeAny(u8, line, " ");
    _ = it.next(); // skip "cpu"
    var values: [8]u64 = undefined;
    var i: usize = 0;
    while (it.next()) |tok| {
        if (i >= 8) break;
        values[i] = std.fmt.parseInt(u64, tok, 10) catch 0;
        i += 1;
    }

    var total: u64 = 0;
    for (0..i) |j| total += values[j];
    const idle = if (i > 3) values[3] else 0;

    return CpuSample{ .total = total, .idle = idle };
}

fn readLinuxUptime(io: Io) !?u64 {
    var buf: [64]u8 = undefined;
    const content = try readFileContents(io, "/proc/uptime", &buf);

    const space_idx = std.mem.indexOf(u8, content, " ") orelse content.len;
    const dot_idx = std.mem.indexOf(u8, content[0..space_idx], ".") orelse space_idx;
    return std.fmt.parseInt(u64, content[0..dot_idx], 10) catch null;
}

fn readLinuxDisk() !struct { ?u64, ?u64 } {
    const Statfs = extern struct {
        f_type: isize,
        f_bsize: isize,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [2]i32,
        f_namelen: isize,
        f_frsize: isize,
        f_flags: isize,
        f_spare: [4]isize,
    };
    var stat: Statfs = undefined;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr("/"), @intFromPtr(&stat));
    const signed: isize = @bitCast(rc);
    if (signed < 0) return .{ null, null };

    const block_size: u64 = @intCast(stat.f_bsize);
    const total = stat.f_blocks * block_size;
    const free = stat.f_bfree * block_size;
    return .{ total, total - free };
}

// --- Windows metrics ---

const MEMORYSTATUSEX = extern struct {
    dwLength: u32 = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: u32 = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn readWindowsMemory() struct { ?u64, ?u64 } {
    if (comptime builtin.os.tag != .windows) return .{ null, null };
    var mem_status = MEMORYSTATUSEX{};
    if (GlobalMemoryStatusEx(&mem_status) != 0) {
        return .{ mem_status.ullTotalPhys, mem_status.ullTotalPhys - mem_status.ullAvailPhys };
    }
    return .{ null, null };
}

fn readWindowsUptime() ?u64 {
    if (comptime builtin.os.tag != .windows) return null;
    return GetTickCount64() / 1000;
}

// --- TLS trust setup ---

/// Populate the client's CA bundle with the union of the OS certificate
/// store and the embedded Mozilla bundle. Either source may fail or be
/// incomplete (e.g. a sparse Windows ROOT store cache); the other still
/// provides trust anchors.
fn setupTrust(client: *std.http.Client, allocator: std.mem.Allocator, io: Io) !void {
    const now = Io.Clock.real.now(io);
    // Non-null `now` tells std.http.Client not to do its own rescan,
    // which would replace the bundle assembled here.
    client.now = now;

    client.ca_bundle.rescan(allocator, io, now) catch |err| {
        std.log.warn("OS certificate store scan failed ({t}); using embedded roots only", .{err});
    };
    try addCertsFromPem(&client.ca_bundle, allocator, embedded_ca_pem, now.toSeconds());
}

/// Add certificates from an in-memory PEM bundle, mirroring
/// std.crypto.Certificate.Bundle.addCertsFromFile. Certificates that are
/// expired or fail to parse are skipped rather than aborting the load.
fn addCertsFromPem(
    bundle: *std.crypto.Certificate.Bundle,
    gpa: std.mem.Allocator,
    pem: []const u8,
    now_sec: i64,
) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;

        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, base64.calcSizeUpperBound(encoded.len));
        const dest = bundle.bytes.allocatedSlice()[decoded_start..];
        const decoded_len = base64.decode(dest, encoded) catch continue;
        bundle.bytes.items.len += decoded_len;
        bundle.parseCert(gpa, decoded_start, now_sec) catch {
            bundle.bytes.items.len = decoded_start;
        };
    }
}

// --- HTTP sender ---

fn sendMetrics(allocator: std.mem.Allocator, io: Io, config: Config, metrics: SystemMetrics) !void {
    var json_buf: Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();

    const writer = &json_buf.writer;
    try writer.writeAll("{");
    try writer.print("\"hostname\":\"{s}\",\"os\":\"{s}\"", .{ metrics.hostname, metrics.os });

    if (metrics.cpu_usage) |v| {
        try writer.print(",\"cpu_usage\":{d:.1}", .{v});
    }
    if (metrics.memory_total) |v| {
        try writer.print(",\"memory_total\":{}", .{v});
    }
    if (metrics.memory_used) |v| {
        try writer.print(",\"memory_used\":{}", .{v});
    }
    if (metrics.disk_total) |v| {
        try writer.print(",\"disk_total\":{}", .{v});
    }
    if (metrics.disk_used) |v| {
        try writer.print(",\"disk_used\":{}", .{v});
    }
    if (metrics.uptime_seconds) |v| {
        try writer.print(",\"uptime_seconds\":{}", .{v});
    }

    try writer.writeAll("}");

    const payload = json_buf.written();
    std.log.info("Sending: {s}", .{payload});

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    try setupTrust(&client, allocator, io);

    const uri = std.Uri.parse(config.endpoint) catch {
        std.log.err("Invalid endpoint URL: {s}", .{config.endpoint});
        return error.InvalidUrl;
    };

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-API-Key", .value = config.api_key },
        },
    });
    defer req.deinit();

    try req.sendBodyComplete(payload);
    var redirect_buf: [4096]u8 = undefined;
    const response = try req.receiveHead(&redirect_buf);

    if (response.head.status == .ok) {
        std.log.info("Status sent successfully for {s}", .{metrics.hostname});
    } else {
        std.log.err("Server returned HTTP {}", .{@intFromEnum(response.head.status)});
    }
}

test "embedded CA bundle parses and contains current roots" {
    const gpa = std.testing.allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);

    // Use a fixed timestamp (2026-06-01) so the test does not depend on wall
    // clock; parseCert drops certificates expired relative to `now`.
    const now_sec: i64 = 1780272000;
    try addCertsFromPem(&bundle, gpa, embedded_ca_pem, now_sec);

    // The Mozilla bundle carries well over 100 roots.
    try std.testing.expect(bundle.map.count() > 100);
}
