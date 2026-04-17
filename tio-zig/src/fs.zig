// tio - a serial device I/O tool (Zig rewrite)
// fs.zig: filesystem helpers – device enumeration and sysfs reads

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const misc = @import("misc.zig");

pub const Device = struct {
    path: []const u8,
    tid: [5]u8, // 4 base-62 chars + null
    uptime: f64,
    driver: []const u8,
    description: []const u8,
};

/// Read the first line from `path` (stripping trailing whitespace/newlines)
/// into `buf`.  Returns the number of bytes written, or -1 on error.
pub fn readFileStripped(buf: []u8, path: []const u8) isize {
    const f = std.fs.openFileAbsolute(path, .{}) catch return -1;
    defer f.close();
    const n = f.reader().read(buf) catch return -1;
    if (n == 0) return -1;
    // Strip trailing whitespace / control chars
    var len = n;
    while (len > 0 and buf[len - 1] <= ' ') len -= 1;
    return @intCast(len);
}

/// Read the first line from a formatted path.
pub fn readFileFmt(buf: []u8, comptime fmt: []const u8, args: anytype) isize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, fmt, args) catch return -1;
    return readFileStripped(buf, path);
}

/// Returns the mtime of a path as seconds since the Unix epoch, or 0.0 on error.
pub fn getCreationTime(path: []const u8) f64 {
    const f = std.fs.openFileAbsolute(path, .{}) catch return 0.0;
    defer f.close();
    const st = f.stat() catch return 0.0;
    // mtime is i128 nanoseconds
    return @as(f64, @floatFromInt(st.mtime)) / @as(f64, std.time.ns_per_s);
}

/// Check whether `path` is a directory.
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Check whether `path` resolves to a serial (character) device.
/// A device is considered serial if it is a character device, responds to
/// isatty(), and does NOT have terminal rows/columns (i.e. it is not a pty).
pub fn isSerialDevice(path: [:0]const u8) bool {
    const fd = posix.openZ(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true }, 0) catch return false;
    defer posix.close(fd);

    // Must be a character device
    const st = posix.fstat(fd) catch return false;
    if (st.mode & std.os.linux.S.IFMT != std.os.linux.S.IFCHR) return false;

    // Must be a tty
    if (!posix.isatty(fd)) return false;

    // Serial devices have no rows/columns (unlike ptys)
    if (builtin.os.tag == .linux) {
        var ws: std.os.linux.winsize = std.mem.zeroes(std.os.linux.winsize);
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.ws_row != 0 and ws.ws_col != 0) return false;
    }

    return true;
}

/// Search `root_dir` for a subdirectory or file named `name`.
/// Returns an allocated string (caller owns) or null.
pub fn searchDirectory(root_dir: []const u8, name: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    var dir = std.fs.openDirAbsolute(root_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.basename, name)) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_dir, entry.path }) catch null;
        }
    }
    return null;
}

// ── Linux serial device enumeration ──────────────────────────────────────

pub fn searchSerialDevices(
    allocator: std.mem.Allocator,
    exclude_devices: ?[]const u8,
    exclude_drivers: ?[]const u8,
    exclude_tids: ?[]const u8,
) !std.ArrayList(Device) {
    var list = std.ArrayList(Device).init(allocator);

    if (builtin.os.tag != .linux) {
        // Fallback: scan /dev for serial devices
        try scanDevDir(allocator, &list, exclude_devices);
        return list;
    }

    const current_time = misc.getCurrentTime();

    var sysfs = std.fs.openDirAbsolute("/sys/class/tty", .{ .iterate = true }) catch return list;
    defer sysfs.close();

    var iter = sysfs.iterate();
    while (try iter.next()) |entry| {
        const dev_name = entry.name;

        // Build /dev/<name> path
        var dev_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dev_path = std.fmt.bufPrintZ(&dev_path_buf, "/dev/{s}", .{dev_name}) catch continue;
        if (!isSerialDevice(dev_path)) continue;

        // Read device symlink /sys/class/tty/<name>/device
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var link_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_path = std.fmt.bufPrint(&link_path_buf, "/sys/class/tty/{s}/device", .{dev_name}) catch continue;
        const link_len = posix.readlink(link_path, &link_buf) catch continue;
        const link_str = link_buf[0..link_len];

        // Extract last component
        const last_slash = std.mem.lastIndexOfScalar(u8, link_str, '/') orelse 0;
        const last_part = if (last_slash + 1 < link_str.len) link_str[last_slash + 1 ..] else link_str;

        // Find device in /sys/devices
        var devices_path = searchDirectory("/sys/devices", last_part, allocator) orelse continue;
        defer allocator.free(devices_path);

        // Remove trailing device name if it matches dev_name
        {
            const lslash = std.mem.lastIndexOfScalar(u8, devices_path, '/') orelse 0;
            if (std.mem.eql(u8, devices_path[lslash + 1 ..], dev_name)) {
                devices_path = devices_path[0..lslash];
            }
        }

        // Topology ID from hash
        const hash = misc.djb2Hash(devices_path);
        var tid_buf: [5]u8 = undefined;
        misc.base62Encode(hash, &tid_buf);

        // Read driver symlink
        var drv_buf: [std.fs.max_path_bytes]u8 = undefined;
        var drv_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const drv_path = std.fmt.bufPrint(&drv_path_buf, "/sys/class/tty/{s}/device/driver", .{dev_name}) catch continue;
        const drv_len = posix.readlink(drv_path, &drv_buf) catch {
            // Not fatal; just leave driver empty
            var drv_empty: [1]u8 = .{0};
            drv_buf[0] = 0;
            _ = drv_empty;
            continue;
        };
        const drv_str = drv_buf[0..drv_len];
        const drv_last = std.mem.lastIndexOfScalar(u8, drv_str, '/') orelse 0;
        const driver = drv_str[drv_last + 1 ..];

        // Uptime
        const creation_time = getCreationTime(dev_path[0 .. dev_path.len - 1 :0]);
        const uptime = current_time - creation_time;

        // Read description from sysfs
        var desc_buf: [64]u8 = [_]u8{0} ** 64;
        const desc_paths = [_][]const u8{
            "/sys/class/tty/{s}/device/../product",
            "/sys/class/tty/{s}/device/../../product",
            "/sys/class/tty/{s}/device/interface",
            "/sys/class/tty/{s}/device/../interface",
        };
        for (desc_paths) |dp| {
            var p: [std.fs.max_path_bytes]u8 = undefined;
            const pp = std.fmt.bufPrint(&p, dp, .{dev_name}) catch continue;
            if (readFileStripped(&desc_buf, pp) >= 0) break;
        }

        // Apply exclusion filters
        const dev_path_slice: []const u8 = dev_path[0..std.mem.indexOfScalar(u8, &dev_path_buf, 0) orelse dev_path.len];
        if (exclude_devices) |pat| if (misc.matchPatterns(dev_path_slice, pat)) continue;
        if (exclude_drivers) |pat| if (misc.matchPatterns(driver, pat)) continue;
        if (exclude_tids) |pat| if (misc.matchPatterns(&tid_buf, pat)) continue;

        try list.append(.{
            .path = try allocator.dupe(u8, dev_path_slice),
            .tid = tid_buf,
            .uptime = uptime,
            .driver = try allocator.dupe(u8, driver),
            .description = try allocator.dupe(u8, std.mem.sliceTo(&desc_buf, 0)),
        });
    }

    // Sort by uptime (largest first → newest device last)
    std.sort.insertion(Device, list.items, {}, struct {
        fn lessThan(_: void, a: Device, b: Device) bool {
            return a.uptime > b.uptime;
        }
    }.lessThan);

    return list;
}

fn scanDevDir(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Device),
    exclude_devices: ?[]const u8,
) !void {
    var dev_dir = std.fs.openDirAbsolute("/dev", .{ .iterate = true }) catch return;
    defer dev_dir.close();
    var iter = dev_dir.iterate();
    while (try iter.next()) |entry| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/{s}", .{entry.name}) catch continue;
        if (!isSerialDevice(path)) continue;
        const path_slice: []const u8 = path[0..std.mem.indexOfScalar(u8, &path_buf, 0) orelse path.len];
        if (exclude_devices) |pat| if (misc.matchPatterns(path_slice, pat)) continue;
        const ct = getCreationTime(path);
        const uptime = misc.getCurrentTime() - ct;
        try list.append(.{
            .path = try allocator.dupe(u8, path_slice),
            .tid = [_]u8{ 0, 0, 0, 0, 0 },
            .uptime = uptime,
            .driver = try allocator.dupe(u8, ""),
            .description = try allocator.dupe(u8, ""),
        });
    }
}

pub fn freeDeviceList(list: *std.ArrayList(Device), allocator: std.mem.Allocator) void {
    for (list.items) |dev| {
        allocator.free(dev.path);
        allocator.free(dev.driver);
        allocator.free(dev.description);
    }
    list.deinit();
}
