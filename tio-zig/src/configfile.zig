// tio - a serial device I/O tool (Zig rewrite)
// configfile.zig: INI-style configuration file parser (~/.tiorc)

const std = @import("std");
const options = @import("options.zig");
const rs485 = @import("rs485.zig");
const timestamp = @import("timestamp.zig");
const alert = @import("alert.zig");

pub const ConfigError = error{
    FileNotFound,
    ParseError,
    InvalidValue,
    OutOfMemory,
};

pub const Config = struct {
    path: ?[]const u8 = null,
    active_group: ?[]const u8 = null,
    device: ?[]const u8 = null,
};

/// A key-value map for one profile section.
const Profile = std.StringHashMap([]const u8);

/// The parsed configuration.  Maps profile names to their key-value pairs.
pub const ProfileMap = std.StringHashMap(Profile);

/// Loaded config state.
var loaded_profiles: ?ProfileMap = null;
var arena: ?std.heap.ArenaAllocator = null;
var config_path: ?[]const u8 = null;

/// Locate the config file.  Search order:
///   1. $TIO_CONF environment variable
///   2. $XDG_CONFIG_HOME/tio/config
///   3. $HOME/.config/tio/config
///   4. $HOME/.tiorc
pub fn findConfigPath(allocator: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "TIO_CONF") catch null) |p| return p;

    const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
    if (xdg) |base| {
        defer allocator.free(base);
        const p = std.fmt.allocPrint(allocator, "{s}/tio/config", .{base}) catch return null;
        if (fileExists(p)) return p;
        allocator.free(p);
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const xdg_default = std.fmt.allocPrint(allocator, "{s}/.config/tio/config", .{home}) catch return null;
    if (fileExists(xdg_default)) return xdg_default;
    allocator.free(xdg_default);

    const rc = std.fmt.allocPrint(allocator, "{s}/.tiorc", .{home}) catch return null;
    if (fileExists(rc)) return rc;
    allocator.free(rc);

    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

/// Parse the configuration file at `path`.  All strings are allocated into
/// an internal arena that lives for the process lifetime.
pub fn parseConfigFile(path: []const u8, outer_allocator: std.mem.Allocator) ConfigError!ProfileMap {
    var inner_arena = std.heap.ArenaAllocator.init(outer_allocator);
    const alloc = inner_arena.allocator();

    const content = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return ConfigError.FileNotFound;

    var profiles = ProfileMap.init(alloc);
    var current_group: []const u8 = "default";
    var current_profile = Profile.init(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip blank lines and comments
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        // Handle "include <path>" directives
        if (std.mem.startsWith(u8, line, "include ")) {
            // Recursively parse included file
            const inc_path = std.mem.trim(u8, line[8..], " \t");
            const inc_profiles = parseConfigFile(inc_path, outer_allocator) catch continue;
            var it = inc_profiles.iterator();
            while (it.next()) |entry| {
                try profiles.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            continue;
        }

        // Section header [group]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            // Save current profile
            try profiles.put(current_group, current_profile);
            current_group = try alloc.dupe(u8, line[1 .. line.len - 1]);
            current_profile = Profile.init(alloc);
            continue;
        }

        // Key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try current_profile.put(
            try alloc.dupe(u8, key),
            try alloc.dupe(u8, val),
        );
    }

    // Save the last profile
    try profiles.put(current_group, current_profile);

    // Transfer ownership of the arena
    if (arena) |*a| a.deinit();
    arena = inner_arena;
    config_path = path;

    return profiles;
}

/// Apply the best-matching profile from `profiles` to `opts`.
/// Matching priority:
///   1. Exact device path match (profile name equals `target`)
///   2. Glob pattern match (profile name matches `target`)
///   3. "default" profile
/// Returns the matched device override (if any) so the caller can use it
/// instead of the command-line target.
pub fn applyProfile(
    profiles: *const ProfileMap,
    target: []const u8,
    opts: *options.Options,
    cfg: *Config,
) void {
    // Determine which group to apply
    const group = blk: {
        // Exact match
        if (profiles.get(target)) |_| break :blk target;

        // Pattern match: iterate all groups
        var it = profiles.iterator();
        while (it.next()) |entry| {
            const group_name = entry.key_ptr.*;
            if (std.mem.eql(u8, group_name, "default")) continue;
            if (patternMatchTarget(target, group_name)) break :blk group_name;
        }

        // Fall back to "default"
        break :blk @as([]const u8, "default");
    };

    cfg.active_group = group;

    const profile = profiles.get(group) orelse return;
    applyKv(profile, opts, cfg);
}

fn patternMatchTarget(target: []const u8, group: []const u8) bool {
    // Simple prefix/glob: if group contains '*' or '?' use glob, otherwise exact
    if (std.mem.indexOfAny(u8, group, "*?") != null) {
        // Delegate to misc.globMatch-like logic embedded here to avoid circular dep
        return globMatch(target, group);
    }
    return std.mem.eql(u8, target, group);
}

fn globMatch(str: []const u8, pat: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_si: usize = 0;
    var star_pi: usize = std.math.maxInt(usize);

    while (si < str.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == str[si])) {
            si += 1;
            pi += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            star_si += 1;
            si = star_si;
            pi = star_pi + 1;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn applyKv(profile: Profile, opts: *options.Options, cfg: *Config) void {
    if (profile.get("device")) |v| cfg.device = v;

    if (profile.get("baudrate")) |v| {
        opts.baudrate = std.fmt.parseInt(u32, v, 10) catch opts.baudrate;
    }
    if (profile.get("databits")) |v| {
        opts.databits = std.fmt.parseInt(u8, v, 10) catch opts.databits;
    }
    if (profile.get("stopbits")) |v| {
        opts.stopbits = std.fmt.parseInt(u8, v, 10) catch opts.stopbits;
    }
    if (profile.get("flow")) |v| {
        opts.flow = options.parseFlow(v) orelse opts.flow;
    }
    if (profile.get("parity")) |v| {
        opts.parity = options.parseParity(v) orelse opts.parity;
    }
    if (profile.get("output-delay")) |v| {
        opts.output_delay = std.fmt.parseInt(u32, v, 10) catch opts.output_delay;
    }
    if (profile.get("output-line-delay")) |v| {
        opts.output_line_delay = std.fmt.parseInt(u32, v, 10) catch opts.output_line_delay;
    }
    if (profile.get("no-reconnect")) |v| {
        opts.no_reconnect = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("local-echo")) |v| {
        opts.local_echo = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("log")) |v| {
        opts.log = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("log-file")) |v| opts.log_filename = v;
    if (profile.get("log-directory")) |v| opts.log_directory = v;
    if (profile.get("log-strip")) |v| {
        opts.log_strip = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("log-append")) |v| {
        opts.log_append = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("input-mode")) |v| {
        opts.input_mode = options.parseInputMode(v) orelse opts.input_mode;
    }
    if (profile.get("output-mode")) |v| {
        opts.output_mode = options.parseOutputMode(v) orelse opts.output_mode;
    }
    if (profile.get("timestamp")) |v| {
        opts.timestamp = options.parseTimestamp(v) orelse opts.timestamp;
    }
    if (profile.get("auto-connect")) |v| {
        opts.auto_connect = options.parseAutoConnect(v) orelse opts.auto_connect;
    }
    if (profile.get("socket")) |v| opts.socket = v;
    if (profile.get("color")) |v| {
        if (std.fmt.parseInt(i32, v, 10) catch null) |n| opts.color = n;
    }
    if (profile.get("mute")) |v| {
        opts.mute = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("map")) |v| {
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (std.mem.eql(u8, t, "ICRNL")) opts.map_i_cr_nl = true;
            if (std.mem.eql(u8, t, "IGNCR")) opts.map_ign_cr = true;
            if (std.mem.eql(u8, t, "IFFESCC")) opts.map_i_ff_escc = true;
            if (std.mem.eql(u8, t, "INLCR")) opts.map_i_nl_cr = true;
            if (std.mem.eql(u8, t, "INLCRNL")) opts.map_i_nl_crnl = true;
            if (std.mem.eql(u8, t, "ICRCRNL")) opts.map_i_cr_crnl = true;
            if (std.mem.eql(u8, t, "IMSB2LSB")) opts.map_i_msb2lsb = true;
            if (std.mem.eql(u8, t, "OCRNL")) opts.map_o_cr_nl = true;
            if (std.mem.eql(u8, t, "ODELBS")) opts.map_o_del_bs = true;
            if (std.mem.eql(u8, t, "ONLCRNL")) opts.map_o_nl_crnl = true;
            if (std.mem.eql(u8, t, "OLTU")) opts.map_o_ltu = true;
            if (std.mem.eql(u8, t, "ONULBRK")) opts.map_o_nulbrk = true;
            if (std.mem.eql(u8, t, "OIGNCR")) opts.map_o_ign_cr = true;
        }
    }
    if (profile.get("alert")) |v| {
        opts.alert = options.parseAlert(v) orelse opts.alert;
    }
    if (profile.get("exclude-devices")) |v| opts.exclude_devices = v;
    if (profile.get("exclude-drivers")) |v| opts.exclude_drivers = v;
    if (profile.get("exclude-tids")) |v| opts.exclude_tids = v;
    if (profile.get("rs485")) |v| {
        opts.rs485 = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    if (profile.get("rs485-config")) |v| {
        rs485.parseRs485Config(v, &opts.rs485_cfg);
    }
    if (profile.get("exec")) |v| opts.exec = v;
}

/// Print all profile names to stdout (used by --complete-profiles).
pub fn printProfiles(profiles: *const ProfileMap) void {
    const w = std.io.getStdOut().writer();
    var it = profiles.iterator();
    while (it.next()) |entry| {
        w.print("{s}\n", .{entry.key_ptr.*}) catch {};
    }
}

/// Print the active config information (for ctrl-t c).
pub fn printConfig(cfg: *const Config) void {
    const w = std.io.getStdOut().writer();
    if (cfg.path) |p| w.print(" Config file:      {s}\r\n", .{p}) catch {};
    if (cfg.active_group) |g| w.print(" Active profile:   {s}\r\n", .{g}) catch {};
}

test "parseConfigFile basic" {
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\[default]
        \\baudrate = 115200
        \\databits = 8
        \\
        \\[mydevice]
        \\baudrate = 9600
        \\device = /dev/ttyUSB0
        \\
    ;
    const f = try tmp_dir.dir.createFile("test.tiorc", .{});
    try f.writeAll(content);
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try tmp_dir.dir.realpath("test.tiorc", &path_buf);

    var profiles = try parseConfigFile(full, std.testing.allocator);
    defer {
        var it = profiles.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        profiles.deinit();
    }

    const def = profiles.get("default").?;
    try std.testing.expectEqualStrings("115200", def.get("baudrate").?);

    const my = profiles.get("mydevice").?;
    try std.testing.expectEqualStrings("9600", my.get("baudrate").?);
    try std.testing.expectEqualStrings("/dev/ttyUSB0", my.get("device").?);
}
