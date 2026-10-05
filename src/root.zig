const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
    /// Objects keep insertion order. Keys are unique.
    object: []const Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };

    /// Looks upo a key in an object. Returns null for non-objects or missing keys.
    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        for (self.object) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    /// Structural equality. Objects compare by key order too.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |x| x == b.bool,
            .int => |x| x == b.int,
            .float => |x| x == b.float,
            .string => |x| std.mem.eql(u8, x, b.string),
            .array => |x| {
                if (x.len != b.array.len) return false;
                for (x, b.array) |l, r| if (!l.eql(r)) return false;
                return true;
            },
            .object => |x| {
                if (x.len != b.object.len) return false;
                for (x, b.object) |l, r| {
                    if (!std.mem.eql(u8, l.key, r.key)) return false;
                    if (!l.value.eql(r.value)) return false;
                }
                return true;
            },
        };
    }

    /// Path lookup supporting "key.subkey[0].leaf"
    pub fn getPath(self: Value, path: []const u8) ?Value {
        var it = std.mem.tokenizeAny(u8, path, ".[ ]");
        var current = self;
        while (it.next()) |segment| {
            switch (current) {
                .object => current = current.get(segment) orelse return null,
                .array => |arr| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                    if (index >= arr.len) return null;
                    current = arr[index];
                },
                else => return null,
            }
        }
        return current;
    }

    pub fn asInt(self: Value) ?i64 {
        return if (self == .int) self.int else null;
    }
    pub fn asFloat(self: Value) ?f64 {
        return if (self == .float) self.float else null;
    }
    pub fn asBool(self: Value) ?bool {
        return if (self == .bool) self.bool else null;
    }
    pub fn asString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    pub fn keys(self: Value, allocator: std.mem.Allocator) ![][]const u8 {
        if (self != .object) return error.NotAnObject;
        const result = try allocator.alloc([]const u8, self.object.len);
        for (self.object, 0..) |entry, i| {
            result[i] = entry.key;
        }
        return result;
    }

    pub fn values(self: Value, allocator: std.mem.Allocator) ![]Value {
        if (self != .object) return error.NotAnObject;
        const result = try allocator.alloc(Value, self.object.len);
        for (self.object, 0..) |entry, i| {
            result[i] = entry.value;
        }
        return result;
    }
};

/// Where and why parsing failed. `line` and `column` are 1-based.
pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{ SyntaxError, ProcessError, OutOfMemory };

/// A parsed document. All memory (including strings) is owned by `arena`,
/// so the source text does not need to outlive it.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub const ParseOptions = struct {
    max_depth: u32 = 256,
    max_input_size: usize = 10 * 1024 * 1024,
    max_string_length: usize = 1 * 1024 * 1024,
};

pub fn parseWithOptions(gpa: Allocator, source: []const u8, diag: ?*Diagnostic, options: ParseOptions) ParseError!Document {
    if (source.len > options.max_input_size) {
        if (diag) |d| d.* = .{ .message = "input exceeds maximum allowed size" };
        return error.ProcessError;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var p: Parser = .{
        .src = source,
        .arena = arena.allocator(),
        .diag = diag,
        .options = options,
    };
    const root = try p.parseDocument();
    return .{ .arena = arena, .root = root };
}

/// Parses `source`. On `error.SyntaxError`, `diag` (if given) is filled in.
pub fn parse(gpa: Allocator, source: []const u8, diag: ?*Diagnostic) ParseError!Document {
    return parseWithOptions(gpa, source, diag, .{});
}

/// This maps DJSON directly to Zig structs. It handles slices and optional values.
pub fn parseInto(comptime T: type, gpa: Allocator, source: []const u8) !std.json.Parsed(T) {
    var doc = try parse(gpa, source, null);
    defer doc.deinit();

    var arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }

    const val = try bindValue(T, arena.allocator(), doc.root);
    return .{ .arena = arena.*, .value = val };
}

fn bindValue(comptime T: type, alloc: Allocator, v: Value) !T {
    const TInfo = @typeInfo(T);
    switch (TInfo) {
        .Int => return @intCast(try v.asInt() orelse return error.TypeMismatch),
        .Float => return @floatCast(try v.asFloat() orelse try v.asInt() orelse error.TypeMismatch),
        .Bool => return try v.asBool() orelse error.TypeMismatch,
        .Optional => |opt| {
            if (v == .null) return null;
            return try bindValue(opt.child, alloc, v);
        },
        .Pointer => |ptr| {
            if (ptr.size == .Slice) {
                if (ptr.child == u8) return try alloc.dupe(u8, v.asString()) orelse error.TypeMismatch;
                const src_arr = if (v == .array) v.array orelse error.TypeMismatch;
                const dest = try alloc.dupe(ptr.child, src_arr.len);
                for (dest, src_arr) |*d, s| {
                    d.* = try bindValue(ptr.child, alloc, s);
                }
                return dest;
            }
        },
        .Struct => |s| {
            if (v != .object) return error.TypeMismatch;
            var res: T = undefined;
            inline for (s.fields) |f| {
                if (v.get(f.name)) |fv| {
                    @field(res, f.name) = try bindValue(f.type, alloc, fv);
                } else if (f.default_value) |ptr| {
                    @field(res, f.name) = @as(*const f.type, @ptrCast(ptr)).*;
                } else return error.MissingField;
            }
            return res;
        },
        .Enum => {
            const name = v.asString() orelse return error.TypeMismatch;
            return std.meta.stringToEnum(T, name) orelse return error.InvalidEnum;
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

const max_depth = 256;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,
    diag: ?*Diagnostic,
    depth: u32 = 0,
    options: ParseOptions,

    const Error = ParseError;
    const Entry = Value.Entry;

    const Item = union(enum) {
        keyed: Entry,
        bare: Value,
    };

    fn fail(p: *Parser, at: usize, msg: []const u8) error{SyntaxError} {
        if (p.diag) |d| {
            var line: usize = 1;
            var column: usize = 1;
            for (p.src[0..@min(at, p.src.len)]) |c| {
                if (c == '\n') {
                    line += 1;
                    column = 1;
                } else {
                    column += 1;
                }
            }
            d.* = .{ .line = line, .column = column, .message = msg };
        }
        return error.SyntaxError;
    }

    fn parseDocument(p: *Parser) Error!Value {
        if (!std.unicode.utf8ValidateSlice(p.src)) return p.fail(0, "Input is not valid UTF-8");
        if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) p.pos = 3; // BOM

        p.skipTrivia(true);
        if (p.pos < p.src.len and (p.src[p.pos] == '{' or p.src[p.pos] == '[') or std.mem.startsWith(u8, p.src, "\"\"\"")) {
            // A file that start with a bracket is exctly one value.
            const v = try p.parseValue();
            p.skipTrivia(true);
            if (p.pos < p.src.len) return p.fail(p.pos, "Unexpected content after the first value");
            return v;
        }
        p.pos = if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) 3 else 0;
        return p.parseBody(null, false, 0);
    }

    fn isWS(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn skipInline(p: *Parser) void {
        while (p.pos < p.src.len and isWS(p.src[p.pos])) p.pos += 1;
    }

    fn commentStartsAt(p: *Parser, i: usize) bool {
        const c = p.src[i];
        return c == '#' or (c == '/' and i + 1 < p.src.len and p.src[i + 1] == '/');
    }

    fn skipToEol(p: *Parser) void {
        while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
    }

    /// Skips whitespace, newlines and comments; also command when `comma` is set.
    fn skipTrivia(p: *Parser, commas: bool) void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => p.pos += 1,
                ',' => {
                    if (!commas) return;
                    p.pos += 1;
                },
                else => {
                    if (p.commentStartsAt(p.pos)) {
                        p.skipToEol();
                    } else return;
                },
            }
        }
    }

    /// At `:` is a key separator only when followed by whitespace, a bracket,
    /// a quote, or the end of input, so `12:30` and `http://x` stay values.
    fn colonIsSep(src: []const u8, i: usize) bool {
        if (i + 1 >= src.len) return true;
        return switch (src[i + 1]) {
            ' ', '\t', '\r', '\n', '{', '[', '"' => true,
            else => false,
        };
    }

    /// Finds where an unquoted token starting at `start` ends.
    fn bareEnd(p: *Parser, start: usize, key_mode: bool) usize {
        const src = p.src;
        var i = start;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            switch (c) {
                ',', '\n', '\r', '}', ']' => break,
                '=' => if (key_mode) break,
                ':' => if (key_mode and colonIsSep(src, i)) break,
                '#' => if (i == start or isWS(src[i - 1])) break,
                '/' => if (i + 1 < src.len and src[i + 1] == '/' and (i == start or isWS(src[i - 1]))) break,
                else => {},
            }
        }
        return i;
    }

    /// Parses entries unitl `close` (or end of input when null).
    fn parseBody(p: *Parser, close: ?u8, forced_array: bool, open_pos: usize) Error!Value {
        var entries: std.ArrayList(Entry) = .empty;
        var items: std.ArrayList(Value) = .empty;
        var keys: std.StringHashMapUnmanaged(void) = .empty;

        while (true) {
            p.skipTrivia(true);
            if (p.pos >= p.src.len) {
                if (close == null) break;
                return p.fail(open_pos, "unterminated container: missing closing bracket [ ->]");
            }
            const c = p.src[p.pos];
            if (c == '}' or c == ']') {
                if (close != null and c == close.?) {
                    p.pos += 1;
                    break;
                }
                return p.fail(p.pos, "unexpected closing bracket");
            }

            const item_pos = p.pos;
            const item = try p.parseItem();
            try p.expectItemEnd(close);

            if (item == .keyed and items.items.len > 0) return p.fail(item_pos, "mixed keyed and bare entries");
            if (item == .bare and entries.items.len > 0) return p.fail(item_pos, "mixed keyed and bare entries");
            if (item == .keyed and forced_array) return p.fail(item_pos, "keyed entry in array");

            try p.expectItemEnd(close);

            switch (item) {
                .keyed => |e| {
                    const existing_idx = for (entries.items, 0..) |existing, idx| {
                        if (std.mem.eql(u8, existing.key, e.key)) break idx;
                    } else null;

                    if (existing_idx) |idx| {
                        // Key exists: check for Recursive Merge Last-Wins
                        if (entries.items[idx].value == .object and e.value == .object) {
                            entries.items[idx].value = try p.mergeObjects(entries.items[idx].value, e.value);
                        } else {
                            entries.items[idx].value = e.value;
                        }
                    } else {
                        try entries.append(p.arena, e);
                        try keys.put(p.arena, e.key, {});
                    }
                },
                .bare => |v| {
                    try items.append(p.arena, v);
                },
            }
        }

        if (forced_array) return .{ .array = try items.toOwnedSlice(p.arena) };
        if (entries.items.len > 0) return .{ .object = try entries.toOwnedSlice(p.arena) };
        if (items.items.len > 0) return .{ .array = try items.toOwnedSlice(p.arena) };

        // Default for {} or empty implicit root is an object
        return .{ .object = try entries.toOwnedSlice(p.arena) };
    }

    fn mergeObjects(p: *Parser, base: Value, override: Value) Error!Value {
        var merged: std.ArrayList(Value.Entry) = .empty;

        try merged.appendSlice(p.arena, base.object);

        for (override.object) |over_e| {
            const existing_idx = for (merged.items, 0..) |base_e, idx| {
                if (std.mem.eql(u8, base_e.key, over_e.key)) break idx;
            } else null;

            if (existing_idx) |idx| {
                if (merged.items[idx].value == .object and over_e.value == .object) {
                    merged.items[idx].value = try p.mergeObjects(merged.items[idx].value, over_e.value);
                } else {
                    merged.items[idx].value = over_e.value;
                }
            } else {
                try merged.append(p.arena, over_e);
            }
        }

        return .{ .object = try merged.toOwnedSlice(p.arena) };
    }

    fn parseItem(p: *Parser) Error!Item {
        const src = p.src;
        const start = p.pos;
        const c = src[start];

        // `.{ ... }` / `[ ... ]` is a bare container, anything else with a dot is a key.
        if (c == '.' and !(start + 1 < src.len and (src[start + 1] == '{' or src[start + 1] == '['))) {
            p.pos += 1;
            p.skipInline();
            const key = try p.parseKey();
            const value = try p.parseAfterSeparator();
            return .{ .keyed = .{ .key = key, .value = value } };
        }

        if (c == '"') {
            const s = try p.parseString();
            const after = p.pos;
            p.skipInline();
            if (p.pos < src.len and (src[p.pos] == '=' or (src[p.pos] == ':' and colonIsSep(src, p.pos)))) {
                const value = try p.parseAfterSeparator();
                return .{ .keyed = .{ .key = s, .value = value } };
            }
            p.pos = after;
            return .{ .bare = .{ .string = s } };
        }

        if (c == '{' or c == '[' or c == '.') {
            return .{ .bare = try p.parseValue() };
        }

        const key_end = p.bareEnd(start, true);
        if (key_end < src.len and (src[key_end] == '=' or (src[key_end] == ':'))) {
            const key = std.mem.trim(u8, src[start..key_end], " \t");
            if (key.len == 0) return p.fail(start, "expected a key before the separator");
            p.pos = key_end;
            const value = try p.parseAfterSeparator();
            return .{ .keyed = .{ .key = try p.arena.dupe(u8, key), .value = value } };
        }

        return .{ .bare = try p.parseScalar() };
    }

    /// After a leading dot: a quoted or unquoted key, stopping at the separator.
    fn parseKey(p: *Parser) Error![]const u8 {
        const src = p.src;
        if (p.pos < src.len and src[p.pos] == '"') return p.parseString();
        const start = p.pos;
        const end = p.bareEnd(start, true);
        if (end >= src.len or !(src[end] == '=' or src[end] == ':')) {
            return p.fail(start, "expected `=` or `:` after `.`");
        }
        const key = std.mem.trim(u8, src[start..end], " \t");
        if (key.len == 0) return p.fail(start, "expected a key after `.`");
        p.pos = end;
        return p.arena.dupe(u8, key);
    }

    /// Consumes the `=`/`:` at the cursor, then parses the value.
    fn parseAfterSeparator(p: *Parser) Error!Value {
        p.skipInline();
        if (p.pos >= p.src.len or !(p.src[p.pos] == '=' or p.src[p.pos] == ':')) {
            return p.fail(p.pos, "expected `=` or `:` after the key");
        }
        p.pos += 1;
        p.skipInline();

        // A value normally starts on the same line. Allow a `{` / '[' on a later line.
        const at_eol = p.pos >= p.src.len or p.src[p.pos] == '\n' or p.src[p.pos] == '\r' or p.commentStartsAt(p.pos);
        if (at_eol) {
            const save = p.pos;
            p.skipTrivia(false);
            if (p.pos < p.src.len and (p.src[p.pos] == '{' or p.src[p.pos] == '[')) {
                return p.parseValue();
            }
            return p.fail(save, "expected a value");
        }
        return p.parseValue();
    }

    fn parseValue(p: *Parser) Error!Value {
        const src = p.src;
        if (p.pos >= src.len) return p.fail(p.pos, "expected a value");
        var c = src[p.pos];
        if (c == '.' and p.pos + 1 < src.len and (src[p.pos + 1] == '{' or src[p.pos + 1] == '[')) {
            p.pos += 1;
            c = src[p.pos];
        }
        switch (c) {
            '{' => return p.parseContainer('}', false),
            '[' => return p.parseContainer(']', true),
            '"' => return .{ .string = try p.parseString() },
            else => return p.parseScalar(),
        }
    }

    fn parseContainer(p: *Parser, close: u8, forced_array: bool) Error!Value {
        const open_pos = p.pos;
        p.pos += 1;

        p.depth += 1;
        defer p.depth -= 1;

        if (p.depth > p.options.max_depth) return p.fail(open_pos, "nesting is too deep -- really you have a problem.");

        return p.parseBody(close, forced_array, open_pos);
    }

    fn parseScalar(p: *Parser) Error!Value {
        const start = p.pos;
        const end = p.bareEnd(start, false);
        const text = std.mem.trimEnd(u8, p.src[start..end], " \t");
        if (text.len == 0) return p.fail(start, "expected a value");
        p.pos = end;
        return switch (classify(text)) {
            .string => |s| return .{ .string = try p.arena.dupe(u8, s) },
            else => |v| v,
        };
    }

    /// After an item, only whitespace, a comment, a comma, a newline, or the
    /// closing bracket may follow.
    fn expectItemEnd(p: *Parser, close: ?u8) Error!void {
        p.skipInline();
        if (p.pos >= p.src.len) return;
        const c = p.src[p.pos];
        if (c == ',' or c == '\n' or c == '\r') return;
        if (close != null and c == close.?) return;
        if (c == '}' or c == ']') return; // reported by parseBody as a mismatch.
        if (p.commentStartsAt(p.pos)) return;
        return p.fail(p.pos, "unexpected text after value (separate entries with a newline or comma)");
    }

    fn parseString(p: *Parser) Error![]u8 {
        const src = p.src;
        const start = p.pos;

        // tripple quote case
        if (std.mem.startsWith(u8, src[p.pos..], "\"\"\"")) {
            p.pos += 3;
            // Skip the intermediate newline if the string starts with one.
            if (p.pos < src.len and src[p.pos] == '\n') {
                p.pos += 1;
            } else if (p.pos + 1 < src.len and src[p.pos] == '\r' and src[p.pos + 1] == '\n') {
                p.pos += 2;
            }

            const content_start = p.pos;
            while (p.pos + 2 < src.len) {
                if (std.mem.startsWith(u8, src[p.pos..], "\"\"\"")) {
                    const raw_text = src[content_start..p.pos];
                    p.pos += 3;
                    return p.dedent(raw_text);
                }
                p.pos += 1;
            }
            return p.fail(start, "unterminated triple-quoted string");
        }

        p.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= src.len) return p.fail(start, "unterminated string");
            const c = src[p.pos];
            switch (c) {
                '"' => {
                    p.pos += 1;
                    return buf.toOwnedSlice(p.arena);
                },
                '\n' => return p.fail(start, "newline in a string (use \\n)"),
                '\\' => {
                    const esc_pos = p.pos;
                    p.pos += 1;
                    if (p.pos >= src.len) return p.fail(esc_pos, "unterminated string");
                    const esc = src[p.pos];
                    p.pos += 1;
                    switch (esc) {
                        '"' => try buf.append(p.arena, '"'),
                        '\\' => try buf.append(p.arena, '\\'),
                        '/' => try buf.append(p.arena, '/'),
                        'b' => try buf.append(p.arena, 8),
                        'f' => try buf.append(p.arena, 12),
                        'n' => try buf.append(p.arena, '\n'),
                        'r' => try buf.append(p.arena, '\r'),
                        't' => try buf.append(p.arena, '\t'),
                        'u' => {
                            var cp: u21 = try p.parseHex4(esc_pos);
                            if (cp >= 0xD800 and cp <= 0xDBFF) {
                                if (!std.mem.startsWith(u8, src[p.pos..], "\\u")) {
                                    return p.fail(esc_pos, "unpaired surrogate in \\u sequence");
                                }
                                p.pos += 2;
                                const low = try p.parseHex4(esc_pos);
                                if (low < 0xDC00 or low > 0xDFFF) return p.fail(esc_pos, "invalid surrogate pair");
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                            } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                                return p.fail(esc_pos, "unpaired surrogate in \\u sequence");
                            }
                            var tmp: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &tmp) catch return p.fail(esc_pos, "invalid code point");
                            try buf.appendSlice(p.arena, tmp[0..n]);
                        },
                        else => return p.fail(esc_pos, "invalid escape sequence"),
                    }
                },
                else => {
                    try buf.append(p.arena, c);
                    p.pos += 1;
                },
            }
        }
    }

    /// Strips the indentation of the last line from all preceding lines.
    fn dedent(p: *Parser, text: []const u8) ![]u8 {
        if (text.len == 0) return p.arena.dupe(u8, "");

        var last_newline_idx: ?usize = null;
        var i: usize = text.len;
        while (i > 0) {
            i -= 1;
            if (text[i] == '\n') {
                last_newline_idx = i;
                break;
            }
        }

        const margin = if (last_newline_idx) |idx| text[idx + 1 ..] else "";
        // If the margin contains non-whitespace, it's not a valid margin; return raw.
        for (margin) |c| if (!isWS(c)) return p.arena.dupe(u8, text);

        var res: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;

        while (it.next()) |line| {
            if (it.rest().len == 0) break;

            if (!first) try res.append(p.arena, '\n');
            first = false;

            if (std.mem.startsWith(u8, line, margin)) {
                try res.appendSlice(p.arena, line[margin.len..]);
            } else {
                try res.appendSlice(p.arena, std.mem.trim(u8, line, " \t"));
            }
        }

        return res.toOwnedSlice(p.arena);
    }

    fn parseHex4(p: *Parser, esc_pos: usize) Error!u21 {
        if (p.pos + 4 > p.src.len) return p.fail(esc_pos, "invalid \\u sequence");
        var v: u21 = 0;
        for (p.src[p.pos..][0..4]) |h| {
            const d = std.fmt.charToDigit(h, 16) catch return p.fail(esc_pos, "invalid \\u sequence");
            v = v * 16 + d;
        }
        p.pos += 4;
        return v;
    }
};

/// Decides what an unquoted token means: `true`, `false`, `null`, and integer,
/// a float, or (otherwise) a string. The returned string aliases text.
pub fn classify(text: []const u8) Value {
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, text, "null")) return .null;

    if (looksNumeric(text)) {
        if (parseFlexibleInt(text)) |val| {
            return .{ .int = val };
        } else |_| {}

        // try float (strip underscores first)
        var buf: [128]u8 = undefined;
        var i: usize = 0;
        for (text) |c| {
            if (c != '_') {
                buf[i] = c;
                i += 1;
            }
            if (i >= 127) break;
        }
        if (std.fmt.parseFloat(f64, buf[0..i])) |f| {
            if (std.math.isFinite(f)) return .{ .float = f };
        } else |_| {}
    }
    return .{ .string = text };
}

fn parseFlexibleInt(text: []const u8) !i64 {
    var buf: [128]u8 = undefined;
    if (text.len >= buf.len) return error.InvalidCharacter;

    var i: usize = 0;
    for (text) |c| {
        if (c != '_') {
            buf[i] = c;
            i += 1;
        }
    }
    const clean = buf[0..i];
    return std.fmt.parseInt(i64, clean, 0);
}

fn looksNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    var rest = text;
    if (rest[0] == '+' or rest[0] == '-') rest = rest[1..];
    if (rest.len == 0) return false;

    // check for prefixs
    if (rest.len > 2 and rest[0] == '0') {
        switch (rest[1]) {
            'x', 'b', 'o', 'X', 'B', 'O' => return true,
            else => {},
        }
    }

    var has_digit = false;
    for (rest) |c| {
        switch (c) {
            '0'...'9' => has_digit = true,
            '+', '-', '.', 'e', 'E', '_' => {},
            else => return false,
        }
    }
    if (!has_digit) return false;

    // ID protection: "007" is a string, but "0" is a number.
    if (rest.len > 1 and rest[0] == '0' and std.ascii.isDigit(rest[1])) return false;
    return true;
}

pub const JsonOptions = struct {
    /// Spaces per level. 0 produces compact output.
    indent: u8 = 2,
};

pub fn writeJson(value: Value, w: *Writer, opts: JsonOptions) Writer.Error!void {
    try writeJsonAt(value, w, opts, 0);
}

pub fn writeNewline(w: *Writer, opts: JsonOptions, depth: usize) Writer.Error!void {
    if (opts.indent == 0) return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', depth * opts.indent);
}

fn writeJsonAt(value: Value, w: *Writer, opts: JsonOptions, depth: usize) Writer.Error!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f, true),
        .string => |s| try writeQuoted(w, s),
        .array => |items| {
            if (items.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeNewline(w, opts, depth + 1);
                try writeJsonAt(item, w, opts, depth + 1);
            }
            try writeNewline(w, opts, depth);
            try w.writeByte(']');
        },
        .object => |entries| {
            if (entries.len == 0) return w.writeAll("{}");
            try w.writeByte('{');
            for (entries, 0..) |entry, i| {
                if (i > 0) try w.writeByte(',');
                try writeNewline(w, opts, depth + 1);
                try writeQuoted(w, entry.key);
                try w.writeAll(if (opts.indent == 0) ":" else ": ");
                try writeJsonAt(entry.value, w, opts, depth + 1);
            }
            try writeNewline(w, opts, depth);
            try w.writeByte('}');
        },
    }
}

/// Writes a float so it reads back as a float (`2.0`, not `2`).
/// Non-finite values (impossible from the parser) become `null` for JSON.
fn writeFloat(w: *Writer, f: f64, json: bool) Writer.Error!void {
    if (!std.math.isFinite(f)) {
        if (json) return w.writeAll("null");
        return w.writeAll("0.0");
    }
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
        return w.print("{e}", .{f});
    };
    try w.writeAll(s);
    if (std.mem.indexOfScalar(u8, s, '.') == null) try w.writeAll(".0");
}

fn writeQuoted(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            8 => try w.writeAll("\\b"),
            12 => try w.writeAll("\\f"),
            0...7, 11, 14...31, 127 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub const DjsonOptions = struct {
    /// Spaces per level.
    indent: u8 = 4,
};

// Writes `value` as djson. A root object is written as an implicit body
/// (no outer braces); everything else is written as a single value.
pub fn writeDjson(value: Value, w: *Writer, opts: DjsonOptions) Writer.Error!void {
    switch (value) {
        .object => |entries| try writeEntries(entries, w, opts, 0),
        else => {
            try writeDjsonValue(value, w, opts, 0);
            try w.writeByte('\n');
        },
    }
}

fn writeIndent(w: *Writer, opts: DjsonOptions, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * opts.indent);
}

fn writeEntries(entries: []const Value.Entry, w: *Writer, opts: DjsonOptions, depth: usize) Writer.Error!void {
    for (entries) |e| {
        try writeIndent(w, opts, depth);
        try w.writeByte('.');
        if (needsQuoteKey(e.key)) try writeQuoted(w, e.key) else try w.writeAll(e.key);
        try w.writeAll(" = ");
        try writeDjsonValue(e.value, w, opts, depth);
        try w.writeByte('\n');
    }
}

fn isScalar(v: Value) bool {
    return switch (v) {
        .array, .object => false,
        else => true,
    };
}

fn writeDjsonValue(value: Value, w: *Writer, opts: DjsonOptions, depth: usize) Writer.Error!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f, false),
        .string => |s| {
            if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                try w.writeAll("\"\"\"\n");
                var it = std.mem.splitScalar(u8, s, '\n');
                while (it.next()) |line| {
                    try writeIndent(w, opts, depth + 1);
                    try w.writeAll(line);
                    try w.writeByte('\n');
                }
                try writeIndent(w, opts, depth + 1);
                try w.writeAll("\"\"\"");
            } else if (needsQuotedValue(s)) {
                try writeQuoted(w, s);
            } else {
                try w.writeAll(s);
            }
        },
        .array => |items| {
            if (items.len == 0) return w.writeAll("[]");
            var all_scalar = true;
            for (items) |item| {
                if (!isScalar(item)) all_scalar = false;
            }
            if (all_scalar) {
                try w.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeDjsonValue(item, w, opts, depth);
                }
                try w.writeByte(']');
                return;
            }
            try w.writeAll("[\n");
            for (items) |item| {
                try writeIndent(w, opts, depth + 1);
                try writeDjsonValue(item, w, opts, depth + 1);
                try w.writeByte('\n');
            }
            try writeIndent(w, opts, depth);
            try w.writeByte(']');
        },
        .object => |entries| {
            if (entries.len == 0) return w.writeAll("{}");
            try w.writeAll("{\n");
            try writeEntries(entries, w, opts, depth + 1);
            try writeIndent(w, opts, depth);
            try w.writeByte('}');
        },
    }
}

/// Directly convert any Zig value to DJSON format without intermediate `Value` nodes.
pub fn stringify(value: anytype, writer: anytype, opts: DjsonOptions) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .Null => try writer.writeAll("null"),
        .Bool => try writer.writeAll(if (value) "true" else "false"),
        .Int, .ComptimeInt => try writer.print("{d}", .{value}),
        .Float, .ComptimeFloat => try writer.print("{d}.0", .{value}),
        .Pointer => |ptr| {
            if (ptr.size == .Slice and ptr.child == u8) {
                if (std.mem.indexOfScalar(u8, value, '\n') != null) {
                    try writer.writeAll("\"\"\"\n");
                    var it = std.mem.splitScalar(u8, value, '\n');
                    while (it.next()) |line| {
                        try writer.writeByteNTimes(' ', opts.indent); // Use opts.indent for margin
                        try writer.writeAll(line);
                        try writer.writeByte('\n');
                    }
                    try writer.writeByteNTimes(' ', opts.indent);
                    try writer.writeAll("\"\"\"");
                } else {
                    try writeQuoted(writer, value);
                }
            } else if (ptr.size == .Slice) {
                try writer.writeAll("[");
                for (value, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try stringify(item, writer, opts);
                }
                try writer.writeAll("]");
            }
        },
        .Struct => |s| {
            try writer.writeAll("{");
            inline for (s.fields, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print(".{s} = ", .{f.name});
                try stringify(@field(value, f.name), writer, opts);
            }
            try writer.writeAll("}");
        },
        else => try writer.print("\"{any}\"", .{value}),
    }
}

fn hasCommentLookalike(s: []const u8) bool {
    if (std.mem.startsWith(u8, s, "//")) return true;
    return std.mem.indexOf(u8, s, " //") != null or std.mem.indexOf(u8, s, "\t//") != null;
}

/// true when `s` would not read back as the same stringp written unquoted.
fn needsQuotedValue(s: []const u8) bool {
    if (s.len == 0) return true;
    if (classify(s) != .string) return true;
    if (Parser.isWS(s[0]) or Parser.isWS(s[s.len - 1])) return true;
    if (s[0] == '.') return true;
    if (hasCommentLookalike(s)) return true;
    for (s, 0..) |c, i| {
        switch (c) {
            ',', '{', '}', '[', ']', '"', '\\', '#', '=' => return true,
            ':' => if (Parser.colonIsSep(s, i)) return true,
            else => if (c < 0x20 or c == 127) return true,
        }
    }
    return false;
}

fn needsQuoteKey(s: []const u8) bool {
    if (s.len == 0) return true;
    if (Parser.isWS(s[0]) or Parser.isWS(s[s.len - 1])) return true;
    if (s[0] == '.') return true;
    if (hasCommentLookalike(s)) return true;
    for (s) |c| {
        switch (c) {
            ',', '{', '}', '[', ']', '"', '\\', '#', '=', ':' => return true,
            else => if (c < 0x20 or c == 127) return true,
        }
    }
    return false;
}

const testing = std.testing;

fn toJson(gpa: Allocator, source: []const u8, indent: u8) ![]u8 {
    var doc = try parse(gpa, source, null);
    defer doc.deinit();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeJson(doc.root, &aw.writer, .{ .indent = indent });
    return aw.toOwnedSlice();
}

fn expectJson(source: []const u8, expected: []const u8) !void {
    const out = try toJson(testing.allocator, source, 0);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

fn expectError(source: []const u8, line: usize, column: usize) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(testing.allocator, source, &diag));
    try testing.expectEqual(line, diag.line);
    try testing.expectEqual(column, diag.column);
}

test "the original sample" {
    const src =
        \\{
        \\structure_name: {
        \\    .test = {
        \\        . test = {
        \\
        \\        }
        \\    },
        \\    .initial_thing = "test",
        \\}
        \\}
    ;
    try expectJson(src, "{\"structure_name\":{\"test\":{\"test\":{}},\"initial_thing\":\"test\"}}");
}

test "implicit top-level object, optional dots, both separators" {
    try expectJson(
        \\name = demo
        \\.version: 3
        \\. debug = true
    , "{\"name\":\"demo\",\"version\":3,\"debug\":true}");
}

test "scalar inference" {
    try expectJson(
        \\a = 42
        \\b = -7
        \\c = 3.5
        \\d = 1e3
        \\e = null
        \\f = false
        \\g = hello world
        \\h = 007
        \\i = inf
        \\j = nan
        \\k = "42"
        \\l = 12:30
        \\m = http://example.com/a?b=c
    ,
        "{\"a\":42,\"b\":-7,\"c\":3.5,\"d\":1000.0,\"e\":null,\"f\":false," ++
            "\"g\":\"hello world\",\"h\":\"007\",\"i\":\"inf\",\"j\":\"nan\"," ++
            "\"k\":\"42\",\"l\":\"12:30\",\"m\":\"http://example.com/a?b=c\"}",
    );
}

test "braces are arrays for bare entries and objects for keyed ones" {
    try expectJson("xs = { a, b, 3 }", "{\"xs\":[\"a\",\"b\",3]}");
    try expectJson("xs = [1, 2, 3,]", "{\"xs\":[1,2,3]}");
    try expectJson("p = { { .x = 1, .y = 2 }, .{ .x = 3 } }", "{\"p\":[{\"x\":1,\"y\":2},{\"x\":3}]}");
    try expectJson("e = {}\nf = []", "{\"e\":{},\"f\":[]}");
}

test "newlines and commas both separate entries" {
    try expectJson("o = { a = 1, b = 2\n c = 3 }", "{\"o\":{\"a\":1,\"b\":2,\"c\":3}}");
}

test "comments" {
    try expectJson(
        \\# header
        \\a = 1 # trailing
        \\b = x // also trailing
        \\c = http://x.y
        \\// whole line
        \\d = "#not a comment"
    , "{\"a\":1,\"b\":\"x\",\"c\":\"http://x.y\",\"d\":\"#not a comment\"}");
}

test "quoted strings and escapes" {
    try expectJson(
        \\a = "line\nbreak \"q\" \u00e9 \ud83d\ude00"
        \\"my key" = 1
    , "{\"a\":\"line\\nbreak \\\"q\\\" \u{e9} \u{1F600}\",\"my key\":1}");
}

test "top-level array and Allman braces" {
    try expectJson("[1, 2, { a = 1 }]", "[1,2,{\"a\":1}]");
    try expectJson("a =\n{\n  b = 1\n}", "{\"a\":{\"b\":1}}");
}

test "empty input is an empty object" {
    try expectJson("", "{}");
    try expectJson("  # nothing\n", "{}");
}

test "recursive merge duplicates" {
    const gpa = testing.allocator;
    const src =
        \\server = { host = localhost, port = 80 }
        \\server = { port = 8080, tls = true }
    ;
    var doc = try parse(gpa, src, null);
    defer doc.deinit();

    const server = doc.root.get("server").?;
    try testing.expectEqualStrings("localhost", server.get("host").?.string);
    try testing.expectEqual(@as(i64, 8080), server.get("port").?.int);
    try testing.expectEqual(true, server.get("tls").?.bool);
}

test "advanced numeric literals" {
    try expectJson("hex = 0xFF", "{\"hex\":255}");
    try expectJson("bin = 0b1010", "{\"bin\":10}");
    try expectJson("oct = 0o77", "{\"oct\":63}");
    try expectJson("large = 1_000_000", "{\"large\":1000000}");
    try expectJson("float_sep = 1_000.50", "{\"float_sep\":1000.5}");
    try expectJson("neg_hex = -0x01", "{\"neg_hex\":-1}");
}

test "depth limit" {
    const gpa = testing.allocator;
    const src = try gpa.alloc(u8, 1000);
    defer gpa.free(src);
    @memset(src, '[');
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(gpa, src, &diag));
}

test "pretty JSON" {
    const out = try toJson(testing.allocator, "a = { b = [1, 2], c = {} }", 2);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{
        \\  "a": {
        \\    "b": [
        \\      1,
        \\      2
        \\    ],
        \\    "c": {}
        \\  }
        \\}
    , out);
}

test "djson output round-trips" {
    const gpa = testing.allocator;
    const src =
        \\name = "Hello, {world}"
        \\empty = ""
        \\num_string = "42"
        \\dotted = ".hidden"
        \\url = http://x.y/z
        \\ratio = 2.0
        \\tags = [a, b, c]
        \\nested = {
        \\    list = { { .x = 1 }, { .x = 2 } }
        \\    "odd key = :" = null
        \\    inner = { }
        \\}
        \\matrix = [[1, 2], [3, 4]]
        \\multi = "a\nb\t\"q\""
    ;
    var doc = try parse(gpa, src, null);
    defer doc.deinit();

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeDjson(doc.root, &aw.writer, .{});

    var diag: Diagnostic = .{};
    var doc2 = parse(gpa, aw.written(), &diag) catch |err| {
        std.debug.print("reparse failed at {d}:{d}: {s}\n--- output ---\n{s}\n", .{ diag.line, diag.column, diag.message, aw.written() });
        return err;
    };
    defer doc2.deinit();
    try testing.expect(doc.root.eql(doc2.root));
}

test "djson outputs triple quotes for multi-line strings" {
    const gpa = testing.allocator;
    const content = "SELECT *\nFROM users";
    const val = Value{ .string = content };

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeDjsonValue(val, &aw.writer, .{}, 0);

    const expected =
        \\"""
        \\    SELECT *
        \\    FROM users
        \\    """
    ;
    try testing.expectEqualStrings(expected, aw.written());

    // Round-trip check
    var doc = try parse(gpa, aw.written(), null);
    defer doc.deinit();
    try testing.expectEqualStrings(content, doc.root.string);
}

test "get" {
    var doc = try parse(testing.allocator, "a = { b = 5 }", null);
    defer doc.deinit();
    const b = doc.root.get("a").?.get("b").?;
    try testing.expectEqual(@as(i64, 5), b.int);
    try testing.expect(doc.root.get("zzz") == null);
}
