// tio - a serial device I/O tool (Zig rewrite)
// readline.zig: line-mode input with simple command-history support

const std = @import("std");
const posix = std.posix;

const MAX_LINE = 4096;
const MAX_HISTORY = 64;

const State = struct {
    buf: [MAX_LINE]u8 = [_]u8{0} ** MAX_LINE,
    len: usize = 0,
    history: [MAX_HISTORY][MAX_LINE]u8 = undefined,
    hist_len: usize = 0,
    hist_pos: usize = 0,
};

var state = State{};

pub fn readlineInit() void {
    state.len = 0;
    state.hist_len = 0;
    state.hist_pos = 0;
}

/// Feed a character into the line editor.
/// Returns true when the line is complete (CR received).
pub fn readlineInput(c: u8) bool {
    switch (c) {
        '\r', '\n' => {
            // Line complete
            state.buf[state.len] = '\r';
            state.len += 1;
            if (state.len > 1) {
                saveHistory();
            }
            return true;
        },
        0x08, 0x7f => {
            // Backspace / DEL
            if (state.len > 0) {
                state.len -= 1;
                _ = posix.write(posix.STDOUT_FILENO, "\x08 \x08") catch {};
            }
        },
        0x1b => {
            // Start of escape sequence (arrow keys for history) – handled partially
        },
        else => {
            if (state.len < MAX_LINE - 2) {
                state.buf[state.len] = c;
                state.len += 1;
                _ = posix.write(posix.STDOUT_FILENO, &[_]u8{c}) catch {};
            }
        },
    }
    return false;
}

/// Return the completed line (including the trailing CR).
pub fn readlineGet() []const u8 {
    const result = state.buf[0..state.len];
    state.len = 0;
    return result;
}

fn saveHistory() void {
    if (state.hist_len < MAX_HISTORY) {
        @memcpy(&state.history[state.hist_len], &state.buf);
        state.hist_len += 1;
    } else {
        // Shift history
        var i: usize = 0;
        while (i < MAX_HISTORY - 1) : (i += 1) {
            @memcpy(&state.history[i], &state.history[i + 1]);
        }
        @memcpy(&state.history[MAX_HISTORY - 1], &state.buf);
    }
    state.hist_pos = state.hist_len;
}

test "readline basic" {
    readlineInit();
    _ = readlineInput('h');
    _ = readlineInput('i');
    const done = readlineInput('\r');
    try std.testing.expect(done);
    const line = readlineGet();
    try std.testing.expectEqualSlices(u8, "hi\r", line);
}
