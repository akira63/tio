// tio - a serial device I/O tool (Zig rewrite)
// print.zig: ANSI-colored output helpers

const std = @import("std");
const timestamp = @import("timestamp.zig");

const stdout = std.io.getStdOut();
const stderr = std.io.getStdErr();

/// When true the last character written to stdout was a data byte (not a
/// tio message), so the next tio message should start with a newline.
pub var print_tainted: bool = false;

/// Current ANSI color escape string (empty when color is disabled).
pub var ansi_format: [32]u8 = [_]u8{0} ** 32;
pub var ansi_format_len: usize = 0;

const ANSI_RESET = "\x1b[0m";

/// Set `print_tainted` to indicate that data output is in progress.
pub fn printTaintedSet() void {
    print_tainted = true;
}

/// Initialise ANSI formatting from a color value.
///  -1  → no color (plain text)
/// 256  → bold
/// 0-255→ 256-colour foreground
pub fn initAnsiFormatting(color: i32) void {
    if (color < 0) {
        ansi_format_len = 0;
        return;
    }
    const s = if (color == 256)
        std.fmt.bufPrint(&ansi_format, "\x1b[1m", .{}) catch &ansi_format[0..0]
    else
        std.fmt.bufPrint(&ansi_format, "\x1b[38;5;{d}m", .{color}) catch &ansi_format[0..0];
    ansi_format_len = s.len;
}

/// Internal: write a tio-formatted line to `writer`.
fn writeLine(writer: anytype, comptime prefix: []const u8, ts_mode: timestamp.Timestamp, color: i32, mute: bool, comptime fmt: []const u8, args: anytype) void {
    if (mute) return;
    if (print_tainted) {
        writer.writeByte('\n') catch {};
        print_tainted = false;
    }
    if (color >= 0) {
        writer.writeAll(ansi_format[0..ansi_format_len]) catch {};
    }
    const ts = timestamp.currentTime(ts_mode) orelse "??:??:??";
    writer.print("\r" ++ prefix ++ "[{s}] " ++ fmt ++ ANSI_RESET ++ "\r\n", .{ts} ++ args) catch {};
}

/// Print a tio status message prefixed with a timestamp.
pub fn tioPrint(ts_mode: timestamp.Timestamp, color: i32, mute: bool, comptime fmt: []const u8, args: anytype) void {
    writeLine(stdout.writer(), "", ts_mode, color, mute, fmt, args);
}

/// Print a tio warning message.
pub fn tioWarning(ts_mode: timestamp.Timestamp, color: i32, mute: bool, comptime fmt: []const u8, args: anytype) void {
    writeLine(stdout.writer(), "Warning: ", ts_mode, color, mute, fmt, args);
}

/// Print a tio error message to stderr.
pub fn tioError(error_normal: bool, ts_mode: timestamp.Timestamp, color: i32, mute: bool, comptime fmt: []const u8, args: anytype) void {
    if (mute) return;
    if (print_tainted) {
        stdout.writer().writeByte('\n') catch {};
        print_tainted = false;
    }
    const writer = stderr.writer();
    if (color >= 0) writer.writeAll(ansi_format[0..ansi_format_len]) catch {};
    if (error_normal) {
        writer.print("\rError: " ++ fmt ++ ANSI_RESET ++ "\r\n", args) catch {};
    } else {
        const ts = timestamp.currentTime(ts_mode) orelse "??:??:??";
        writer.print("\r[{s}] Error: " ++ fmt ++ ANSI_RESET ++ "\r\n", .{ts} ++ args) catch {};
    }
}

/// Print raw data character in normal mode (just write to stdout).
pub fn printNormal(c: u8) void {
    stdout.writer().writeByte(c) catch {};
}

/// Print raw data character in hex mode ("xx ").
pub fn printHex(c: u8) void {
    stdout.writer().print("{x:0>2} ", .{c}) catch {};
}

/// Print a raw format string (no timestamp, respects color).
pub fn printRaw(color: i32, mute: bool, comptime fmt: []const u8, args: anytype) void {
    if (mute) return;
    const w = stdout.writer();
    if (color >= 0) w.writeAll(ansi_format[0..ansi_format_len]) catch {};
    w.print(fmt, args) catch {};
    if (color >= 0) w.writeAll(ANSI_RESET) catch {};
}

/// Print an array of bytes as-is to stdout (used for the coffee-break easter egg).
pub fn printArray(data: []const u8) void {
    stdout.writer().writeAll(data) catch {};
}

/// Print a string left-padded to `length` with `pad_char`.
pub fn printPadded(s: []const u8, length: usize, pad_char: u8) void {
    const w = stdout.writer();
    w.writeAll(s) catch {};
    if (s.len < length) {
        var i = s.len;
        while (i < length) : (i += 1) w.writeByte(pad_char) catch {};
    }
}

/// Clear the current terminal line.
pub fn clearLine() void {
    stdout.writer().writeAll("\r\x1b[K") catch {};
}
