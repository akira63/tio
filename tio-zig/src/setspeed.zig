// tio - a serial device I/O tool (Zig rewrite)
// setspeed.zig: non-standard baud rate support

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

// Linux TCGETS2/TCSETS2 ioctl numbers (from asm-generic/ioctls.h)
const TCGETS2: u32 = 0x802C542A;
const TCSETS2: u32 = 0x402C542B;
const BOTHER: u32 = 0x1000;

// Linux termios2 struct
const Termios2 = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [19]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

// macOS IOSSIOSPEED ioctl number
const IOSSIOSPEED: u32 = 0x80045402;

/// Set an arbitrary baud rate on `fd`.  This is called only when the
/// requested baud rate is not a standard POSIX speed constant.
pub fn setSpeed(fd: posix.fd_t, baudrate: u32) !void {
    if (builtin.os.tag == .linux) {
        return setSpeedLinux(fd, baudrate);
    } else if (builtin.os.tag == .macos) {
        return setSpeedMacos(fd, baudrate);
    } else {
        return error.Unsupported;
    }
}

fn setSpeedLinux(fd: posix.fd_t, baudrate: u32) !void {
    var t2: Termios2 = undefined;
    const rc_get = std.os.linux.ioctl(fd, TCGETS2, @intFromPtr(&t2));
    if (rc_get != 0) return error.IoctlFailed;

    t2.c_cflag &= ~@as(u32, 0xF); // Clear CBAUD
    t2.c_cflag |= BOTHER;
    t2.c_ispeed = baudrate;
    t2.c_ospeed = baudrate;

    const rc_set = std.os.linux.ioctl(fd, TCSETS2, @intFromPtr(&t2));
    if (rc_set != 0) return error.IoctlFailed;
}

fn setSpeedMacos(fd: posix.fd_t, baudrate: u32) !void {
    // Use @cImport for the macOS ioctl since std.os.darwin is not available
    const speed: c_long = @intCast(baudrate);
    const rc = c.ioctl(fd, @as(c_ulong, IOSSIOSPEED), &speed);
    if (rc != 0) return error.IoctlFailed;
}

/// Check whether `baudrate` is a standard POSIX baud rate constant.
pub fn isStandardBaudrate(baudrate: u32) bool {
    const standard = [_]u32{
        0,    50,    75,    110,    134,    150,    200,   300,
        600,  1200,  1800,  2400,   4800,   9600,   19200, 38400,
        57600, 115200, 230400, 460800, 500000, 576000, 921600,
        1000000, 1152000, 1500000, 2000000,
    };
    for (standard) |s| {
        if (s == baudrate) return true;
    }
    return false;
}
