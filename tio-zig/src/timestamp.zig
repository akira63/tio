// tio - a serial device I/O tool (Zig rewrite)
// timestamp.zig: timestamp formatting for tio messages

const std = @import("std");
const posix = std.posix;

pub const Timestamp = enum(u8) {
    none,
    hour24,
    hour24_start,
    hour24_delta,
    iso8601,
    epoch,
    epoch_usec,
};

pub const TIME_STRING_SIZE_MAX = 32;

const State = struct {
    first: bool = true,
    start_sec: i64 = 0,
    start_usec: i64 = 0,
    prev_sec: i64 = 0,
    prev_usec: i64 = 0,
    buf: [TIME_STRING_SIZE_MAX]u8 = undefined,
};

var state = State{};

/// Get the current timestamp string.  The returned slice is backed by a
/// module-level static buffer; callers must not hold it across calls.
pub fn currentTime(ts_mode: Timestamp) ?[]const u8 {
    // Get wall-clock time
    const now = posix.gettimeofday() catch return null;
    const now_sec = now.tv_sec;
    const now_usec = now.tv_usec;

    if (state.first) {
        state.start_sec = now_sec;
        state.start_usec = now_usec;
        state.first = false;
    }

    var len: usize = 0;
    const buf = &state.buf;

    switch (ts_mode) {
        .none, .hour24 => {
            // Local time "HH:MM:SS"
            const t = toLocalTm(now_sec);
            len = formatTime(buf, t, false);
        },
        .hour24_start => {
            // Elapsed since start "HH:MM:SS"
            const elapsed = elapsed_secs(now_sec, now_usec, state.start_sec, state.start_usec);
            const t = gmtime(elapsed);
            len = formatTime(buf, t, false);
        },
        .hour24_delta => {
            // Delta since previous call "HH:MM:SS"
            const elapsed = elapsed_secs(now_sec, now_usec, state.prev_sec, state.prev_usec);
            const t = gmtime(elapsed);
            len = formatTime(buf, t, false);
        },
        .iso8601 => {
            // "YYYY-MM-DDThh:mm:ss"
            const t = toLocalTm(now_sec);
            len = formatIso8601(buf, t);
        },
        .epoch, .epoch_usec => {
            // Seconds since Unix epoch
            len = std.fmt.bufPrint(buf, "{d}", .{now_sec}) catch return null;
        },
    }

    // Append milliseconds or microseconds
    if (len > 0 and len < TIME_STRING_SIZE_MAX) {
        const sub = if (ts_mode == .epoch_usec)
            std.fmt.bufPrint(buf[len..], ".{d:0>6}", .{now_usec}) catch return null
        else
            std.fmt.bufPrint(buf[len..], ".{d:0>3}", .{@divTrunc(now_usec, 1000)}) catch return null;
        len += sub.len;
    }

    state.prev_sec = now_sec;
    state.prev_usec = now_usec;

    if (len == 0 or len >= TIME_STRING_SIZE_MAX) return null;
    return buf[0..len];
}

// Simple broken-down time struct (subset of struct tm)
const Tm = struct {
    sec: i64 = 0,
    min: i64 = 0,
    hour: i64 = 0,
    mday: i64 = 1,
    mon: i64 = 0, // 0-11
    year: i64 = 0, // since 1900
};

fn elapsed_secs(a_sec: i64, a_usec: i64, b_sec: i64, b_usec: i64) i64 {
    _ = a_usec;
    _ = b_usec;
    return a_sec - b_sec;
}

fn toLocalTm(epoch_sec: i64) Tm {
    // Use C's localtime via @cImport, or implement a simple UTC-only version.
    // For simplicity, we implement a UTC-based breakdown (real localtime requires TZ support).
    return gmtime(epoch_sec);
}

fn gmtime(epoch_sec: i64) Tm {
    // Days per month in a non-leap year
    const days_per_month = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var sec = epoch_sec;
    const s = @mod(sec, 60);
    sec = @divFloor(sec, 60);
    const m = @mod(sec, 60);
    sec = @divFloor(sec, 60);
    const h = @mod(sec, 24);
    var days = @divFloor(sec, 24);

    // Compute year
    var year: i64 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeap(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    // Compute month
    var mon: i64 = 0;
    while (mon < 12) {
        var dim = days_per_month[@intCast(mon)];
        if (mon == 1 and isLeap(year)) dim += 1;
        if (days < dim) break;
        days -= dim;
        mon += 1;
    }

    return Tm{
        .sec = s,
        .min = m,
        .hour = h,
        .mday = days + 1,
        .mon = mon,
        .year = year - 1900,
    };
}

fn isLeap(y: i64) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn formatTime(buf: []u8, t: Tm, _: bool) usize {
    const s = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.min, t.sec }) catch return 0;
    return s.len;
}

fn formatIso8601(buf: []u8, t: Tm) usize {
    const s = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        t.year + 1900, t.mon + 1, t.mday, t.hour, t.min, t.sec,
    }) catch return 0;
    return s.len;
}

test "currentTime none" {
    const s = currentTime(.none);
    try std.testing.expect(s != null);
    try std.testing.expect(s.?.len > 0);
}
