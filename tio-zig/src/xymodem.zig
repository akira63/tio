// tio - a serial device I/O tool (Zig rewrite)
// xymodem.zig: X-modem (1K/CRC) and Y-modem file send protocol

const std = @import("std");
const posix = std.posix;
const misc = @import("misc.zig");

pub const ModemMode = enum { xmodem_1k, xmodem_crc, ymodem };

// Protocol control bytes
const SOH: u8 = 0x01; // 128-byte block header
const STX: u8 = 0x02; // 1024-byte block header
const ACK: u8 = 0x06;
const NAK: u8 = 0x15;
const CAN: u8 = 0x18;
const EOT: u8 = 0x04;
const C_BYTE: u8 = 'C';

/// Sent by the transfer loop when the user presses any key.
pub var key_hit: u8 = 0xff;

const RETRY_MAX = 10;
const TIMEOUT_MS = 10_000;
const NAK_TIMEOUT_MS = 3_000;

// CRC-16/CCITT
fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        var s = b ^ @as(u8, @intCast(crc >> 8));
        s ^= s >> 4;
        crc = (crc << 8) ^ @as(u16, s) ^ (@as(u16, s) << 5) ^ (@as(u16, s) << 12);
    }
    return crc;
}

/// Send `filename` over the serial device `sio` using `mode`.
/// Returns 0 on success, -1 on error/abort.
pub fn xymodemSend(sio: posix.fd_t, filename: []const u8, mode: ModemMode) !i32 {
    // Open the file
    const file = std.fs.cwd().openFile(filename, .{}) catch return error.FileOpenFailed;
    defer file.close();

    const file_size = (file.stat() catch return error.StatFailed).size;
    const data = try std.posix.mmap(null, file_size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(data);

    const block_size: usize = if (mode == .xmodem_crc) 128 else 1024;

    // Wait for receiver ready ('C' for CRC mode, NAK for checksum mode)
    const ready = try waitForReady(sio);
    if (!ready) return -1;

    var seq: u8 = if (mode == .ymodem) 0 else 1;

    // Y-modem: send block 0 (filename + size)
    if (mode == .ymodem) {
        var hdr: [1024]u8 = [_]u8{0} ** 1024;
        const basename = std.fs.path.basename(filename);
        @memcpy(hdr[0..basename.len], basename);
        const size_str = std.fmt.bufPrint(hdr[basename.len + 1 ..], "{d}", .{file_size}) catch {};
        _ = size_str;
        if (try sendBlock(sio, &hdr, block_size, seq, true) < 0) return -1;
        seq +%= 1;
        _ = try waitForReady(sio);
    }

    // Send data blocks
    var offset: usize = 0;
    while (offset < data.len) {
        var block: [1024]u8 = [_]u8{0x1a} ** 1024; // pad with CTRL-Z
        const chunk_size = @min(block_size, data.len - offset);
        @memcpy(block[0..chunk_size], data[offset .. offset + chunk_size]);
        const rc = try sendBlock(sio, &block, block_size, seq, true);
        if (rc < 0) return -1;
        offset += chunk_size;
        seq +%= 1;
    }

    // EOT
    var retry: usize = 0;
    while (retry < RETRY_MAX) : (retry += 1) {
        _ = posix.write(sio, &[_]u8{EOT}) catch return -1;
        var resp: u8 = 0;
        const n = misc.readPoll(sio, std.mem.asBytes(&resp), 5000) catch return -1;
        if (n > 0 and resp == ACK) break;
    }

    // Y-modem: send empty block 0
    if (mode == .ymodem) {
        _ = try waitForReady(sio);
        var empty_hdr: [1024]u8 = [_]u8{0} ** 1024;
        _ = try sendBlock(sio, &empty_hdr, 128, 0, true);
    }

    return 0;
}

fn waitForReady(sio: posix.fd_t) !bool {
    var retry: usize = 0;
    while (retry < RETRY_MAX) : (retry += 1) {
        var buf: [1]u8 = undefined;
        const n = misc.readPoll(sio, &buf, NAK_TIMEOUT_MS) catch return false;
        if (n == 0) continue;
        if (buf[0] == C_BYTE or buf[0] == NAK) return true;
        if (buf[0] == CAN) return false;
    }
    return false;
}

fn sendBlock(sio: posix.fd_t, data: []const u8, block_size: usize, seq: u8, use_crc: bool) !i32 {
    var retry: usize = 0;
    while (retry < RETRY_MAX) : (retry += 1) {
        // Check if user pressed a key (abort)
        if (key_hit != 0xff and key_hit != 0) return -1;

        // Build block header
        const header: u8 = if (block_size == 1024) STX else SOH;
        _ = posix.write(sio, &[_]u8{ header, seq, ~seq }) catch return -1;
        _ = posix.write(sio, data[0..block_size]) catch return -1;

        if (use_crc) {
            const crc = crc16(data[0..block_size]);
            const crc_bytes = [_]u8{ @intCast(crc >> 8), @truncate(crc) };
            _ = posix.write(sio, &crc_bytes) catch return -1;
        } else {
            // Simple checksum
            var sum: u8 = 0;
            for (data[0..block_size]) |b| sum +%= b;
            _ = posix.write(sio, &[_]u8{sum}) catch return -1;
        }

        // Wait for ACK/NAK
        var resp: u8 = 0;
        const n = misc.readPoll(sio, std.mem.asBytes(&resp), TIMEOUT_MS) catch return -1;
        if (n == 0) continue; // timeout, retry
        if (resp == ACK) return 0;
        if (resp == CAN) return -1;
        // NAK: retry
    }
    return -1;
}

test "crc16" {
    // Known CRC-16/CCITT value for "123456789" = 0x29B1
    const result = crc16("123456789");
    try std.testing.expectEqual(@as(u16, 0x29B1), result);
}
