//! Regular expression engine — Zig port of libregexp.c (incremental).
//!
//! Exported with the C ABI to match the prototypes in libregexp.h, so the
//! remaining C in libregexp.c links against them unchanged.
//!
//! First increment: the compiled-bytecode header accessors.

// Compiled bytecode header layout (libregexp.c).
const RE_HEADER_FLAGS = 0;
const RE_HEADER_CAPTURE_COUNT = 2;
const RE_HEADER_REGISTER_COUNT = 3;
const RE_HEADER_BYTECODE_LEN = 4;
const RE_HEADER_LEN = 8;

const LRE_FLAG_NAMED_GROUPS: c_int = 1 << 7;

inline fn get_u16(p: [*c]const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8);
}

inline fn get_u32(p: [*c]const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) |
        (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

export fn lre_get_alloc_count(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @as(c_int, bc_buf[RE_HEADER_CAPTURE_COUNT]) * 2 +
        @as(c_int, bc_buf[RE_HEADER_REGISTER_COUNT]);
}

export fn lre_get_capture_count(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @as(c_int, bc_buf[RE_HEADER_CAPTURE_COUNT]);
}

export fn lre_get_flags(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @intCast(get_u16(bc_buf + RE_HEADER_FLAGS));
}

// Return NULL if no group names. Otherwise, return a pointer to
// 'capture_count - 1' zero terminated UTF-8 strings.
export fn lre_get_groupnames(bc_buf: [*c]const u8) callconv(.c) [*c]const u8 {
    if ((lre_get_flags(bc_buf) & LRE_FLAG_NAMED_GROUPS) == 0)
        return null;
    const re_bytecode_len = get_u32(bc_buf + RE_HEADER_BYTECODE_LEN);
    return bc_buf + RE_HEADER_LEN + re_bytecode_len;
}
