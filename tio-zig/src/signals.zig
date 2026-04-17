// tio - a serial device I/O tool (Zig rewrite)
// signals.zig: POSIX signal handling

const std = @import("std");
const posix = std.posix;

/// Flag set to true when SIGTERM/SIGINT is received so the main loop can exit cleanly.
pub var quit_requested: bool = false;

fn handleSigterm(_: c_int) callconv(.C) void {
    quit_requested = true;
}

/// Install default signal handlers:
///   SIGTERM  → set quit_requested
///   SIGHUP   → ignored
///   SIGPIPE  → ignored (we handle write errors explicitly)
pub fn installSignalHandlers() void {
    // SIGTERM → quit
    const sa_term = posix.Sigaction{
        .handler = .{ .handler = handleSigterm },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa_term, null) catch {};

    // SIGHUP → ignore
    const sa_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa_ign, null) catch {};

    // SIGPIPE → ignore (we handle broken pipe errors on write)
    posix.sigaction(posix.SIG.PIPE, &sa_ign, null) catch {};
}
