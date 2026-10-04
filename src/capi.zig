const std = @import("std");
const djson = @import("djson");
const Document = djson.Document;

pub const DjsonHandle = *Document;

const allocator = std.heap.wasm_allocator;

export fn alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn djson_parse_buf(source_ptr: [*]const u8, len: usize) ?DjsonHandle {
    const source = source_ptr[0..len];
    const doc = djson.parse(allocator, source, null) catch return null;
    const res = allocator.create(Document) catch return null;
    res.* = doc;
    return res;
}

export fn djson_free(handle: DjsonHandle) void {
    handle.deinit();
    allocator.destroy(handle);
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
