const Document = @import("djson").Document;
const std = @import("std");

pub const DjsonHandle = *Document;

export fn djson_parse_buf(source_ptr: [*]const u8, len: usize) ?DjsonHandle {
    const source = source_ptr[0..len];
    const doc = try Document.parse(std.heap.page_allocator, source, null) catch return null;
    const res = std.heap.c_allocator.create(Document) catch return null;
    res.* = doc;
    return res;
}

export fn djson_free(handle: DjsonHandle) void {
    handle.deinit();
    std.heap.c_allocator.destroy(handle);
}

export fn djson_get_int(handle: DjsonHandle, path_ptr: [*]const u8, path_len: usize, out: *i64) ?i64 {
    const path = path_ptr[0..path_len];
    if (handle.root.getPath(path)) |v| {
        if (v == .int) {
            out.* = v.int;
            return true;
        }
    }
    return false;
}
