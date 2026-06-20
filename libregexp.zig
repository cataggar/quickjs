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

// ---------------------------------------------------------------------------
// lre_parse_escape — parse a regexp/string escape after the backslash.
// Private copies of the cutils.h inline helpers it needs.
// ---------------------------------------------------------------------------

inline fn from_hex(c: u32) c_int {
    if (c >= '0' and c <= '9') {
        return @intCast(c - '0');
    } else if (c >= 'A' and c <= 'F') {
        return @intCast(c - 'A' + 10);
    } else if (c >= 'a' and c <= 'f') {
        return @intCast(c - 'a' + 10);
    } else {
        return -1;
    }
}

inline fn is_digit(c: u32) bool {
    return c >= '0' and c <= '9';
}

inline fn is_hi_surrogate(c: u32) bool {
    return (c >> 10) == (0xD800 >> 10);
}

inline fn is_lo_surrogate(c: u32) bool {
    return (c >> 10) == (0xDC00 >> 10);
}

inline fn from_surrogate(hi: u32, lo: u32) u32 {
    return 0x10000 + 0x400 * (hi - 0xD800) + (lo - 0xDC00);
}

// Parse an escape sequence, *pp points after the '\'.
//   allow_utf16: 0 none, 1 UTF-16 escapes, 2 also convert surrogate pairs.
// Return the unicode char and update *pp, -1 if malformed, -2 otherwise.
export fn lre_parse_escape(pp: [*c][*c]const u8, allow_utf16: c_int) callconv(.c) c_int {
    var p = pp[0];
    var c: u32 = p[0];
    p += 1;
    switch (c) {
        'b' => c = 0x08,
        'f' => c = 0x0c,
        'n' => c = 0x0a,
        'r' => c = 0x0d,
        't' => c = 0x09,
        'v' => c = 0x0b,
        'x' => {
            const h0 = from_hex(p[0]);
            p += 1;
            if (h0 < 0) return -1;
            const h1 = from_hex(p[0]);
            p += 1;
            if (h1 < 0) return -1;
            c = @intCast((h0 << 4) | h1);
        },
        'u' => {
            if (p[0] == '{' and allow_utf16 != 0) {
                p += 1;
                c = 0;
                while (true) {
                    const h = from_hex(p[0]);
                    p += 1;
                    if (h < 0) return -1;
                    c = (c << 4) | @as(u32, @intCast(h));
                    if (c > 0x10FFFF) return -1;
                    if (p[0] == '}') break;
                }
                p += 1;
            } else {
                c = 0;
                var i: c_int = 0;
                while (i < 4) : (i += 1) {
                    const h = from_hex(p[0]);
                    p += 1;
                    if (h < 0) return -1;
                    c = (c << 4) | @as(u32, @intCast(h));
                }
                if (is_hi_surrogate(c) and allow_utf16 == 2 and p[0] == '\\' and p[1] == 'u') {
                    // convert an escaped surrogate pair into a unicode char
                    var c1: u32 = 0;
                    var k: c_int = 0;
                    while (k < 4) : (k += 1) {
                        const h = from_hex(p[@intCast(2 + k)]);
                        if (h < 0) break;
                        c1 = (c1 << 4) | @as(u32, @intCast(h));
                    }
                    if (k == 4 and is_lo_surrogate(c1)) {
                        p += 6;
                        c = from_surrogate(c, c1);
                    }
                }
            }
        },
        '0'...'7' => {
            c -= '0';
            if (allow_utf16 == 2) {
                // only accept \0 not followed by digit
                if (c != 0 or is_digit(p[0])) return -1;
            } else {
                // parse a legacy octal sequence
                oct: {
                    var v: u32 = @as(u32, p[0]) -% '0';
                    if (v > 7) break :oct;
                    c = (c << 3) | v;
                    p += 1;
                    if (c >= 32) break :oct;
                    v = @as(u32, p[0]) -% '0';
                    if (v > 7) break :oct;
                    c = (c << 3) | v;
                    p += 1;
                }
            }
        },
        else => return -2,
    }
    pp[0] = p;
    return @intCast(c);
}
