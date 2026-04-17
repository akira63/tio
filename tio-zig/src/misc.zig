// tio - a serial device I/O tool (Zig rewrite)
// misc.zig: general-purpose utility functions

const std = @import("std");
const posix = std.posix;

/// Sleep for `ms` milliseconds.
pub fn delay(ms: u64) void {
    if (ms == 0) return;
    std.time.sleep(ms * std.time.ns_per_ms);
}

/// Convert an ASCII key letter (a-z) to its control-key code.
/// Returns -1 if the key is not in the a-z range.
pub fn ctrlKeyCode(key: u8) i32 {
    if (key >= 'a' and key <= 'z') {
        return @as(i32, key & ~@as(u8, 0x60));
    }
    return -1;
}

/// DJB2 hash function for a byte slice.
pub fn djb2Hash(str: []const u8) u64 {
    var hash: u64 = 5381;
    for (str) |c| {
        hash = ((hash << 5) +% hash) +% c; // hash * 33 + c
    }
    return hash;
}

const BASE62_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Encode a number as a 4-character base-62 string.
/// `output` must be at least 5 bytes (4 chars + null terminator).
pub fn base62Encode(num: u64, output: []u8) void {
    std.debug.assert(output.len >= 5);
    var n = num;
    for (0..4) |i| {
        output[i] = BASE62_CHARS[n % 62];
        n /= 62;
    }
    output[4] = 0;
}

/// Return the current wall-clock time as seconds since the Unix epoch (float).
pub fn getCurrentTime() f64 {
    const ts = posix.clock_gettime(.REALTIME) catch return -1;
    return @as(f64, @floatFromInt(ts.tv_sec)) + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e9;
}

/// Poll `fd` for readability, then read up to `len` bytes into `data`.
/// `timeout_ms` is the poll timeout in milliseconds (0 = wait forever, -1 = no wait).
/// Returns the number of bytes read, 0 on timeout, or a negative error.
pub fn readPoll(fd: posix.fd_t, data: []u8, timeout_ms: i32) !usize {
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const n = try posix.poll(&fds, timeout_ms);
    if (n == 0) return 0; // timeout
    if (fds[0].revents & posix.POLL.IN != 0) {
        return posix.read(fd, data);
    }
    return 0;
}

/// Simple glob / fnmatch-style pattern matching against a comma-separated list of patterns.
/// Supports '*' and '?' wildcards.
pub fn matchPatterns(string: []const u8, patterns: []const u8) bool {
    var iter = std.mem.splitScalar(u8, patterns, ',');
    while (iter.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, " \t");
        if (trimmed.len == 0) continue;
        if (globMatch(string, trimmed)) return true;
    }
    return false;
}

/// Minimal glob match: supports '*' (any sequence) and '?' (any single char).
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
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') {
        pi += 1;
    }
    return pi == pat.len;
}

/// Execute a shell command with stdin/stdout redirected to `fd`.
pub fn executeShellCommand(fd: posix.fd_t, command: []const u8, allocator: std.mem.Allocator) !i32 {
    const pid = try posix.fork();
    if (pid == 0) {
        // Child process: redirect stdout and stderr to the serial device fd
        try posix.dup2(fd, posix.STDOUT_FILENO);
        try posix.dup2(fd, posix.STDERR_FILENO);
        const args = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            try allocator.dupeZ(u8, command),
            null,
        };
        const envp = [_:null]?[*:0]const u8{null};
        posix.execveZ("/bin/sh", &args, &envp) catch {};
        posix.exit(127);
    }
    // Parent: wait for child
    const result = posix.waitpid(pid, 0);
    if (posix.W.IFEXITED(result.status)) {
        return @intCast(posix.W.EXITSTATUS(result.status));
    }
    return -1;
}

test "djb2Hash" {
    const h = djb2Hash("hello");
    try std.testing.expect(h != 0);
}

test "globMatch" {
    try std.testing.expect(globMatch("/dev/ttyUSB0", "/dev/ttyUSB*"));
    try std.testing.expect(globMatch("/dev/ttyACM0", "/dev/ttyACM?"));
    try std.testing.expect(!globMatch("/dev/ttyUSB0", "/dev/ttyACM*"));
}

test "base62Encode" {
    var buf: [5]u8 = undefined;
    base62Encode(12345, &buf);
    try std.testing.expect(buf[4] == 0);
}

test "matchPatterns" {
    try std.testing.expect(matchPatterns("/dev/ttyUSB0", "/dev/ttyUSB*,/dev/ttyACM*"));
    try std.testing.expect(!matchPatterns("/dev/ttyS0", "/dev/ttyUSB*,/dev/ttyACM*"));
}
