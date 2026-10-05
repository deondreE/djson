const std = @import("std");
const Io = std.Io;
const djson = @import("djson");

const usage =
    \\djson {s} - a minimal, data-oriented, JSON-like language
    \\
    \\USAGE
    \\    djson [options] [file]        read `file` (or stdin if omitted or `-`)
    \\
    \\OPTIONS
    \\    -t, --to <json|djson>   output format (default: json)
    \\    -c, --compact           compact JSON (no whitespace)
    \\    -i, --indent <n>        spaces per indent level (default: 2 for json, 4 for djson)
    \\        --check             only validate; print nothing on success
    \\    -h, --help              show this help
    \\    -V, --version           show the version
    \\
;

const Format = enum { json, djson };
const version = "0.1.0";

const Options = struct {
    path: ?[]const u8 = null,
    format: Format = .djson,
    compact: bool = false,
    indent: ?u8 = null,
    check: bool = false,
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("djson: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseArgs(args: []const [:0]const u8) Options {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print(usage, .{version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("djson {s}\n", .{version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--compact")) {
            opts.compact = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            opts.check = true;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) die("`{s}` needs a value (json or djson)", .{a});
            opts.format = std.meta.stringToEnum(Format, args[i]) orelse
                die("unknown output format `{s}` (expected json or djson)", .{args[i]});
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--indent")) {
            i += 1;
            if (i >= args.len) die("`{s}` needs a number", .{a});
            opts.indent = std.fmt.parseInt(u8, args[i], 10) catch
                die("invalid indent `{s}`", .{args[i]});
        } else if (std.mem.eql(u8, a, "-")) {
            opts.path = null;
        } else if (a.len > 1 and a[0] == '-') {
            die("unknown option `{s}` (try --help)", .{a});
        } else {
            if (opts.path != null) die("only one input file is supported", .{});
            opts.path = a;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args);
    const max_input = 256 * 1024 * 1024;

    const source: []u8 = blk: {
        if (opts.path) |path| {
            break :blk Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input)) catch |err| die("cannot read `{s}`: {s}", .{ path, @errorName(err) });
        }
        const stdin = Io.File.stdin();
        if (stdin.isTty(io) catch false) die("no input file given and stdin is a terminal (try --help)", .{});
        var rbuf: [4096]u8 = undefined;
        var stdin_reader = stdin.readerStreaming(io, &rbuf);
        var list: std.ArrayList(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = stdin_reader.interface.readSliceShort(&chunk) catch |err| die("cannot read from stdin: {s}", .{@errorName(err)});
            list.appendSlice(gpa, chunk[0..n]) catch die("out of memory", .{});
            if (list.items.len > max_input) die("input is too large", .{});
            if (n < chunk.len) break;
        }
        break :blk list.toOwnedSlice(gpa) catch die("out of memory", .{});
    };
    defer gpa.free(source);

    var diag: djson.Diagnostic = undefined;
    var doc = djson.parse(gpa, source, &diag) catch |err| switch (err) {
        error.SyntaxError => {
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{
                opts.path orelse "<stdin>", diag.line, diag.column, diag.message,
            });
            std.process.exit(1);
        },
        error.OutOfMemory => die("out of memory", .{}),
        error.ProcessError => die("ProcessError", .{}),
    };
    defer doc.deinit();

    if (opts.check) return;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    switch (opts.format) {
        .json => {
            const indent: u8 = if (opts.compact) 0 else opts.indent orelse 2;
            try djson.writeJson(doc.root, out, .{ .indent = indent });
            try out.writeByte('\n');
        },
        .djson => try djson.writeDjson(doc.root, out, .{ .indent = opts.indent orelse 4 }),
    }
    try out.flush();
}
