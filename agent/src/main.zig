const std = @import("std");
const builtin = @import("builtin");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = loadConfig(allocator) catch |err| {
        std.log.err("Failed to load config: {}", .{err});
        std.log.err("Set STATUS_ENDPOINT and STATUS_API_KEY environment variables, or create config.ini", .{});
        return err;
    };

    std.log.info("status-agent starting", .{});
    std.log.info("  endpoint: {s}", .{config.endpoint});
    std.log.info("  interval: {}s", .{config.interval_seconds});

    while (true) {
        const metrics = collectMetrics(allocator, config) catch |err| {
            std.log.err("Failed to collect metrics: {}", .{err});
            std.Thread.sleep(config.interval_seconds * std.time.ns_per_s);
            continue;
        };

        sendMetrics(allocator, config, metrics) catch |err| {
            std.log.err("Failed to send metrics: {}", .{err});
        };

        std.Thread.sleep(config.interval_seconds * std.time.ns_per_s);
    }
}

// --- Config loading ---

fn loadConfig(allocator: std.mem.Allocator) !Config {
    const endpoint = getEnv(allocator, "STATUS_ENDPOINT");
    const api_key = getEnv(allocator, "STATUS_API_KEY");
    const interval_str = getEnv(allocator, "STATUS_INTERVAL");
    const hostname_override = getEnv(allocator, "STATUS_HOSTNAME");

    if (endpoint != null and api_key != null) {
        const interval: u64 = if (interval_str) |s| std.fmt.parseInt(u64, s, 10) catch 60 else 60;
        if (interval_str) |s| allocator.free(s);
        return Config{
            .endpoint = endpoint.?,
            .api_key = api_key.?,
            .interval_seconds = interval,
            .hostname_override = hostname_override,
        };
    }

    if (endpoint) |e| allocator.free(e);
    if (api_key) |k| allocator.free(k);
    if (interval_str) |s| allocator.free(s);
    if (hostname_override) |h| allocator.free(h);

    return loadConfigFile(allocator);
}

fn getEnv(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch return null;
}

fn loadConfigFile(allocator: std.mem.Allocator) !Config {
    const file = std.fs.cwd().openFile("config.ini", .{}) catch {
        return error.ConfigNotFound;
    };
    defer file.close();

    var buf: [8192]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return error.ConfigNotFound;
    const content = buf[0..bytes_read];

    var endpoint: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var interval: u64 = 60;
    var hostname_override: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, &[_]u8{ '\r', ' ', '\t' });
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], &[_]u8{ ' ', '\t' });
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], &[_]u8{ ' ', '\t' });

            if (std.mem.eql(u8, key, "endpoint")) {
                endpoint = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "api_key")) {
                api_key = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "interval")) {
                interval = std.fmt.parseInt(u64, val, 10) catch 60;
            } else if (std.mem.eql(u8, key, "hostname")) {
                hostname_override = try allocator.dupe(u8, val);
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

fn collectMetrics(allocator: std.mem.Allocator, config: Config) !SystemMetrics {
    const hostname = config.hostname_override orelse try getHostname(allocator);
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
        metrics.memory_total, metrics.memory_used = readLinuxMemory() catch .{ null, null };
        metrics.cpu_usage = readLinuxCpuUsage() catch null;
        metrics.uptime_seconds = readLinuxUptime() catch null;
        metrics.disk_total, metrics.disk_used = readLinuxDisk() catch .{ null, null };
    } else if (comptime builtin.os.tag == .windows) {
        metrics.memory_total, metrics.memory_used = readWindowsMemory();
        metrics.uptime_seconds = readWindowsUptime();
    }

    return metrics;
}

fn getHostname(allocator: std.mem.Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.process.getEnvVarOwned(allocator, "COMPUTERNAME") catch {
            return try allocator.dupe(u8, "unknown-windows");
        };
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&buf);
        return try allocator.dupe(u8, hostname);
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

fn readFileContents(path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const n = file.readAll(buf) catch return error.ReadFailed;
    return buf[0..n];
}

fn readLinuxMemory() !struct { ?u64, ?u64 } {
    var buf: [4096]u8 = undefined;
    const content = try readFileContents("/proc/meminfo", &buf);

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

fn readLinuxCpuUsage() !?f64 {
    const sample1 = try readCpuSample();
    std.Thread.sleep(1 * std.time.ns_per_s);
    const sample2 = try readCpuSample();

    const total_diff = sample2.total - sample1.total;
    const idle_diff = sample2.idle - sample1.idle;

    if (total_diff == 0) return null;
    return (1.0 - @as(f64, @floatFromInt(idle_diff)) / @as(f64, @floatFromInt(total_diff))) * 100.0;
}

const CpuSample = struct { total: u64, idle: u64 };

fn readCpuSample() !CpuSample {
    var buf: [512]u8 = undefined;
    const content = try readFileContents("/proc/stat", &buf);

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

fn readLinuxUptime() !?u64 {
    var buf: [64]u8 = undefined;
    const content = try readFileContents("/proc/uptime", &buf);

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

// --- HTTP sender ---

fn sendMetrics(allocator: std.mem.Allocator, config: Config, metrics: SystemMetrics) !void {
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);

    const writer = json_buf.writer(allocator);
    try writer.writeAll("{");
    try std.fmt.format(writer, "\"hostname\":\"{s}\",\"os\":\"{s}\"", .{ metrics.hostname, metrics.os });

    if (metrics.cpu_usage) |v| {
        try std.fmt.format(writer, ",\"cpu_usage\":{d:.1}", .{v});
    }
    if (metrics.memory_total) |v| {
        try std.fmt.format(writer, ",\"memory_total\":{}", .{v});
    }
    if (metrics.memory_used) |v| {
        try std.fmt.format(writer, ",\"memory_used\":{}", .{v});
    }
    if (metrics.disk_total) |v| {
        try std.fmt.format(writer, ",\"disk_total\":{}", .{v});
    }
    if (metrics.disk_used) |v| {
        try std.fmt.format(writer, ",\"disk_used\":{}", .{v});
    }
    if (metrics.uptime_seconds) |v| {
        try std.fmt.format(writer, ",\"uptime_seconds\":{}", .{v});
    }

    try writer.writeAll("}");

    const payload = json_buf.items;
    std.log.info("Sending: {s}", .{payload});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

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

    try req.sendBodyComplete(@constCast(payload));
    var redirect_buf: [4096]u8 = undefined;
    const response = try req.receiveHead(&redirect_buf);

    if (response.head.status == .ok) {
        std.log.info("Status sent successfully for {s}", .{metrics.hostname});
    } else {
        std.log.err("Server returned HTTP {}", .{@intFromEnum(response.head.status)});
    }
}
