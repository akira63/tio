// tio - a serial device I/O tool (Zig rewrite)
// rs485.zig: RS-485 mode support (Linux only)

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// RS-485 configuration flags (mirrors the C SER_RS485_* defines).
pub const Rs485Flags = packed struct(u32) {
    enabled: bool = false,
    rts_on_send: bool = false,
    rts_after_send: bool = false,
    rx_during_tx: bool = false,
    terminate_bus: bool = false,
    _reserved: u27 = 0,
};

pub const Rs485Config = struct {
    flags: u32 = 0,
    delay_rts_before_send: i32 = 0,
    delay_rts_after_send: i32 = 0,
};

// Linux serial_rs485 struct layout (from linux/serial.h)
const SerialRs485 = extern struct {
    flags: u32,
    delay_rts_before_send: u32,
    delay_rts_after_send: u32,
    _padding: [5]u32 = [_]u32{0} ** 5,
};

// TIOCSRS485 / TIOCGRS485 ioctl numbers on Linux
const TIOCSRS485: u32 = 0x542F;
const TIOCGRS485: u32 = 0x542E;

// SER_RS485 flags
pub const SER_RS485_ENABLED: u32 = 1 << 0;
pub const SER_RS485_RTS_ON_SEND: u32 = 1 << 1;
pub const SER_RS485_RTS_AFTER_SEND: u32 = 1 << 2;
pub const SER_RS485_RX_DURING_TX: u32 = 1 << 4;
pub const SER_RS485_TERMINATE_BUS: u32 = 1 << 5;

var saved_rs485: SerialRs485 = undefined;
var rs485_saved: bool = false;

/// Enable RS-485 mode on `fd` using `cfg`.
pub fn enableRs485(fd: posix.fd_t, cfg: Rs485Config) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    // Save original RS-485 state
    const rc_get = std.os.linux.ioctl(fd, TIOCGRS485, @intFromPtr(&saved_rs485));
    if (rc_get == 0) rs485_saved = true;

    var rs485 = SerialRs485{
        .flags = cfg.flags | SER_RS485_ENABLED,
        .delay_rts_before_send = if (cfg.delay_rts_before_send >= 0) @intCast(cfg.delay_rts_before_send) else 0,
        .delay_rts_after_send = if (cfg.delay_rts_after_send >= 0) @intCast(cfg.delay_rts_after_send) else 0,
    };

    const rc = std.os.linux.ioctl(fd, TIOCSRS485, @intFromPtr(&rs485));
    if (rc != 0) return error.IoctlFailed;
}

/// Restore the RS-485 state that was saved when enableRs485 was called.
pub fn restoreRs485(fd: posix.fd_t) void {
    if (!rs485_saved) return;
    if (builtin.os.tag != .linux) return;
    _ = std.os.linux.ioctl(fd, TIOCSRS485, @intFromPtr(&saved_rs485));
    rs485_saved = false;
}

/// Parse an RS-485 config string of the form:
///   "RTS_ON_SEND,RTS_AFTER_SEND,DELAY_BEFORE=N,DELAY_AFTER=N"
pub fn parseRs485Config(arg: []const u8, cfg: *Rs485Config) void {
    var it = std.mem.splitScalar(u8, arg, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (std.mem.eql(u8, t, "RTS_ON_SEND")) {
            cfg.flags |= SER_RS485_RTS_ON_SEND;
        } else if (std.mem.eql(u8, t, "RTS_AFTER_SEND")) {
            cfg.flags |= SER_RS485_RTS_AFTER_SEND;
        } else if (std.mem.eql(u8, t, "RX_DURING_TX")) {
            cfg.flags |= SER_RS485_RX_DURING_TX;
        } else if (std.mem.eql(u8, t, "TERMINATE_BUS")) {
            cfg.flags |= SER_RS485_TERMINATE_BUS;
        } else if (std.mem.startsWith(u8, t, "DELAY_BEFORE=")) {
            cfg.delay_rts_before_send = std.fmt.parseInt(i32, t[13..], 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "DELAY_AFTER=")) {
            cfg.delay_rts_after_send = std.fmt.parseInt(i32, t[12..], 10) catch 0;
        }
    }
}

pub fn printRs485Config(cfg: Rs485Config) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(" RS-485 config flags: 0x{x:0>8}\r\n", .{cfg.flags}) catch {};
    stdout.print(" RS-485 delay RTS before send: {d} ms\r\n", .{cfg.delay_rts_before_send}) catch {};
    stdout.print(" RS-485 delay RTS after send:  {d} ms\r\n", .{cfg.delay_rts_after_send}) catch {};
}
