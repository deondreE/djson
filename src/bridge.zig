const std = @import("std");
const djson = @import("djson");
const Document = djson.Document;

pub const DjsonHandle = *Document;
pub const DjsonValue = *djson.Value;
const allocator = std.heap.c_allocator;

threadlocal var last_error_message: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;
threadlocal var last_error_line: usize = 0;
threadlocal var last_error_col: usize = 0;

const ArrayIterator = struct {
    values: []const djson.Value,
    index: usize,
};

const ObjectIterator = struct {
    keys: []const []const u8,
    values: []const djson.Value,
    index: usize,
};

fn set_err(diag: djson.Diagnostic) void {
    last_error_line = diag.line;
    last_error_col = diag.column;

    const msg_len = @min(diag.message.len, 256);
    last_error_len = msg_len;

    @memcpy(last_error_message[0..msg_len], diag.message[0..msg_len]);
}

export fn djson_get_value(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize) callconv(.c) ?DjsonValue {
    const path = path_ptr[0..path_len];
    const val = handle.root.getPath(path) orelse return null;

    const res = allocator.create(djson.Value) catch return null;
    res.* = val;
    return res;
}

export fn djson_parse_buf(source_ptr: [*]const u8, len: usize) callconv(.c) ?DjsonHandle {
    const source = source_ptr[0..len];
    var diag: djson.Diagnostic = .{};
    const doc = djson.parse(allocator, source, &diag) catch {
        set_err(diag);
        return null;
    };
    const res = allocator.create(Document) catch return null;
    res.* = doc;
    return res;
}

export fn djson_free(handle: DjsonHandle) callconv(.c) void {
    handle.deinit();
    allocator.destroy(handle);
}

export fn djson_err_msg_ptr() callconv(.c) [*]const u8 {
    return &last_error_message;
}
export fn djson_err_msg_len() callconv(.c) usize {
    return last_error_len;
}
export fn djson_err_line() callconv(.c) usize {
    return last_error_line;
}
export fn djson_err_col() callconv(.c) usize {
    return last_error_col;
}

export fn alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Returns the type of the value at the path.
/// -1: Not found, 0: null, 1: bool, 2: int, 3: float, 4: string, 5: array, 6: object
export fn djson_get_type(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize) callconv(.c) i32 {
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

export fn djson_get_int(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize, out: *i64) callconv(.c) bool {
    const path = path_ptr[0..path_len];
    if (handle.root.getPath(path)) |v| {
        if (v == .int) {
            out.* = v.int;
            return true;
        }
    }
    return false;
}

// Array iteration

export fn djson_array_iter(val: DjsonValue) callconv(.c) ?*ArrayIterator {
    if (val.* != .array) return null;
    const it = allocator.create(ArrayIterator) catch return null;

    it.* = .{ .values = val.array, .index = 0 };
    return it;
}

export fn djson_array_next(it: *ArrayIterator) callconv(.c) ?DjsonValue {
    if (it.index >= it.values.len) return null;
    const val = &it.values[it.index];
    it.index += 1;
    return @constCast(val);
}

export fn djson_array_iter_free(it: *ArrayIterator) callconv(.c) void {
    allocator.destroy(it);
}

// Object iterators
export fn djson_object_iter(val: DjsonValue) callconv(.c) ?*ObjectIterator {
    if (val.* != .object) return null;
    const k = val.keys(allocator) catch return null;
    const v = val.values(allocator) catch {
        allocator.free(k);
        return null;
    };

    const it = allocator.create(ObjectIterator) catch {
        allocator.free(k);
        allocator.free(v);
        return null;
    };
    it.* = .{
        .keys = k,
        .values = v,
        .index = 0,
    };
    return it;
}

export fn djson_object_next(it: *ObjectIterator, key_out: *[*]const u8, len_out: *usize) callconv(.c) ?DjsonValue {
    if (it.index >= it.values.len) return null;
    const keys_slice = it.keys;
    const current_key = keys_slice[it.index];

    key_out.* = current_key.ptr;
    len_out.* = current_key.len;

    const val_ptr = &it.values[it.index];

    it.index += 1;
    return @constCast(val_ptr);
}

export fn djson_object_iter_free(it: *ObjectIterator) callconv(.c) void {
    allocator.free(it.keys);
    allocator.free(it.values);
    allocator.destroy(it);
}
