// tio - a serial device I/O tool (Zig rewrite)
// alert.zig: audible/visual alerts on connect/disconnect

const std = @import("std");
const posix = std.posix;

pub const Alert = enum(u8) {
    none,
    bell,
    blink,
};

fn blinkBackground() void {
    // Reverse video on
    _ = posix.write(posix.STDOUT_FILENO, "\x1b[?5h") catch {};
    std.time.sleep(200 * std.time.ns_per_ms);
    // Reverse video off
    _ = posix.write(posix.STDOUT_FILENO, "\x1b[?5l") catch {};
}

fn soundBell() void {
    _ = posix.write(posix.STDOUT_FILENO, "\x07") catch {};
}

pub fn alertConnect(alert: Alert) void {
    switch (alert) {
        .none => {},
        .bell => soundBell(),
        .blink => blinkBackground(),
    }
}

pub fn alertDisconnect(alert: Alert) void {
    switch (alert) {
        .none => {},
        .bell => {
            soundBell();
            std.time.sleep(200 * std.time.ns_per_ms);
            soundBell();
        },
        .blink => {
            blinkBackground();
            std.time.sleep(200 * std.time.ns_per_ms);
            blinkBackground();
        },
    }
}
