// tio - a serial device I/O tool (Zig rewrite)
// main.zig: program entry point
//
// Lua scripting dependency has been completely removed from this rewrite.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const options   = @import("options.zig");
const tty       = @import("tty.zig");
const configfile= @import("configfile.zig");
const print     = @import("print.zig");
const log       = @import("log.zig");
const signals   = @import("signals.zig");
const socket    = @import("socket.zig");
const fs_mod    = @import("fs.zig");
const timestamp = @import("timestamp.zig");
const misc      = @import("misc.zig");

pub fn main() !void {
    // ── Allocator ──────────────────────────────────────────────────────────
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── Parse command-line arguments ───────────────────────────────────────
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    var arg_list = std.ArrayList([]const u8).init(allocator);
    defer arg_list.deinit();
    while (args_iter.next()) |a| try arg_list.append(a);

    var opts = options.parseArgs(arg_list.items, allocator) catch |err| {
        std.io.getStdErr().writer().print("tio: argument error: {any}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // ── ANSI color initialization ──────────────────────────────────────────
    // Disable color if NO_COLOR env var is set or stdout is not a tty
    const no_color = std.process.getEnvVarOwned(allocator, "NO_COLOR") catch null;
    if (no_color != null or !posix.isatty(posix.STDOUT_FILENO)) {
        opts.color = -1;
    }
    if (no_color) |v| allocator.free(v);
    print.initAnsiFormatting(opts.color);

    // ── List serial devices and exit ───────────────────────────────────────
    if (opts.list_devices) {
        tty.listSerialDevices(&opts, allocator);
        return;
    }

    // ── Read and apply configuration file ─────────────────────────────────
    var cfg = configfile.Config{};

    if (configfile.findConfigPath(allocator)) |conf_path| {
        cfg.path = conf_path;
        var profiles = configfile.parseConfigFile(conf_path, allocator) catch blk: {
            // Config file not found or malformed; continue with defaults
            break :blk configfile.ProfileMap.init(allocator);
        };
        defer {
            var it = profiles.iterator();
            while (it.next()) |e| e.value_ptr.deinit();
            profiles.deinit();
        }

        // Print profiles for shell completion and exit
        if (opts.complete_profiles) {
            configfile.printProfiles(&profiles);
            return;
        }

        configfile.applyProfile(&profiles, opts.target, &opts, &cfg);
    }

    // ── Require a device target ────────────────────────────────────────────
    if (opts.target.len == 0 and opts.auto_connect == .direct) {
        std.io.getStdErr().writer().print(
            "tio: no device specified; use -h for help or --list to list serial devices\n", .{},
        ) catch {};
        std.process.exit(1);
    }

    // ── Install signal handlers ────────────────────────────────────────────
    signals.installSignalHandlers();

    // ── Configure TTY port parameters ─────────────────────────────────────
    tty.ttyConfigure(&opts) catch |err| {
        std.io.getStdErr().writer().print("tio: invalid port configuration: {any}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // ── Detect interactive mode ────────────────────────────────────────────
    const is_interactive = posix.isatty(posix.STDIN_FILENO);

    // ── Configure stdout/stdin for raw I/O ────────────────────────────────
    if (is_interactive) {
        tty.stdoutConfigure(&opts) catch |err| {
            std.io.getStdErr().writer().print("tio: failed to configure stdout: {any}\n", .{err}) catch {};
            std.process.exit(1);
        };
    }

    // Ensure we restore terminal settings on exit
    defer {
        tty.stdinRestore();
        tty.stdoutRestore(&opts);
        if (opts.log) log.logClose(opts.mute);
        socket.socketExit();
    }

    // ── Configure socket (if requested) ───────────────────────────────────
    if (opts.socket) |sock_str| {
        socket.socketConfigure(sock_str) catch |err| {
            std.io.getStdErr().writer().print("tio: socket error: {any}\n", .{err}) catch {};
            std.process.exit(1);
        };
    }

    // ── Open log file (if requested) ──────────────────────────────────────
    if (opts.log) {
        log.logOpen(
            opts.log_filename,
            opts.log_append,
            opts.target,
            @tagName(opts.auto_connect),
            opts.log_directory,
            allocator,
        ) catch |err| {
            std.io.getStdErr().writer().print("tio: could not open log file: {any}\n", .{err}) catch {};
            opts.log = false;
        };
    }

    // ── Create stdin reader thread ─────────────────────────────────────────
    tty.ttyInputThreadCreate(&opts) catch |err| {
        std.io.getStdErr().writer().print("tio: could not create stdin thread: {any}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // ── Configure stdin for raw mode ──────────────────────────────────────
    if (is_interactive) {
        tty.stdinConfigure() catch |err| {
            std.io.getStdErr().writer().print("tio: failed to configure stdin: {any}\n", .{err}) catch {};
            std.process.exit(1);
        };
    }

    // ── Main connection loop ───────────────────────────────────────────────
    while (!signals.quit_requested) {
        tty.ttyWaitForDevice(&opts, &cfg, allocator);

        tty.ttyConnect(&opts, &cfg, allocator) catch |err| {
            switch (err) {
                error.DeviceRead, error.DeviceLocked => {
                    // Device unplugged or locked; reconnect unless disabled
                    if (opts.no_reconnect) break;
                },
                else => break,
            }
        };

        if (opts.no_reconnect or signals.quit_requested) break;

        // Brief delay before attempting reconnect
        misc.delay(100);
    }
}

// ── Module tests ──────────────────────────────────────────────────────────

const misc_mod = @import("misc.zig");
const opts_mod = @import("options.zig");
const cf_mod   = @import("configfile.zig");
const rl_mod   = @import("readline.zig");
const xy_mod   = @import("xymodem.zig");
const ts_mod   = @import("timestamp.zig");

test {
    // Pull in tests from all submodules
    _ = misc_mod;
    _ = opts_mod;
    _ = rl_mod;
    _ = xy_mod;
    _ = ts_mod;
}
