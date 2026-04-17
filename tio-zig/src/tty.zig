// tio - a serial device I/O tool (Zig rewrite)
// tty.zig: core serial device connect / I/O event loop
//
// Architecture
// ────────────
//  main thread        – select() loop on: device_fd, pipe_read, socket_fds
//  stdin reader thread – reads stdin, writes to pipe_write
//
// The pipe decouples stdin (which blocks) from the event loop so we can
// use a single select() call for all three fd sources.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const options   = @import("options.zig");
const print     = @import("print.zig");
const log       = @import("log.zig");
const timestamp = @import("timestamp.zig");
const alert_mod = @import("alert.zig");
const rs485_mod = @import("rs485.zig");
const setspeed  = @import("setspeed.zig");
const socket    = @import("socket.zig");
const readline  = @import("readline.zig");
const xymodem   = @import("xymodem.zig");
const misc      = @import("misc.zig");
const signals   = @import("signals.zig");
const fs_mod    = @import("fs.zig");
const configfile= @import("configfile.zig");

// ── ioctl request numbers (Linux) ────────────────────────────────────────

const TIOCMGET: u32 = 0x5415;
const TIOCMSET: u32 = 0x5418;
const TIOCSBRK: u32 = 0x5427;
const TIOCCBRK: u32 = 0x5428;
const TCIOFLUSH: c_int = 2;

const TIOCM_DTR: c_int = 0x002;
const TIOCM_RTS: c_int = 0x004;
const TIOCM_CTS: c_int = 0x020;
const TIOCM_DSR: c_int = 0x100;
const TIOCM_CD:  c_int = 0x040;
const TIOCM_RI:  c_int = 0x080;

// ── Key codes used in the interactive command handler ─────────────────────

const KEY_0         = '0';
const KEY_1         = '1';
const KEY_2         = '2';
const KEY_3         = '3';
const KEY_4         = '4';
const KEY_5         = '5';
const KEY_9         = '9';
const KEY_A: u8     = 'a';
const KEY_B: u8     = 'b';
const KEY_C: u8     = 'c';
const KEY_E: u8     = 'e';
const KEY_F: u8     = 'f';
const KEY_SHIFT_F: u8 = 'F';
const KEY_G: u8     = 'g';
const KEY_I: u8     = 'i';
const KEY_L: u8     = 'l';
const KEY_SHIFT_L: u8 = 'L';
const KEY_M: u8     = 'm';
const KEY_O: u8     = 'o';
const KEY_P: u8     = 'p';
const KEY_Q: u8     = 'q';
const KEY_R: u8     = 'r';
const KEY_SHIFT_R: u8 = 'R';
const KEY_S: u8     = 's';
const KEY_T: u8     = 't';
const KEY_V: u8     = 'v';
const KEY_X: u8     = 'x';
const KEY_Y: u8     = 'y';
const KEY_Z: u8     = 'z';
const KEY_QUESTION  = '?';

const TOPOLOGY_ID_SIZE = 4;

/// ASCII art shown for ctrl-t z
const RANDOM_ARRAY =
    "        ( (\n" ++
    "         ) )\n" ++
    "      ........\n" ++
    "      |      |]\n" ++
    "      \\      /\n" ++
    "       `----'\n\n" ++
    "Time for a coffee break!\n \n";

// ── Module-level mutable state ────────────────────────────────────────────

var device_fd: posix.fd_t = -1;
var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
var stdin_old: posix.termios = undefined;
var stdout_old: posix.termios = undefined;
var tio_old: posix.termios = undefined;
var tio_new: posix.termios = undefined;
var stdin_configured: bool = false;
var stdout_configured: bool = false;
var rx_total: u64 = 0;
var tx_total: u64 = 0;
var connected: bool = false;
var standard_baudrate: bool = true;
var interactive_mode: bool = true;
var device_name: []const u8 = "";

/// Global reference to the parsed options, set once in main.
var g_opts: *const options.Options = undefined;

/// cfmakeraw implementation (not always available in Zig std).
fn cfmakeraw(tios: *posix.termios) void {
    tios.iflag &= ~@as(posix.tcflag_t,
        posix.IGNBRK | posix.BRKINT | posix.PARMRK | posix.ISTRIP |
        posix.INLCR  | posix.IGNCR  | posix.ICRNL  | posix.IXON);
    tios.oflag &= ~@as(posix.tcflag_t, posix.OPOST);
    tios.lflag &= ~@as(posix.tcflag_t,
        posix.ECHO | posix.ECHONL | posix.ICANON | posix.ISIG | posix.IEXTEN);
    tios.cflag &= ~@as(posix.tcflag_t, posix.CSIZE | posix.PARENB);
    tios.cflag |= posix.CS8;
    tios.cc[@intFromEnum(posix.V.TIME)] = 0;
    tios.cc[@intFromEnum(posix.V.MIN)]  = 1;
}

// ── Stdout / stdin configuration ──────────────────────────────────────────

pub fn stdoutConfigure(opts: *const options.Options) !void {
    stdout_old = try posix.tcgetattr(posix.STDOUT_FILENO);
    var new = stdout_old;
    cfmakeraw(&new);
    if (!interactive_mode) {
        new.lflag |= posix.ISIG; // Allow Ctrl-C when piping
    }
    new.cc[@intFromEnum(posix.V.TIME)] = 0;
    new.cc[@intFromEnum(posix.V.MIN)]  = 1;
    try posix.tcsetattr(posix.STDOUT_FILENO, .NOW, &new);
    stdout_configured = true;
    if (opts.vt100) {
        // Enable VT100 graphics mode awareness – we'll restore on exit
    }
}

pub fn stdoutRestore(opts: *const options.Options) void {
    if (!stdout_configured) return;
    posix.tcsetattr(posix.STDOUT_FILENO, .NOW, &stdout_old) catch {};
    if (opts.vt100) {
        // Disable DEC Special Graphics character set (noise protection)
        _ = posix.write(posix.STDOUT_FILENO, "\x0F") catch {};
    }
}

pub fn stdinConfigure() !void {
    stdin_old = try posix.tcgetattr(posix.STDIN_FILENO);
    var new = stdin_old;
    cfmakeraw(&new);
    new.cc[@intFromEnum(posix.V.TIME)] = 0;
    new.cc[@intFromEnum(posix.V.MIN)]  = 1;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, &new);
    stdin_configured = true;
}

pub fn stdinRestore() void {
    if (!stdin_configured) return;
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, &stdin_old) catch {};
}

// ── TTY port configuration ─────────────────────────────────────────────────

pub fn ttyConfigure(opts: *const options.Options) !void {
    tio_new = std.mem.zeroes(posix.termios);

    // Baud rate
    standard_baudrate = setspeed.isStandardBaudrate(opts.baudrate);
    if (standard_baudrate) {
        const speed = baudrateToSpeed(opts.baudrate) orelse return error.InvalidBaudrate;
        try posix.cfsetispeed(&tio_new, speed);
        try posix.cfsetospeed(&tio_new, speed);
    }

    // Data bits
    tio_new.cflag &= ~@as(posix.tcflag_t, posix.CSIZE);
    tio_new.cflag |= switch (opts.databits) {
        5 => posix.CS5,
        6 => posix.CS6,
        7 => posix.CS7,
        8 => posix.CS8,
        else => return error.InvalidDatabits,
    };

    // Flow control
    switch (opts.flow) {
        .none => {
            tio_new.cflag &= ~@as(posix.tcflag_t, posix.CRTSCTS);
            tio_new.iflag &= ~@as(posix.tcflag_t, posix.IXON | posix.IXOFF | posix.IXANY);
        },
        .hard => {
            tio_new.cflag |= posix.CRTSCTS;
            tio_new.iflag &= ~@as(posix.tcflag_t, posix.IXON | posix.IXOFF | posix.IXANY);
        },
        .soft => {
            tio_new.cflag &= ~@as(posix.tcflag_t, posix.CRTSCTS);
            tio_new.iflag |= posix.IXON | posix.IXOFF;
        },
    }

    // Stop bits
    switch (opts.stopbits) {
        1 => tio_new.cflag &= ~@as(posix.tcflag_t, posix.CSTOPB),
        2 => tio_new.cflag |= posix.CSTOPB,
        else => return error.InvalidStopbits,
    }

    // Parity
    switch (opts.parity) {
        .none => tio_new.cflag &= ~@as(posix.tcflag_t, posix.PARENB),
        .odd  => {
            tio_new.cflag |= posix.PARENB | posix.PARODD;
        },
        .even => {
            tio_new.cflag |= posix.PARENB;
            tio_new.cflag &= ~@as(posix.tcflag_t, posix.PARODD);
        },
        .mark => {
            tio_new.cflag |= posix.PARENB | posix.PARODD;
            // CMSPAR is Linux-only
            if (builtin.os.tag == .linux) tio_new.cflag |= 0x40000000;
        },
        .space => {
            tio_new.cflag |= posix.PARENB;
            tio_new.cflag &= ~@as(posix.tcflag_t, posix.PARODD);
            if (builtin.os.tag == .linux) tio_new.cflag |= 0x40000000;
        },
    }

    tio_new.cflag |= posix.CLOCAL | posix.CREAD;
    tio_new.oflag = 0;
    tio_new.lflag = 0;
    tio_new.cc[@intFromEnum(posix.V.TIME)] = 0;
    tio_new.cc[@intFromEnum(posix.V.MIN)]  = 1;

    // Input mappings (termios level)
    if (opts.map_i_nl_cr) tio_new.iflag |= posix.INLCR;
    if (opts.map_ign_cr)  tio_new.iflag |= posix.IGNCR;
    if (opts.map_i_cr_nl) tio_new.iflag |= posix.ICRNL;
}

pub fn ttyReconfigure(opts: *const options.Options) void {
    ttyConfigure(opts) catch {};
    if (connected) {
        posix.tcsetattr(device_fd, .NOW, &tio_new) catch {};
    }
}

// ── Line state helpers ─────────────────────────────────────────────────────

fn lineStateName(mask: c_int) []const u8 {
    return switch (mask) {
        TIOCM_DTR => "DTR",
        TIOCM_RTS => "RTS",
        TIOCM_CTS => "CTS",
        TIOCM_DSR => "DSR",
        TIOCM_CD  => "DCD",
        TIOCM_RI  => "RI",
        else      => "?",
    };
}

fn ttyGetLineState() !c_int {
    var state: c_int = 0;
    const rc = std.os.linux.ioctl(device_fd, TIOCMGET, @intFromPtr(&state));
    if (rc != 0) return error.IoctlFailed;
    return state;
}

fn ttySetLineState(state: c_int) !void {
    var s = state;
    const rc = std.os.linux.ioctl(device_fd, TIOCMSET, @intFromPtr(&s));
    if (rc != 0) return error.IoctlFailed;
}

pub fn ttyLineToggle(mask: c_int, opts: *const options.Options) void {
    var state = ttyGetLineState() catch {
        tioPrint(opts, "Warning: Could not get line state");
        return;
    };
    if (state & mask != 0) {
        state &= ~mask;
        tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, "Setting {s} to HIGH", .{lineStateName(mask)}) catch "Setting line to HIGH");
    } else {
        state |= mask;
        tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, "Setting {s} to LOW", .{lineStateName(mask)}) catch "Setting line to LOW");
    }
    ttySetLineState(state) catch {
        tioPrint(opts, "Warning: Could not set line state");
    };
}

pub fn ttyLinePulse(mask: c_int, duration_ms: u32, opts: *const options.Options) void {
    ttyLineToggle(mask, opts);
    if (duration_ms > 0) {
        tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, "Waiting {d} ms", .{duration_ms}) catch "Waiting...");
        misc.delay(duration_ms);
    }
    ttyLineToggle(mask, opts);
}

// ── Output buffering ───────────────────────────────────────────────────────

var tty_buf: [8192]u8 = undefined;
var tty_buf_len: usize = 0;

fn ttySyncBuffer() void {
    if (tty_buf_len == 0) return;
    var written: usize = 0;
    while (written < tty_buf_len) {
        const n = posix.write(device_fd, tty_buf[written..tty_buf_len]) catch break;
        written += n;
    }
    tty_buf_len = 0;
}

fn ttyWrite(data: []const u8) void {
    const opts = g_opts;
    if (opts.output_delay > 0 or opts.output_line_delay > 0) {
        for (data) |b| {
            _ = posix.write(device_fd, &[_]u8{b}) catch {};
            if (opts.output_line_delay > 0 and b == '\n') misc.delay(opts.output_line_delay);
            if (opts.output_delay > 0) misc.delay(opts.output_delay);
        }
        return;
    }
    if (tty_buf_len + data.len > tty_buf.len) ttySyncBuffer();
    @memcpy(tty_buf[tty_buf_len .. tty_buf_len + data.len], data);
    tty_buf_len += data.len;
}

// ── Tiny helpers ───────────────────────────────────────────────────────────

fn tioPrint(opts: *const options.Options, msg: []const u8) void {
    if (opts.mute) return;
    if (print.print_tainted) {
        _ = posix.write(posix.STDOUT_FILENO, "\n") catch {};
        print.print_tainted = false;
    }
    const ts = timestamp.currentTime(opts.timestamp) orelse "";
    const out = std.io.getStdOut().writer();
    if (opts.color >= 0) out.writeAll(print.ansi_format[0..print.ansi_format_len]) catch {};
    out.print("\r[{s}] {s}\x1b[0m\r\n", .{ ts, msg }) catch {};
}

fn isValidHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn charToNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else      => 0,
    };
}

// ── Print character to stdout (respects output mode) ─────────────────────

var hex_chars: [2]u8 = undefined;
var hex_char_index: u8 = 0;
var printchar_mode: options.OutputMode = .normal;

fn setOutputMode(mode: options.OutputMode) void {
    printchar_mode = mode;
}

fn printChar(c: u8, opts: *const options.Options) void {
    switch (printchar_mode) {
        .normal => print.printNormal(c),
        .hex    => print.printHex(c),
    }
    if (opts.log) log.logPutc(c, switch (printchar_mode) {
        .normal => .normal,
        .hex    => .hex,
    }, opts.log_strip);
    socket.socketWrite(c);
}

fn handleHexPrompt(c: u8, opts: *const options.Options) void {
    hex_chars[hex_char_index] = c;
    hex_char_index += 1;
    _ = posix.write(posix.STDOUT_FILENO, &[_]u8{c}) catch {};
    print.printTaintedSet();

    if (hex_char_index == 2) {
        misc.delay(100);
        if (!opts.local_echo) {
            _ = posix.write(posix.STDOUT_FILENO, "\x08 \x08\x08 \x08") catch {};
        } else {
            _ = posix.write(posix.STDOUT_FILENO, " ") catch {};
        }
        const val: u8 = (charToNibble(hex_chars[0]) << 4) | (charToNibble(hex_chars[1]) & 0x0F);
        hex_char_index = 0;
        ttyWrite(&[_]u8{val});
        tx_total += 1;
    }
}

// ── Mapping helpers ────────────────────────────────────────────────────────

fn printMappings(opts: *const options.Options) void {
    const has = opts.map_i_cr_nl or opts.map_ign_cr or opts.map_i_ff_escc or
                opts.map_i_nl_cr or opts.map_i_nl_crnl or opts.map_i_cr_crnl or
                opts.map_o_cr_nl or opts.map_o_del_bs or opts.map_o_nl_crnl or
                opts.map_o_ltu or opts.map_o_nulbrk or opts.map_i_msb2lsb or opts.map_o_ign_cr;

    if (!has) {
        tioPrint(opts, " Mappings: none");
        return;
    }
    const out = std.io.getStdOut().writer();
    out.writeAll(" Mappings:") catch {};
    if (opts.map_i_cr_nl)   out.writeAll(" ICRNL")    catch {};
    if (opts.map_ign_cr)    out.writeAll(" IGNCR")    catch {};
    if (opts.map_i_ff_escc) out.writeAll(" IFFESCC")  catch {};
    if (opts.map_i_nl_cr)   out.writeAll(" INLCR")    catch {};
    if (opts.map_i_nl_crnl) out.writeAll(" INLCRNL")  catch {};
    if (opts.map_i_cr_crnl) out.writeAll(" ICRCRNL")  catch {};
    if (opts.map_i_msb2lsb) out.writeAll(" IMSB2LSB") catch {};
    if (opts.map_o_cr_nl)   out.writeAll(" OCRNL")    catch {};
    if (opts.map_o_del_bs)  out.writeAll(" ODELBS")   catch {};
    if (opts.map_o_nl_crnl) out.writeAll(" ONLCRNL")  catch {};
    if (opts.map_o_ltu)     out.writeAll(" OLTU")     catch {};
    if (opts.map_o_nulbrk)  out.writeAll(" ONULBRK")  catch {};
    if (opts.map_o_ign_cr)  out.writeAll(" OIGNCR")   catch {};
    out.writeAll("\r\n") catch {};
}

// ── Interactive command handler ────────────────────────────────────────────

const SubCommand = enum { none, line_toggle, line_pulse, xmodem, map };

var sub_command: SubCommand = .none;
var line_mode_for_subcmd: enum { toggle, pulse } = .toggle;
var cmd_previous_char: u8 = 0;

/// Read a line from the pipe (blocking, for prompts during commands).
fn tioReadLine(buf: []u8) usize {
    var pos: usize = 0;
    while (pos < buf.len - 1) {
        var c: u8 = 0;
        const n = posix.read(pipe_fds[0], std.mem.asBytes(&c)) catch break;
        if (n == 0) break;
        if (c == 0x08 or c == 0x7f) {
            if (pos > 0) {
                pos -= 1;
                _ = posix.write(posix.STDOUT_FILENO, "\x08 \x08") catch {};
            }
            continue;
        }
        _ = posix.write(posix.STDOUT_FILENO, &[_]u8{c}) catch {};
        if (c == '\r') break;
        buf[pos] = c;
        pos += 1;
    }
    buf[pos] = 0;
    return pos;
}

/// Process one byte from the user's keyboard (interactive mode).
/// `output_char` is set to the forwarded character; `forward` indicates
/// whether it should be sent to the device.
pub fn handleCommandSequence(
    input_char: u8,
    output_char: *u8,
    forward: *bool,
    opts: *options.Options,
    cfg: *configfile.Config,
) void {
    // Default: forward the character
    output_char.* = input_char;
    forward.* = true;

    // ── Sub-command in progress ──────────────────────────────────────────
    if (sub_command != .none) {
        forward.* = false;

        switch (sub_command) {
            .none => {},
            .line_toggle, .line_pulse => {
                const is_pulse = sub_command == .line_pulse;
                const mask: c_int = switch (input_char) {
                    KEY_0 => TIOCM_DTR,
                    KEY_1 => TIOCM_RTS,
                    KEY_2 => TIOCM_CTS,
                    KEY_3 => TIOCM_DSR,
                    KEY_4 => TIOCM_CD,
                    KEY_5 => TIOCM_RI,
                    else  => { tioPrint(opts, "Invalid line number"); sub_command = .none; return; },
                };
                const dur: u32 = switch (mask) {
                    TIOCM_DTR => opts.dtr_pulse_duration,
                    TIOCM_RTS => opts.rts_pulse_duration,
                    TIOCM_CTS => opts.cts_pulse_duration,
                    TIOCM_DSR => opts.dsr_pulse_duration,
                    TIOCM_CD  => opts.dcd_pulse_duration,
                    TIOCM_RI  => opts.ri_pulse_duration,
                    else      => 0,
                };
                if (is_pulse) ttyLinePulse(mask, dur, opts) else ttyLineToggle(mask, opts);
            },
            .xmodem => {
                var file_buf: [4096]u8 = undefined;
                switch (input_char) {
                    KEY_0 => {
                        tioPrint(opts, "Send file with XMODEM-1K");
                        _ = posix.write(posix.STDOUT_FILENO, "\rEnter file name: ") catch {};
                        const n = tioReadLine(&file_buf);
                        if (n > 0) {
                            tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, "Sending '{s}'", .{file_buf[0..n]}) catch "Sending...");
                            _ = xymodem.xymodemSend(device_fd, file_buf[0..n], .xmodem_1k) catch {};
                        }
                    },
                    KEY_1 => {
                        tioPrint(opts, "Send file with XMODEM-CRC");
                        _ = posix.write(posix.STDOUT_FILENO, "\rEnter file name: ") catch {};
                        const n = tioReadLine(&file_buf);
                        if (n > 0) {
                            _ = xymodem.xymodemSend(device_fd, file_buf[0..n], .xmodem_crc) catch {};
                        }
                    },
                    KEY_2 => {
                        tioPrint(opts, "Send file with YMODEM");
                        _ = posix.write(posix.STDOUT_FILENO, "\rEnter file name: ") catch {};
                        const n = tioReadLine(&file_buf);
                        if (n > 0) {
                            _ = xymodem.xymodemSend(device_fd, file_buf[0..n], .ymodem) catch {};
                        }
                    },
                    else => tioPrint(opts, "Invalid protocol option"),
                }
            },
            .map => handleMapSubCommand(input_char, opts),
        }

        sub_command = .none;
        cmd_previous_char = 0;
        return;
    }

    // ── Main command handler (after prefix key) ───────────────────────────
    if (opts.prefix_enabled and cmd_previous_char == opts.prefix_code) {
        forward.* = false;

        // Double prefix → forward the prefix character
        if (input_char == opts.prefix_code) {
            output_char.* = opts.prefix_code;
            forward.* = true;
            cmd_previous_char = 0;
            return;
        }

        switch (input_char) {
            KEY_QUESTION => {
                tioPrint(opts, "Key commands:");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} ?       List available key commands", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} b       Send break", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} c       Show configuration", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} e       Toggle local echo", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} f       Toggle log to file", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} F       Flush data I/O buffers", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} g       Toggle serial port line", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} i       Toggle input mode", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} l       Clear screen", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} L       Show line states", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} m       Change character mappings", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} o       Toggle output mode", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} p       Pulse serial port line", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} q       Quit", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} R       Execute shell command with I/O to device", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} s       Show statistics", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} t       Toggle timestamp mode", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} v       Show version", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} x       Send file via XMODEM", .{opts.prefix_key}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                    " ctrl-{c} y       Send file via YMODEM", .{opts.prefix_key}) catch "");
            },

            KEY_B => {
                // Send break
                _ = std.os.linux.ioctl(device_fd, TIOCSBRK, 0);
                misc.delay(250);
                _ = std.os.linux.ioctl(device_fd, TIOCCBRK, 0);
            },

            KEY_C => {
                tioPrint(opts, "Configuration:");
                configfile.printConfig(cfg);
                options.printOptions(opts);
                if (opts.rs485) rs485_mod.printRs485Config(opts.rs485_cfg);
                printMappings(opts);
            },

            KEY_E => {
                opts.local_echo = !opts.local_echo;
                tioPrint(opts, if (opts.local_echo) "Switched local echo on" else "Switched local echo off");
            },

            KEY_F => {
                if (log.logIsOpen()) {
                    log.logClose(opts.mute);
                    opts.log = false;
                } else {
                    log.logOpen(opts.log_filename, opts.log_append, opts.target,
                        @tagName(opts.auto_connect), opts.log_directory, std.heap.page_allocator) catch {};
                    opts.log = log.logIsOpen();
                }
                tioPrint(opts, if (opts.log) "Switched log to file on" else "Switched log to file off");
            },

            KEY_SHIFT_F => {
                // Flush I/O
                tioPrint(opts, "Flushed data I/O buffers");
                _ = std.c.tcflush(device_fd, TCIOFLUSH);
            },

            KEY_G => {
                tioPrint(opts, "Please enter which serial line number to toggle:");
                tioPrint(opts, "(0) DTR  (1) RTS  (2) CTS  (3) DSR  (4) DCD  (5) RI");
                line_mode_for_subcmd = .toggle;
                sub_command = .line_toggle;
            },

            KEY_I => {
                opts.input_mode = @enumFromInt((@intFromEnum(opts.input_mode) + 1) % 3);
                tioPrint(opts, switch (opts.input_mode) {
                    .normal => "Switched input mode to normal",
                    .hex    => "Switched input mode to hex",
                    .line   => "Switched input mode to line",
                });
            },

            KEY_L => {
                // Clear screen
                _ = posix.write(posix.STDOUT_FILENO, "\x1bc") catch {};
            },

            KEY_SHIFT_L => {
                const ls = ttyGetLineState() catch { tioPrint(opts, "Could not get line state"); return; };
                tioPrint(opts, "Line states:");
                const out = std.io.getStdOut().writer();
                out.print(" DTR: {s}\r\n", .{if (ls & TIOCM_DTR != 0) "LOW" else "HIGH"}) catch {};
                out.print(" RTS: {s}\r\n", .{if (ls & TIOCM_RTS != 0) "LOW" else "HIGH"}) catch {};
                out.print(" CTS: {s}\r\n", .{if (ls & TIOCM_CTS != 0) "LOW" else "HIGH"}) catch {};
                out.print(" DSR: {s}\r\n", .{if (ls & TIOCM_DSR != 0) "LOW" else "HIGH"}) catch {};
                out.print(" DCD: {s}\r\n", .{if (ls & TIOCM_CD  != 0) "LOW" else "HIGH"}) catch {};
                out.print(" RI : {s}\r\n", .{if (ls & TIOCM_RI  != 0) "LOW" else "HIGH"}) catch {};
            },

            KEY_M => {
                tioPrint(opts, "Please enter which mapping to set or unset:");
                const o = std.io.getStdOut().writer();
                o.print(" (0) ICRNL   (1) IGNCR   (2) IFFESCC (3) INLCR\r\n", .{}) catch {};
                o.print(" (4) INLCRNL (5) ICRCRNL (6) IMSB2LSB\r\n", .{}) catch {};
                o.print(" (7) OCRNL   (8) ODELBS  (9) ONLCRNL\r\n", .{}) catch {};
                o.print(" (a) OLTU    (b) ONULBRK (c) OIGNCR\r\n", .{}) catch {};
                sub_command = .map;
            },

            KEY_O => {
                opts.output_mode = if (opts.output_mode == .normal) .hex else .normal;
                setOutputMode(opts.output_mode);
                tioPrint(opts, if (opts.output_mode == .hex) "Switched output mode to hex" else "Switched output mode to normal");
            },

            KEY_P => {
                tioPrint(opts, "Please enter which serial line number to pulse:");
                tioPrint(opts, "(0) DTR  (1) RTS  (2) CTS  (3) DSR  (4) DCD  (5) RI");
                line_mode_for_subcmd = .pulse;
                sub_command = .line_pulse;
            },

            KEY_Q => std.process.exit(0),

            KEY_SHIFT_R => {
                tioPrint(opts, "Execute shell command with I/O redirected to device");
                _ = posix.write(posix.STDOUT_FILENO, "\rEnter command: ") catch {};
                var cmd_buf: [4096]u8 = undefined;
                const n = tioReadLine(&cmd_buf);
                if (n > 0) {
                    _ = misc.executeShellCommand(device_fd, cmd_buf[0..n], std.heap.page_allocator) catch {};
                }
            },

            KEY_S => {
                tioPrint(opts, "Statistics:");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, " Sent {d} bytes", .{tx_total}) catch "");
                tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator, " Received {d} bytes", .{rx_total}) catch "");
            },

            KEY_T => {
                const next: u8 = (@intFromEnum(opts.timestamp) + 1) % @intFromEnum(timestamp.Timestamp.epoch_usec) + 1;
                if (next > @intFromEnum(timestamp.Timestamp.epoch_usec)) {
                    opts.timestamp = .none;
                    tioPrint(opts, "Switched timestamp mode off");
                } else {
                    opts.timestamp = @enumFromInt(next);
                    tioPrint(opts, std.fmt.allocPrint(std.heap.page_allocator,
                        "Switched timestamp mode to {s}", .{@tagName(opts.timestamp)}) catch "");
                }
            },

            KEY_V => tioPrint(opts, "tio 3.9.0 (Zig rewrite)"),

            KEY_X => {
                tioPrint(opts, "Please enter which XMODEM protocol to use:");
                tioPrint(opts, " (0) XMODEM-1K send");
                tioPrint(opts, " (1) XMODEM-CRC send");
                tioPrint(opts, " (2) XMODEM-CRC receive");
                sub_command = .xmodem;
            },

            KEY_Y => {
                tioPrint(opts, "Send file with YMODEM");
                _ = posix.write(posix.STDOUT_FILENO, "\rEnter file name: ") catch {};
                var fbuf: [4096]u8 = undefined;
                const n = tioReadLine(&fbuf);
                if (n > 0) {
                    _ = xymodem.xymodemSend(device_fd, fbuf[0..n], .ymodem) catch {};
                }
            },

            KEY_Z => print.printArray(RANDOM_ARRAY),

            else => {}, // Ignore unknown escaped keys
        }

        cmd_previous_char = 0;
        return;
    }

    cmd_previous_char = input_char;
}

fn handleMapSubCommand(c: u8, opts: *options.Options) void {
    switch (c) {
        '0' => { opts.map_i_cr_nl   = !opts.map_i_cr_nl;   ttyReconfigure(opts); tioPrint(opts, if (opts.map_i_cr_nl)   "ICRNL set"   else "ICRNL unset"); },
        '1' => { opts.map_ign_cr    = !opts.map_ign_cr;     ttyReconfigure(opts); tioPrint(opts, if (opts.map_ign_cr)    "IGNCR set"   else "IGNCR unset"); },
        '2' => { opts.map_i_ff_escc = !opts.map_i_ff_escc;                        tioPrint(opts, if (opts.map_i_ff_escc) "IFFESCC set" else "IFFESCC unset"); },
        '3' => { opts.map_i_nl_cr   = !opts.map_i_nl_cr;   ttyReconfigure(opts); tioPrint(opts, if (opts.map_i_nl_cr)   "INLCR set"   else "INLCR unset"); },
        '4' => { opts.map_i_nl_crnl = !opts.map_i_nl_crnl;                       tioPrint(opts, if (opts.map_i_nl_crnl) "INLCRNL set" else "INLCRNL unset"); },
        '5' => { opts.map_i_cr_crnl = !opts.map_i_cr_crnl;                       tioPrint(opts, if (opts.map_i_cr_crnl) "ICRCRNL set" else "ICRCRNL unset"); },
        '6' => { opts.map_i_msb2lsb = !opts.map_i_msb2lsb;                       tioPrint(opts, if (opts.map_i_msb2lsb) "IMSB2LSB set" else "IMSB2LSB unset"); },
        '7' => { opts.map_o_cr_nl   = !opts.map_o_cr_nl;                          tioPrint(opts, if (opts.map_o_cr_nl)   "OCRNL set"   else "OCRNL unset"); },
        '8' => { opts.map_o_del_bs  = !opts.map_o_del_bs;                         tioPrint(opts, if (opts.map_o_del_bs)  "ODELBS set"  else "ODELBS unset"); },
        '9' => { opts.map_o_nl_crnl = !opts.map_o_nl_crnl;                        tioPrint(opts, if (opts.map_o_nl_crnl) "ONLCRNL set" else "ONLCRNL unset"); },
        'a' => { opts.map_o_ltu     = !opts.map_o_ltu;                            tioPrint(opts, if (opts.map_o_ltu)     "OLTU set"    else "OLTU unset"); },
        'b' => { opts.map_o_nulbrk  = !opts.map_o_nulbrk;                         tioPrint(opts, if (opts.map_o_nulbrk)  "ONULBRK set" else "ONULBRK unset"); },
        'c' => { opts.map_o_ign_cr  = !opts.map_o_ign_cr;                         tioPrint(opts, if (opts.map_o_ign_cr)  "OIGNCR set"  else "OIGNCR unset"); },
        else => tioPrint(opts, "Invalid input"),
    }
}

// ── Forward one char from stdin to the device ─────────────────────────────

fn forwardToTty(c: u8, opts: *const options.Options) void {
    var ch = c;

    // Output mappings
    if (ch == 127 and opts.map_o_del_bs) ch = '\x08';
    if (ch == '\r' and opts.map_o_cr_nl) ch = '\n';
    if (ch == '\r' and opts.map_o_ign_cr) return;

    if ((ch == '\n' or ch == '\r') and opts.map_o_nl_crnl) {
        // Local echo
        if (opts.local_echo) {
            print.printChar(printchar_mode, '\r', opts.log, opts.log_strip);
            print.printChar(printchar_mode, '\n', opts.log, opts.log_strip);
        }
        ttyWrite("\r\n");
        tx_total += 2;
        return;
    }

    switch (opts.output_mode) {
        .normal => {
            if (opts.input_mode == .hex) {
                handleHexPrompt(ch, opts);
            } else {
                if (opts.input_mode != .line and opts.local_echo) {
                    print.printChar(printchar_mode, ch, opts.log, opts.log_strip);
                }
                if (ch == 0 and opts.map_o_nulbrk) {
                    _ = std.os.linux.ioctl(device_fd, TIOCSBRK, 0);
                    misc.delay(250);
                    _ = std.os.linux.ioctl(device_fd, TIOCCBRK, 0);
                } else {
                    ttyWrite(&[_]u8{ch});
                    tx_total += 1;
                }
            }
        },
        .hex => {
            if (opts.input_mode == .hex) {
                handleHexPrompt(ch, opts);
            } else {
                if (opts.local_echo) print.printChar(printchar_mode, ch, opts.log, opts.log_strip);
                ttyWrite(&[_]u8{ch});
                tx_total += 1;
            }
        },
    }
}

// ── Stdin reader thread ────────────────────────────────────────────────────

const StdinArg = struct {
    opts: *options.Options,
};

fn stdinReaderThread(arg: StdinArg) void {
    const opts = arg.opts;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch |err| {
            if (err == error.Interrupted) continue;
            break;
        };
        if (n == 0) {
            // EOF: close write end of pipe
            posix.close(pipe_fds[1]);
            break;
        }

        if (interactive_mode) {
            // Intercept quit key early (for xmodem abort etc.)
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (xymodem.key_hit == 0xff and buf[i] != 0) {
                    // not waiting for a key hit
                } else if (xymodem.key_hit == 0xff) {
                    // key hit slot empty, nothing to do
                } else {
                    xymodem.key_hit = buf[i];
                    // Remove from buffer
                    var j = i;
                    while (j < n - 1) : (j += 1) buf[j] = buf[j + 1];
                    continue;
                }
                _ = opts;
            }
        }

        // Write to pipe for the main select loop
        var written: usize = 0;
        while (written < n) {
            const w = posix.write(pipe_fds[1], buf[written..n]) catch break;
            written += w;
        }
    }
}

pub fn ttyInputThreadCreate(opts: *options.Options) !void {
    pipe_fds = try posix.pipe();
    _ = try std.Thread.spawn(.{}, stdinReaderThread, .{StdinArg{ .opts = opts }});
}

// ── Device search / wait ───────────────────────────────────────────────────

pub fn ttySearch(
    opts: *options.Options,
    cfg: *configfile.Config,
    allocator: std.mem.Allocator,
) void {
    switch (opts.auto_connect) {
        .direct => {
            const target = if (cfg.device) |d| d else opts.target;
            device_name = target;

            // Check for 4-char topology ID
            if (target.len == TOPOLOGY_ID_SIZE) {
                var dev_list = fs_mod.searchSerialDevices(
                    allocator,
                    opts.exclude_devices,
                    opts.exclude_drivers,
                    opts.exclude_tids,
                ) catch return;
                defer fs_mod.freeDeviceList(&dev_list, allocator);
                for (dev_list.items) |dev| {
                    if (std.mem.eql(u8, dev.tid[0..4], target)) {
                        device_name = dev.path;
                        return;
                    }
                }
            }
        },

        .new => {
            // Snapshot current devices
            var first_list = fs_mod.searchSerialDevices(
                allocator, opts.exclude_devices, opts.exclude_drivers, opts.exclude_tids,
            ) catch return;
            var min_uptime: f64 = if (first_list.items.len > 0)
                first_list.items[first_list.items.len - 1].uptime
            else
                std.math.floatMax(f64);
            fs_mod.freeDeviceList(&first_list, allocator);

            tioPrint(opts, "Waiting for tty device..");
            while (true) {
                var list = fs_mod.searchSerialDevices(
                    allocator, opts.exclude_devices, opts.exclude_drivers, opts.exclude_tids,
                ) catch { misc.delay(500); continue; };
                defer fs_mod.freeDeviceList(&list, allocator);
                for (list.items) |dev| {
                    if (dev.uptime < min_uptime) {
                        device_name = dev.path;
                        return;
                    }
                }
                misc.delay(500);
            }
        },

        .latest => {
            var list = fs_mod.searchSerialDevices(
                allocator, opts.exclude_devices, opts.exclude_drivers, opts.exclude_tids,
            ) catch return;
            defer fs_mod.freeDeviceList(&list, allocator);
            if (list.items.len > 0) {
                device_name = list.items[list.items.len - 1].path;
            }
        },
    }
}

pub fn ttyWaitForDevice(opts: *options.Options, cfg: *configfile.Config, allocator: std.mem.Allocator) void {
    var first = true;
    var last_errno: posix.E = .SUCCESS;

    while (true) {
        ttySearch(opts, cfg, allocator);

        if (interactive_mode) {
            // Poll pipe + sockets briefly so we can handle Ctrl-t q while waiting
            var poll_fds: [2]posix.pollfd = .{
                .{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = socket.serverFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            const n_fds: usize = if (socket.serverFd() >= 0) 2 else 1;
            const timeout_ms: i32 = if (first) 0 else 1000;
            first = false;

            const n = posix.poll(poll_fds[0..n_fds], timeout_ms) catch 0;
            if (n > 0 and poll_fds[0].revents & posix.POLL.IN != 0) {
                var c: u8 = 0;
                _ = posix.read(pipe_fds[0], std.mem.asBytes(&c)) catch {};
                var out_c: u8 = c;
                var fwd: bool = false;
                var opts_mut = opts.*;
                handleCommandSequence(c, &out_c, &fwd, &opts_mut, cfg);
            }
        }

        // Check device accessibility
        posix.access(device_name, posix.F_OK) catch |err| {
            const errno = posix.errno(@intFromEnum(err));
            if (errno != last_errno) {
                tioPrint(opts, std.fmt.allocPrint(allocator, "Could not open {s} ({any})", .{ device_name, err }) catch "");
                tioPrint(opts, "Waiting for tty device..");
                last_errno = errno;
            }
            if (!interactive_mode) misc.delay(1000);
            continue;
        };
        return;
    }
}

// ── Disconnect / cleanup ───────────────────────────────────────────────────

pub fn ttyDisconnect(opts: *const options.Options) void {
    if (connected) {
        tioPrint(opts, "Disconnected");
        posix.flock(device_fd, .{ .type = .UN }) catch {};
        posix.close(device_fd);
        device_fd = -1;
        connected = false;
        alert_mod.alertDisconnect(opts.alert);
    }
}

pub fn ttyRestore(opts: *const options.Options) void {
    if (device_fd >= 0) {
        posix.tcsetattr(device_fd, .NOW, &tio_old) catch {};
    }
    if (opts.rs485) rs485_mod.restoreRs485(device_fd);
    ttyDisconnect(opts);
}

// ── Main connect / I/O loop ───────────────────────────────────────────────

pub fn ttyConnect(opts: *options.Options, cfg: *configfile.Config, allocator: std.mem.Allocator) !void {
    g_opts = opts;

    // Open device
    device_fd = try posix.open(device_name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);

    // Verify it's a tty
    if (!posix.isatty(device_fd)) {
        tioPrint(opts, "Error: Not a tty device");
        posix.close(device_fd);
        return error.NotATty;
    }

    // Exclusive lock
    posix.flock(device_fd, .{ .type = .EX, .wait = false }) catch |err| {
        if (err == error.WouldBlock) {
            tioPrint(opts, "Error: Device file is locked by another process");
            posix.close(device_fd);
            return error.DeviceLocked;
        }
        return err;
    };

    // Flush stale I/O
    _ = std.c.tcflush(device_fd, TCIOFLUSH);

    // Print connect status
    tioPrint(opts, try std.fmt.allocPrint(allocator, "Connected to {s}", .{device_name}));
    connected = true;
    print.print_tainted = false;

    // Alert
    alert_mod.alertConnect(opts.alert);

    // Save original port settings
    tio_old = try posix.tcgetattr(device_fd);

    // Enable RS-485
    if (opts.rs485) try rs485_mod.enableRs485(device_fd, opts.rs485_cfg);

    // Apply port settings
    try posix.tcsetattr(device_fd, .NOW, &tio_new);

    // Set non-standard baud rate
    if (!standard_baudrate) {
        try setspeed.setSpeed(device_fd, opts.baudrate);
    }

    // Set output mode
    setOutputMode(opts.output_mode);

    // If stdin is a pipe, forward all to device and exit
    if (!interactive_mode) {
        var buf: [1]u8 = undefined;
        while (true) {
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break;
            _ = posix.write(device_fd, &buf) catch break;
        }
        ttyRestore(opts);
        std.process.exit(0);
    }

    // Execute --exec command if given
    if (opts.exec) |cmd| {
        const status = misc.executeShellCommand(device_fd, cmd, allocator) catch -1;
        ttyRestore(opts);
        std.process.exit(@intCast(if (status < 0) 1 else status));
    }

    // Initialise readline
    readline.readlineInit();

    // ── Main I/O loop ───────────────────────────────────────────────────
    var do_timestamp = opts.timestamp != .none;
    var poll_fds_buf: [MAX_POLL_FDS]posix.pollfd = undefined;

    while (!signals.quit_requested) {
        // Build poll list: device, pipe, socket server, socket clients
        var nfds: usize = 0;
        poll_fds_buf[nfds] = .{ .fd = device_fd, .events = posix.POLL.IN, .revents = 0 };
        nfds += 1;
        poll_fds_buf[nfds] = .{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 };
        nfds += 1;
        if (socket.serverFd() >= 0) {
            poll_fds_buf[nfds] = .{ .fd = socket.serverFd(), .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }
        for (socket.clientFds()) |cfd| {
            if (cfd >= 0) {
                poll_fds_buf[nfds] = .{ .fd = cfd, .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }

        const poll_fds = poll_fds_buf[0..nfds];
        const ready = posix.poll(poll_fds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };
        if (ready == 0) continue;

        for (poll_fds) |pfd| {
            if (pfd.revents == 0) continue;

            if (pfd.fd == device_fd) {
                // ── Data from serial device ────────────────────────────
                var rbuf: [4096]u8 = undefined;
                const n = posix.read(device_fd, &rbuf) catch {
                    ttyDisconnect(opts);
                    return error.DeviceRead;
                };
                if (n == 0) {
                    ttyDisconnect(opts);
                    return error.DeviceRead;
                }
                rx_total += n;

                for (rbuf[0..n]) |c| {
                    var ch = c;

                    // MSB-to-LSB bit reversal
                    if (opts.map_i_msb2lsb) {
                        var reversed: u8 = 0;
                        var j: u3 = 0;
                        while (j < 8) : (j += 1) {
                            if (ch & (@as(u8, 1) << j) != 0) reversed |= @as(u8, 1) << (7 - j);
                        }
                        ch = reversed;
                    }

                    // Timestamp handling (normal mode: per-line)
                    if (opts.output_mode == .normal and do_timestamp and ch != '\n' and ch != '\r') {
                        if (timestamp.currentTime(opts.timestamp)) |ts| {
                            const tw = std.io.getStdOut().writer();
                            if (opts.color >= 0) tw.writeAll(print.ansi_format[0..print.ansi_format_len]) catch {};
                            tw.print("[{s}] ", .{ts}) catch {};
                            if (opts.log) log.logWrite("[{s}] ", .{ts});
                        }
                        do_timestamp = false;
                    }

                    // Input mappings
                    if (ch == '\n' and opts.map_i_nl_crnl and !opts.map_i_msb2lsb) {
                        printChar('\r', opts);
                        printChar('\n', opts);
                        if (opts.timestamp != .none) do_timestamp = true;
                    } else if (ch == '\r' and opts.map_i_cr_crnl and !opts.map_i_msb2lsb) {
                        printChar('\r', opts);
                        printChar('\n', opts);
                        if (opts.timestamp != .none) do_timestamp = true;
                    } else if (ch == '\x0C' and opts.map_i_ff_escc and !opts.map_i_msb2lsb) {
                        printChar('\x1b', opts);
                        printChar('c', opts);
                    } else {
                        printChar(ch, opts);
                    }

                    print.print_tainted = true;

                    if (ch == '\n' and opts.timestamp != .none) do_timestamp = true;
                }
            } else if (pfd.fd == pipe_fds[0]) {
                // ── Data from stdin (via pipe) ─────────────────────────
                var rbuf: [4096]u8 = undefined;
                const n = posix.read(pipe_fds[0], &rbuf) catch continue;
                if (n == 0) {
                    // EOF
                    ttySyncBuffer();
                    std.process.exit(0);
                }

                for (rbuf[0..n]) |c| {
                    var out_c = c;
                    var fwd = true;

                    if (opts.prefix_enabled and c == opts.prefix_code) fwd = false;
                    handleCommandSequence(c, &out_c, &fwd, opts, cfg);

                    if (fwd) {
                        switch (opts.input_mode) {
                            .hex => {
                                if (!isValidHex(out_c)) {
                                    tioPrint(opts, "Invalid hex character");
                                    fwd = false;
                                }
                            },
                            .line => {
                                if (out_c == '\r') {
                                    const rl_line = readline.readlineGet();
                                    ttyWrite(rl_line);
                                } else {
                                    _ = readline.readlineInput(out_c);
                                    fwd = false;
                                }
                            },
                            .normal => {},
                        }

                        if (fwd) forwardToTty(out_c, opts);
                    }
                }
                ttySyncBuffer();
            } else if (pfd.fd == socket.serverFd()) {
                // ── New socket client ──────────────────────────────────
                socket.acceptClient();
            } else {
                // ── Data from socket client ────────────────────────────
                if (socket.socketHandleInput(pfd.fd)) |ch| {
                    var c = ch;
                    // Apply input mappings
                    if (c == '\n' and opts.map_i_nl_cr) c = '\r';
                    if (c == '\r' and opts.map_ign_cr) continue;
                    if (c == '\r' and opts.map_i_cr_nl) c = '\n';
                    forwardToTty(c, opts);
                    ttySyncBuffer();
                }
            }
        }
    }
}

const MAX_POLL_FDS = 2 + 1 + 16; // device + pipe + server + clients

// ── List serial devices ────────────────────────────────────────────────────

pub fn listSerialDevices(opts: *const options.Options, allocator: std.mem.Allocator) void {
    var list = fs_mod.searchSerialDevices(
        allocator,
        opts.exclude_devices,
        opts.exclude_drivers,
        opts.exclude_tids,
    ) catch return;
    defer fs_mod.freeDeviceList(&list, allocator);

    if (list.items.len == 0) {
        std.io.getStdOut().writer().print("No serial devices found.\n", .{}) catch {};
        return;
    }

    var max_len: usize = 17;
    for (list.items) |dev| {
        if (dev.path.len > max_len) max_len = dev.path.len;
    }

    const w = std.io.getStdOut().writer();
    print.printPadded("Device", max_len, ' ');
    w.print(" TID     Uptime [s] Driver           Description\n", .{}) catch {};
    print.printPadded("", max_len, '-');
    w.print(" ---- ------------- ---------------- --------------------------\n", .{}) catch {};

    for (list.items) |dev| {
        print.printPadded(dev.path, max_len, ' ');
        w.print(" {s:4} {d:13.3} {s:<16} {s}\n",
            .{ dev.tid[0..4], dev.uptime, dev.driver, dev.description }) catch {};
    }
}

/// Translate a numeric baud rate to the corresponding POSIX speed constant.
fn baudrateToSpeed(baud: u32) ?posix.speed_t {
    return switch (baud) {
        0      => posix.B0,
        50     => posix.B50,
        75     => posix.B75,
        110    => posix.B110,
        134    => posix.B134,
        150    => posix.B150,
        200    => posix.B200,
        300    => posix.B300,
        600    => posix.B600,
        1200   => posix.B1200,
        1800   => posix.B1800,
        2400   => posix.B2400,
        4800   => posix.B4800,
        9600   => posix.B9600,
        19200  => posix.B19200,
        38400  => posix.B38400,
        57600  => posix.B57600,
        115200 => posix.B115200,
        230400 => posix.B230400,
        else   => null,
    };
}
