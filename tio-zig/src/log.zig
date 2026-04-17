// tio - a serial device I/O tool (Zig rewrite)
// log.zig: log serial I/O to a file

const std = @import("std");
const posix = std.posix;

pub const OutputMode = enum { normal, hex };

const State = struct {
    file: ?std.fs.File = null,
    filename: ?[]const u8 = null,
};

var state = State{};

/// Open the log file.  If `filename` is null, an automatic name is generated
/// from `target` and the current date/time.
pub fn logOpen(
    filename: ?[]const u8,
    append: bool,
    target: []const u8,
    auto_connect_str: []const u8,
    log_directory: ?[]const u8,
    allocator: std.mem.Allocator,
) !void {
    const actual_name = blk: {
        if (filename) |f| {
            break :blk f;
        }
        // Auto-generate filename
        const base = if (target.len > 0)
            std.fs.path.basename(target)
        else
            auto_connect_str;

        // Timestamp component
        const ts = timestamp: {
            const sec = std.time.timestamp();
            const ep = std.time.epoch.EpochSeconds{ .secs = @intCast(sec) };
            const day = ep.getDaySeconds();
            const yr = ep.getEpochDay().calculateYearDay();
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
                yr.year,
                yr.calculateMonthDay().month.numeric(),
                yr.calculateMonthDay().day_index + 1,
                day.getHoursIntoDay(),
                day.getMinutesIntoHour(),
                day.getSecondsIntoMinute(),
            }) catch "unknown";
            break :timestamp s;
        };

        const auto = try std.fmt.allocPrint(allocator, "tio_{s}_{s}.log", .{ base, ts });
        if (log_directory) |dir| {
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, auto });
        }
        break :blk auto;
    };

    state.filename = actual_name;
    const flags = std.fs.File.CreateFlags{
        .exclusive = false,
        .truncate = !append,
        .read = false,
    };
    state.file = try std.fs.cwd().createFile(actual_name, flags);
}

/// Write a single character to the log file.
pub fn logPutc(c: u8, output_mode: OutputMode, strip: bool) void {
    const f = state.file orelse return;
    const w = f.writer();
    if (output_mode == .hex) {
        w.print("{x:0>2} ", .{c}) catch {};
        return;
    }
    if (strip and shouldStrip(c)) return;
    w.writeByte(c) catch {};
}

/// Write a formatted string to the log file.
pub fn logWrite(comptime fmt: []const u8, args: anytype) void {
    const f = state.file orelse return;
    f.writer().print(fmt, args) catch {};
}

/// Close the log file and print a message.
pub fn logClose(mute: bool) void {
    if (state.file) |f| {
        f.close();
        state.file = null;
        if (!mute) {
            if (state.filename) |name| {
                const stdout = std.io.getStdOut().writer();
                stdout.print("\r\nSaved log to file {s}\r\n", .{name}) catch {};
            }
        }
    }
}

/// Returns true if the log file is currently open.
pub fn logIsOpen() bool {
    return state.file != null;
}

pub fn logGetFilename() ?[]const u8 {
    return state.filename;
}

// ── Strip logic (remove control characters and ANSI escape sequences) ──

const StripState = struct {
    esc_seq: bool = false,
    prev: u8 = 0,
};
var strip_state = StripState{};

fn shouldStrip(c: u8) bool {
    defer strip_state.prev = c;

    switch (c) {
        0x0a => {
            // LF: reset escape sequence tracking
            strip_state.esc_seq = false;
            return false;
        },
        0x1b => {
            return true; // ESC
        },
        0x5b => {
            if (strip_state.prev == 0x1b) {
                strip_state.esc_seq = true;
                return true;
            }
        },
        else => {
            // ASCII control characters
            if (c <= 0x1f) return true;
            // Inside ESC CSI intermediate chars
            if (strip_state.esc_seq and c >= 0x20 and c <= 0x3f) return true;
            // ESC CSI final byte
            if (strip_state.esc_seq and c >= 0x40 and c <= 0x7e) {
                strip_state.esc_seq = false;
                return true;
            }
        },
    }
    return false;
}
