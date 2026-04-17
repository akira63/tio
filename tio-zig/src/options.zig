// tio - a serial device I/O tool (Zig rewrite)
// options.zig: command-line argument parsing
// Lua scripting dependency has been removed entirely.

const std = @import("std");
const timestamp = @import("timestamp.zig");
const alert = @import("alert.zig");
const rs485 = @import("rs485.zig");

pub const Flow = enum { none, hard, soft };
pub const Parity = enum { none, odd, even, mark, space };
pub const AutoConnect = enum { direct, new, latest };
pub const InputMode = enum { normal, hex, line };
pub const OutputMode = enum { normal, hex };

pub const Options = struct {
    // Connection
    target: []const u8 = "",
    baudrate: u32 = 115200,
    databits: u8 = 8,
    flow: Flow = .none,
    stopbits: u8 = 1,
    parity: Parity = .none,

    // Delays
    output_delay: u32 = 0,
    output_line_delay: u32 = 0,

    // Pulse durations (ms)
    dtr_pulse_duration: u32 = 100,
    rts_pulse_duration: u32 = 100,
    cts_pulse_duration: u32 = 100,
    dsr_pulse_duration: u32 = 100,
    dcd_pulse_duration: u32 = 100,
    ri_pulse_duration: u32 = 100,

    // Reconnect behaviour
    no_reconnect: bool = false,
    auto_connect: AutoConnect = .direct,

    // Logging
    log: bool = false,
    log_append: bool = false,
    log_strip: bool = false,
    log_filename: ?[]const u8 = null,
    log_directory: ?[]const u8 = null,

    // Terminal
    local_echo: bool = false,
    timestamp: timestamp.Timestamp = .none,
    timestamp_timeout: u32 = 200,
    color: i32 = 256, // 256 = bold; -1 = no color; 0-255 = 256-color fg
    mute: bool = false,
    vt100: bool = false,
    input_mode: InputMode = .normal,
    output_mode: OutputMode = .normal,
    hex_n_value: u32 = 0,

    // Prefix key (default: Ctrl-T)
    prefix_code: u8 = 20,
    prefix_key: u8 = 't',
    prefix_enabled: bool = true,

    // Socket
    socket: ?[]const u8 = null,

    // RS-485
    rs485: bool = false,
    rs485_cfg: rs485.Rs485Config = .{},

    // Alerts
    alert: alert.Alert = .none,

    // Exec
    exec: ?[]const u8 = null,

    // Exclusion filters
    exclude_devices: ?[]const u8 = null,
    exclude_drivers: ?[]const u8 = null,
    exclude_tids: ?[]const u8 = null,

    // Character mappings
    map_i_nl_cr: bool = false,
    map_i_cr_nl: bool = false,
    map_ign_cr: bool = false,
    map_i_ff_escc: bool = false,
    map_i_nl_crnl: bool = false,
    map_i_cr_crnl: bool = false,
    map_o_cr_nl: bool = false,
    map_o_nl_crnl: bool = false,
    map_o_del_bs: bool = false,
    map_o_ltu: bool = false,
    map_o_nulbrk: bool = false,
    map_i_msb2lsb: bool = false,
    map_o_ign_cr: bool = false,

    // Meta
    complete_profiles: bool = false,
    list_devices: bool = false,
};

pub const ParseError = error{
    InvalidArgument,
    MissingValue,
    InvalidValue,
    OutOfMemory,
    UnknownOption,
};

const VERSION = "3.9.0";

const HELP =
    \\Usage: tio [OPTIONS] <device>
    \\
    \\Connect to a TTY serial device.
    \\
    \\Options:
    \\  -b, --baudrate <bps>          Baud rate (default: 115200)
    \\  -d, --databits <5-8>          Data bits (default: 8)
    \\  -f, --flow <none|hard|soft>   Flow control (default: none)
    \\  -s, --stopbits <1|2>          Stop bits (default: 1)
    \\  -p, --parity <none|odd|even|mark|space>
    \\                                Parity (default: none)
    \\  -o, --output-delay <ms>       Output delay per character (ms)
    \\  -O, --output-line-delay <ms>  Output delay per line (ms)
    \\  -n, --no-reconnect            Do not reconnect if disconnected
    \\  -e, --local-echo              Enable local echo
    \\  -t, --timestamp [<format>]    Timestamp mode
    \\      --timestamp-timeout <ms>  Hex mode timestamp timeout (default: 200)
    \\  -L, --log [<file>]            Log to file
    \\      --log-directory <dir>     Log directory
    \\      --log-strip               Strip control chars from log
    \\      --log-append              Append to existing log file
    \\  -l, --list                    List available serial devices
    \\  -c, --color <0-255|bold>      Color scheme
    \\  -m, --mute                    Suppress tio messages
    \\      --map <list>              Character mapping
    \\  -S, --socket <uri>            Socket forwarding (unix:/path, inet:port, inet6:port)
    \\      --rs485                   Enable RS-485 mode
    \\      --rs485-config <opts>     RS-485 configuration
    \\      --alert <none|bell|blink> Connect/disconnect alert
    \\  -A, --auto-connect <mode>     Auto-connect mode (direct|new|latest)
    \\      --exclude-devices <pats>  Exclude device patterns
    \\      --exclude-drivers <pats>  Exclude driver patterns
    \\      --exclude-tids <pats>     Exclude topology-ID patterns
    \\  -x, --exec <cmd>              Execute shell command with device I/O
    \\      --vt100                   Enable VT100 mode
    \\      --prefix-key <key>        Prefix key letter (default: t → Ctrl-t)
    \\      --hex-n <n>               Hex mode: bytes per line
    \\      --complete-profiles       List configuration profiles (for shell completion)
    \\  -v, --version                 Show version
    \\  -h, --help                    Show this help
    \\
;

/// Parse the command-line arguments.  `args` should be the raw arg list
/// (without the program name).  Returns the parsed Options and, if a non-option
/// argument is present, sets `opts.target`.
pub fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) ParseError!Options {
    _ = allocator;
    var opts = Options{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i < args.len) opts.target = args[i];
            break;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            // ── Long options ──────────────────────────────────────────────
            if (std.mem.startsWith(u8, arg, "--")) {
                const long = arg[2..];
                if (std.mem.eql(u8, long, "help") or std.mem.eql(u8, long, "h")) {
                    std.io.getStdOut().writeAll(HELP) catch {};
                    std.process.exit(0);
                } else if (std.mem.eql(u8, long, "version") or std.mem.eql(u8, long, "v")) {
                    std.io.getStdOut().writer().print("tio {s}\n", .{VERSION}) catch {};
                    std.process.exit(0);
                } else if (std.mem.eql(u8, long, "list") or std.mem.eql(u8, long, "l")) {
                    opts.list_devices = true;
                } else if (std.mem.eql(u8, long, "no-reconnect") or std.mem.eql(u8, long, "n")) {
                    opts.no_reconnect = true;
                } else if (std.mem.eql(u8, long, "local-echo") or std.mem.eql(u8, long, "e")) {
                    opts.local_echo = true;
                } else if (std.mem.eql(u8, long, "mute") or std.mem.eql(u8, long, "m")) {
                    opts.mute = true;
                } else if (std.mem.eql(u8, long, "rs485")) {
                    opts.rs485 = true;
                } else if (std.mem.eql(u8, long, "vt100")) {
                    opts.vt100 = true;
                } else if (std.mem.eql(u8, long, "log-strip")) {
                    opts.log_strip = true;
                } else if (std.mem.eql(u8, long, "log-append")) {
                    opts.log_append = true;
                } else if (std.mem.eql(u8, long, "complete-profiles")) {
                    opts.complete_profiles = true;
                } else if (std.mem.eql(u8, long, "baudrate") or std.mem.eql(u8, long, "b")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.baudrate = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "databits") or std.mem.eql(u8, long, "d")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.databits = std.fmt.parseInt(u8, args[i], 10) catch return error.InvalidValue;
                    if (opts.databits < 5 or opts.databits > 8) return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "stopbits") or std.mem.eql(u8, long, "s")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.stopbits = std.fmt.parseInt(u8, args[i], 10) catch return error.InvalidValue;
                    if (opts.stopbits < 1 or opts.stopbits > 2) return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "flow") or std.mem.eql(u8, long, "f")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.flow = parseFlow(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "parity") or std.mem.eql(u8, long, "p")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.parity = parseParity(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "output-delay") or std.mem.eql(u8, long, "o")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.output_delay = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "output-line-delay") or std.mem.eql(u8, long, "O")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.output_line_delay = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "timestamp") or std.mem.eql(u8, long, "t")) {
                    // Optional value: if next arg starts with '-' or is missing, use 24hour
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        opts.timestamp = parseTimestamp(args[i]) orelse return error.InvalidValue;
                    } else {
                        opts.timestamp = .hour24;
                    }
                } else if (std.mem.eql(u8, long, "timestamp-timeout")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.timestamp_timeout = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "log") or std.mem.eql(u8, long, "L")) {
                    opts.log = true;
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        opts.log_filename = args[i];
                    }
                } else if (std.mem.eql(u8, long, "log-directory")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.log_directory = args[i];
                } else if (std.mem.eql(u8, long, "color") or std.mem.eql(u8, long, "c")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.color = parseColor(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "map")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    parseMappings(args[i], &opts);
                } else if (std.mem.eql(u8, long, "socket") or std.mem.eql(u8, long, "S")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.socket = args[i];
                } else if (std.mem.eql(u8, long, "rs485-config")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    rs485.parseRs485Config(args[i], &opts.rs485_cfg);
                } else if (std.mem.eql(u8, long, "alert")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.alert = parseAlert(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "auto-connect") or std.mem.eql(u8, long, "A")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.auto_connect = parseAutoConnect(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "exclude-devices")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.exclude_devices = args[i];
                } else if (std.mem.eql(u8, long, "exclude-drivers")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.exclude_drivers = args[i];
                } else if (std.mem.eql(u8, long, "exclude-tids")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.exclude_tids = args[i];
                } else if (std.mem.eql(u8, long, "exec") or std.mem.eql(u8, long, "x")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.exec = args[i];
                } else if (std.mem.eql(u8, long, "prefix-key")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    const k = args[i];
                    if (k.len != 1 or k[0] < 'a' or k[0] > 'z') return error.InvalidValue;
                    opts.prefix_key = k[0];
                    opts.prefix_code = k[0] & ~@as(u8, 0x60);
                } else if (std.mem.eql(u8, long, "hex-n")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.hex_n_value = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "line-pulse-duration")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    parseLinePulseDuration(args[i], &opts);
                } else if (std.mem.eql(u8, long, "input-mode")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.input_mode = parseInputMode(args[i]) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, long, "output-mode")) {
                    i += 1;
                    if (i >= args.len) return error.MissingValue;
                    opts.output_mode = parseOutputMode(args[i]) orelse return error.InvalidValue;
                } else {
                    std.io.getStdErr().writer().print("Unknown option: --{s}\n", .{long}) catch {};
                    return error.UnknownOption;
                }
            } else {
                // ── Short options (combined, e.g. -be) ─────────────────
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'h' => {
                            std.io.getStdOut().writeAll(HELP) catch {};
                            std.process.exit(0);
                        },
                        'v' => {
                            std.io.getStdOut().writer().print("tio {s}\n", .{VERSION}) catch {};
                            std.process.exit(0);
                        },
                        'l' => opts.list_devices = true,
                        'n' => opts.no_reconnect = true,
                        'e' => opts.local_echo = true,
                        'm' => opts.mute = true,
                        'b' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.baudrate = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                        },
                        'd' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.databits = std.fmt.parseInt(u8, args[i], 10) catch return error.InvalidValue;
                        },
                        's' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.stopbits = std.fmt.parseInt(u8, args[i], 10) catch return error.InvalidValue;
                        },
                        'f' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.flow = parseFlow(args[i]) orelse return error.InvalidValue;
                        },
                        'p' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.parity = parseParity(args[i]) orelse return error.InvalidValue;
                        },
                        'o' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.output_delay = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                        },
                        'O' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.output_line_delay = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
                        },
                        't' => {
                            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                                i += 1;
                                opts.timestamp = parseTimestamp(args[i]) orelse return error.InvalidValue;
                            } else {
                                opts.timestamp = .hour24;
                            }
                        },
                        'L' => {
                            opts.log = true;
                            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                                i += 1;
                                opts.log_filename = args[i];
                            }
                        },
                        'c' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.color = parseColor(args[i]) orelse return error.InvalidValue;
                        },
                        'S' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.socket = args[i];
                        },
                        'A' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.auto_connect = parseAutoConnect(args[i]) orelse return error.InvalidValue;
                        },
                        'x' => {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            opts.exec = args[i];
                        },
                        else => {
                            std.io.getStdErr().writer().print("Unknown option: -{c}\n", .{arg[j]}) catch {};
                            return error.UnknownOption;
                        },
                    }
                }
            }
        } else {
            // Non-option argument → device target
            opts.target = arg;
        }
    }

    return opts;
}

// ── Parsers for option values ─────────────────────────────────────────────

pub fn parseFlow(s: []const u8) ?Flow {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "hard")) return .hard;
    if (std.mem.eql(u8, s, "soft")) return .soft;
    return null;
}

pub fn parseParity(s: []const u8) ?Parity {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "odd")) return .odd;
    if (std.mem.eql(u8, s, "even")) return .even;
    if (std.mem.eql(u8, s, "mark")) return .mark;
    if (std.mem.eql(u8, s, "space")) return .space;
    return null;
}

pub fn parseAutoConnect(s: []const u8) ?AutoConnect {
    if (std.mem.eql(u8, s, "direct")) return .direct;
    if (std.mem.eql(u8, s, "new")) return .new;
    if (std.mem.eql(u8, s, "latest")) return .latest;
    return null;
}

pub fn parseTimestamp(s: []const u8) ?timestamp.Timestamp {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "24hour")) return .hour24;
    if (std.mem.eql(u8, s, "24hour-start")) return .hour24_start;
    if (std.mem.eql(u8, s, "24hour-delta")) return .hour24_delta;
    if (std.mem.eql(u8, s, "iso8601")) return .iso8601;
    if (std.mem.eql(u8, s, "epoch")) return .epoch;
    if (std.mem.eql(u8, s, "epoch-usec")) return .epoch_usec;
    return null;
}

pub fn parseAlert(s: []const u8) ?alert.Alert {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "bell")) return .bell;
    if (std.mem.eql(u8, s, "blink")) return .blink;
    return null;
}

pub fn parseInputMode(s: []const u8) ?InputMode {
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "hex")) return .hex;
    if (std.mem.eql(u8, s, "line")) return .line;
    return null;
}

pub fn parseOutputMode(s: []const u8) ?OutputMode {
    if (std.mem.eql(u8, s, "normal")) return .normal;
    if (std.mem.eql(u8, s, "hex")) return .hex;
    return null;
}

fn parseColor(s: []const u8) ?i32 {
    if (std.mem.eql(u8, s, "bold")) return 256;
    if (std.mem.eql(u8, s, "none")) return -1;
    const v = std.fmt.parseInt(i32, s, 10) catch return null;
    if (v < 0 or v > 255) return null;
    return v;
}

fn parseLinePulseDuration(s: []const u8, opts: *Options) void {
    // Format: "DTR=N,RTS=N,CTS=N,DSR=N,DCD=N,RI=N" (any combination)
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (std.mem.startsWith(u8, t, "DTR=")) opts.dtr_pulse_duration = std.fmt.parseInt(u32, t[4..], 10) catch continue;
        if (std.mem.startsWith(u8, t, "RTS=")) opts.rts_pulse_duration = std.fmt.parseInt(u32, t[4..], 10) catch continue;
        if (std.mem.startsWith(u8, t, "CTS=")) opts.cts_pulse_duration = std.fmt.parseInt(u32, t[4..], 10) catch continue;
        if (std.mem.startsWith(u8, t, "DSR=")) opts.dsr_pulse_duration = std.fmt.parseInt(u32, t[4..], 10) catch continue;
        if (std.mem.startsWith(u8, t, "DCD=")) opts.dcd_pulse_duration = std.fmt.parseInt(u32, t[4..], 10) catch continue;
        if (std.mem.startsWith(u8, t, "RI=")) opts.ri_pulse_duration = std.fmt.parseInt(u32, t[3..], 10) catch continue;
    }
}

fn parseMappings(s: []const u8, opts: *Options) void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (std.mem.eql(u8, t, "ICRNL")) opts.map_i_cr_nl = true;
        if (std.mem.eql(u8, t, "IGNCR")) opts.map_ign_cr = true;
        if (std.mem.eql(u8, t, "IFFESCC")) opts.map_i_ff_escc = true;
        if (std.mem.eql(u8, t, "INLCR")) opts.map_i_nl_cr = true;
        if (std.mem.eql(u8, t, "INLCRNL")) opts.map_i_nl_crnl = true;
        if (std.mem.eql(u8, t, "ICRCRNL")) opts.map_i_cr_crnl = true;
        if (std.mem.eql(u8, t, "IMSB2LSB")) opts.map_i_msb2lsb = true;
        if (std.mem.eql(u8, t, "OCRNL")) opts.map_o_cr_nl = true;
        if (std.mem.eql(u8, t, "ODELBS")) opts.map_o_del_bs = true;
        if (std.mem.eql(u8, t, "ONLCRNL")) opts.map_o_nl_crnl = true;
        if (std.mem.eql(u8, t, "OLTU")) opts.map_o_ltu = true;
        if (std.mem.eql(u8, t, "ONULBRK")) opts.map_o_nulbrk = true;
        if (std.mem.eql(u8, t, "OIGNCR")) opts.map_o_ign_cr = true;
    }
}

/// Print all active options (for ctrl-t c).
pub fn printOptions(opts: *const Options) void {
    const w = std.io.getStdOut().writer();
    w.print(" Device:           {s}\r\n", .{opts.target}) catch {};
    w.print(" Baud rate:        {d}\r\n", .{opts.baudrate}) catch {};
    w.print(" Data bits:        {d}\r\n", .{opts.databits}) catch {};
    w.print(" Flow:             {s}\r\n", .{@tagName(opts.flow)}) catch {};
    w.print(" Stop bits:        {d}\r\n", .{opts.stopbits}) catch {};
    w.print(" Parity:           {s}\r\n", .{@tagName(opts.parity)}) catch {};
    w.print(" Output delay:     {d} ms\r\n", .{opts.output_delay}) catch {};
    w.print(" Output line delay:{d} ms\r\n", .{opts.output_line_delay}) catch {};
    w.print(" Local echo:       {}\r\n", .{opts.local_echo}) catch {};
    w.print(" Auto connect:     {s}\r\n", .{@tagName(opts.auto_connect)}) catch {};
    w.print(" No reconnect:     {}\r\n", .{opts.no_reconnect}) catch {};
    w.print(" Input mode:       {s}\r\n", .{@tagName(opts.input_mode)}) catch {};
    w.print(" Output mode:      {s}\r\n", .{@tagName(opts.output_mode)}) catch {};
    w.print(" Timestamp:        {s}\r\n", .{@tagName(opts.timestamp)}) catch {};
    w.print(" Log:              {}\r\n", .{opts.log}) catch {};
    if (opts.log_filename) |f| w.print(" Log file:         {s}\r\n", .{f}) catch {};
    if (opts.socket) |s| w.print(" Socket:           {s}\r\n", .{s}) catch {};
    w.print(" RS-485:           {}\r\n", .{opts.rs485}) catch {};
    w.print(" Alert:            {s}\r\n", .{@tagName(opts.alert)}) catch {};
    if (opts.exec) |e| w.print(" Exec:             {s}\r\n", .{e}) catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "parseFlow" {
    try std.testing.expectEqual(Flow.none, parseFlow("none").?);
    try std.testing.expectEqual(Flow.hard, parseFlow("hard").?);
    try std.testing.expect(parseFlow("bad") == null);
}

test "parseParity" {
    try std.testing.expectEqual(Parity.even, parseParity("even").?);
    try std.testing.expectEqual(Parity.mark, parseParity("mark").?);
}

test "parseArgs basic" {
    const argv = [_][]const u8{ "-b", "9600", "/dev/ttyUSB0" };
    const opts = try parseArgs(&argv, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 9600), opts.baudrate);
    try std.testing.expectEqualStrings("/dev/ttyUSB0", opts.target);
}
