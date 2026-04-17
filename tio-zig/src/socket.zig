// tio - a serial device I/O tool (Zig rewrite)
// socket.zig: redirect serial I/O to a UNIX / IPv4 / IPv6 socket

const std = @import("std");
const posix = std.posix;
const net = std.net;

const MAX_CLIENTS = 16;
const DEFAULT_PORT = 3333;

pub const SocketFamily = enum { unix, inet, inet6 };

const State = struct {
    sockfd: posix.fd_t = -1,
    clientfds: [MAX_CLIENTS]posix.fd_t = [_]posix.fd_t{-1} ** MAX_CLIENTS,
    family: ?SocketFamily = null,
    unix_path: [108]u8 = [_]u8{0} ** 108,
};

var state = State{};

/// Parse the socket string and start listening.
/// Format: "unix:/path/to/sock", "inet:4242", "inet6:4242"
pub fn socketConfigure(socket_str: []const u8) !void {
    if (std.mem.startsWith(u8, socket_str, "unix:")) {
        state.family = .unix;
        const path = socket_str[5..];
        if (path.len == 0) return error.MissingPath;
        if (path.len >= state.unix_path.len) return error.PathTooLong;
        @memcpy(state.unix_path[0..path.len], path);
        state.unix_path[path.len] = 0;
        try bindUnix(state.unix_path[0..path.len :0]);
    } else if (std.mem.startsWith(u8, socket_str, "inet:")) {
        state.family = .inet;
        const port = std.fmt.parseInt(u16, socket_str[5..], 10) catch DEFAULT_PORT;
        try bindInet(port);
    } else if (std.mem.startsWith(u8, socket_str, "inet6:")) {
        state.family = .inet6;
        const port = std.fmt.parseInt(u16, socket_str[6..], 10) catch DEFAULT_PORT;
        try bindInet6(port);
    } else {
        return error.InvalidScheme;
    }
}

fn bindUnix(path: [:0]const u8) !void {
    // Clean up stale socket file
    posix.unlink(path) catch {};

    state.sockfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    var addr = posix.sockaddr.un{ .path = [_]u8{0} ** 108 };
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);

    try posix.bind(state.sockfd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(state.sockfd, MAX_CLIENTS);
}

fn bindInet(port: u16) !void {
    state.sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const optval: c_int = 1;
    try posix.setsockopt(state.sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    const addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(state.sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(state.sockfd, MAX_CLIENTS);
}

fn bindInet6(port: u16) !void {
    state.sockfd = try posix.socket(posix.AF.INET6, posix.SOCK.STREAM, 0);
    const optval: c_int = 1;
    try posix.setsockopt(state.sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    const addr = net.Address.initIp6(std.mem.zeroes([16]u8), port, 0, 0);
    try posix.bind(state.sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(state.sockfd, MAX_CLIENTS);
}

/// Send `c` to all connected socket clients.
pub fn socketWrite(c: u8) void {
    for (&state.clientfds) |*cfd| {
        if (cfd.* == -1) continue;
        const n = posix.write(cfd.*, &[_]u8{c}) catch {
            posix.close(cfd.*);
            cfd.* = -1;
            continue;
        };
        if (n == 0) {
            posix.close(cfd.*);
            cfd.* = -1;
        }
    }
}

/// Returns the server socket fd, or -1 if socket is not active.
pub fn serverFd() posix.fd_t {
    return state.sockfd;
}

/// Returns a slice of active client fds.
pub fn clientFds() []posix.fd_t {
    return &state.clientfds;
}

/// Accept a new client on the server socket.
pub fn acceptClient() void {
    const cfd = posix.accept(state.sockfd, null, null, 0) catch return;
    for (&state.clientfds) |*slot| {
        if (slot.* == -1) {
            slot.* = cfd;
            return;
        }
    }
    // No room - reject
    posix.close(cfd);
}

/// Read one byte from any ready client socket.
/// Returns the byte on success, null otherwise.
pub fn socketHandleInput(fd: posix.fd_t) ?u8 {
    for (&state.clientfds) |*cfd| {
        if (cfd.* != fd) continue;
        var buf: [1]u8 = undefined;
        const n = posix.read(cfd.*, &buf) catch {
            posix.close(cfd.*);
            cfd.* = -1;
            return null;
        };
        if (n == 0) {
            posix.close(cfd.*);
            cfd.* = -1;
            return null;
        }
        return buf[0];
    }
    return null;
}

/// Clean up: close all sockets and remove the UNIX socket file.
pub fn socketExit() void {
    for (&state.clientfds) |*cfd| {
        if (cfd.* != -1) posix.close(cfd.*);
        cfd.* = -1;
    }
    if (state.sockfd != -1) {
        posix.close(state.sockfd);
        state.sockfd = -1;
    }
    if (state.family == .unix) {
        posix.unlink(std.mem.sliceTo(&state.unix_path, 0)) catch {};
    }
}
