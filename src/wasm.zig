const std = @import("std");
const djson = @import("djson");
const Document = djson.Document;

pub const DjsonHandle = *Document;
const allocator = std.heap.wasm_allocator;

var last_error_message: [256]u8 = undefined;
var last_error_len: usize = 0;
var last_error_line: usize = 0;
var last_error_col: usize = 0;

export fn alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn djson_parse_buf(source_ptr: [*]const u8, len: usize) ?DjsonHandle {
    const source = source_ptr[0..len];
    var diag: djson.Diagnostic = .{};
    const doc = djson.parse(allocator, source, &diag) catch {
        // Capture diagnostics into global state
        last_error_line = diag.line;
        last_error_col = diag.column;
        last_error_len = @min(diag.message.len, 256);
        @memcpy(last_error_message[0..last_error_len], diag.message[0..last_error_len]);
        return null;
    };
    const res = allocator.create(Document) catch return null;
    res.* = doc;
    return res;
}

export fn djson_err_msg_ptr() [*]const u8 {
    return &last_error_message;
}
export fn djson_err_msg_len() usize {
    return last_error_len;
}
export fn djson_err_line() usize {
    return last_error_line;
}
export fn djson_err_col() usize {
    return last_error_col;
}

export fn djson_free(handle: DjsonHandle) void {
    handle.deinit();
    allocator.destroy(handle);
}

/// Returns the type of the value at the path.
/// -1: Not found, 0: null, 1: bool, 2: int, 3: float, 4: string, 5: array, 6: object
export fn djson_get_type(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize) i32 {
    const path = path_ptr[0..path_len];
    const val = handle.root.getPath(path) orelse return -1;
    // Map zig union tags to stable integers
    return switch (val) {
        .null => 0,
        .bool => 1,
        .int => 2,
        .float => 3,
        .string => 4,
        .array => 5,
        .object => 6,
    };
}

export fn djson_get_int(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize, out: *i64) bool {
    const path = path_ptr[0..path_len];
    if (handle.root.getPath(path)) |v| {
        if (v == .int) {
            out.* = v.int;
            return true;
        }
    }
    return false;
}
