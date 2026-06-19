//! Unicode utilities — Zig port of libunicode.c (incremental).
//!
//! This first increment ports the self-contained CharRange set-algebra
//! functions (no dependency on the generated Unicode tables). They are
//! exported with the C ABI and match the prototypes in libunicode.h, so the
//! remaining C in libunicode.c / libregexp.c / quickjs.c link unchanged.

const std = @import("std");

extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn memcpy(noalias dest: ?*anyopaque, noalias src: ?*const anyopaque, n: usize) ?*anyopaque;
extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern "c" fn abort() callconv(.c) noreturn;

// DynBufReallocFunc from cutils.h: void *(*)(void *opaque, void *ptr, size_t size)
const DynBufReallocFunc = fn (opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

// Mirrors the C CharRange struct layout (libunicode.h).
const CharRange = extern struct {
    len: c_int, // in points, always even
    size: c_int,
    points: [*c]u32, // points sorted by increasing value
    mem_opaque: ?*anyopaque,
    realloc_func: ?*const DynBufReallocFunc,
};

// CharRangeOpEnum
const CR_OP_UNION: c_int = 0;
const CR_OP_INTER: c_int = 1;
const CR_OP_XOR: c_int = 2;
const CR_OP_SUB: c_int = 3;

fn cr_default_realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    _ = opaque_ptr;
    return realloc(ptr, size);
}

export fn cr_init(cr: *CharRange, mem_opaque: ?*anyopaque, realloc_func: ?*const DynBufReallocFunc) callconv(.c) void {
    cr.len = 0;
    cr.size = 0;
    cr.points = null;
    cr.mem_opaque = mem_opaque;
    cr.realloc_func = realloc_func orelse &cr_default_realloc;
}

export fn cr_free(cr: *CharRange) callconv(.c) void {
    _ = cr.realloc_func.?(cr.mem_opaque, @ptrCast(cr.points), 0);
}

export fn cr_realloc(cr: *CharRange, size: c_int) callconv(.c) c_int {
    if (size > cr.size) {
        const grow: c_int = @divTrunc(cr.size *% 3, 2); // cr->size * 3 / 2
        const new_size: c_int = if (size > grow) size else grow; // max_int
        const bytes: usize = @as(usize, @intCast(new_size)) * @sizeOf(u32);
        const new_buf = cr.realloc_func.?(cr.mem_opaque, @ptrCast(cr.points), bytes);
        if (new_buf == null) return -1;
        cr.points = @ptrCast(@alignCast(new_buf));
        cr.size = new_size;
    }
    return 0;
}

export fn cr_copy(cr: *CharRange, cr1: *const CharRange) callconv(.c) c_int {
    if (cr_realloc(cr, cr1.len) != 0) return -1;
    _ = memcpy(@ptrCast(cr.points), @ptrCast(cr1.points), @sizeOf(u32) * @as(usize, @intCast(cr1.len)));
    cr.len = cr1.len;
    return 0;
}

// static inline cr_add_point from libunicode.h, used by cr_op.
fn cr_add_point(cr: *CharRange, v: u32) c_int {
    if (cr.len >= cr.size) {
        if (cr_realloc(cr, cr.len + 1) != 0) return -1;
    }
    cr.points[@intCast(cr.len)] = v;
    cr.len += 1;
    return 0;
}

// merge consecutive intervals and remove empty intervals
fn cr_compress(cr: *CharRange) void {
    const pt = cr.points;
    const len = cr.len;
    var i: c_int = 0;
    var k: c_int = 0;
    while ((i + 1) < len) {
        if (pt[@intCast(i)] == pt[@intCast(i + 1)]) {
            // empty interval
            i += 2;
        } else {
            var j = i;
            while ((j + 3) < len and pt[@intCast(j + 1)] == pt[@intCast(j + 2)]) j += 2;
            // just copy
            pt[@intCast(k)] = pt[@intCast(i)];
            pt[@intCast(k + 1)] = pt[@intCast(j + 1)];
            k += 2;
            i = j + 2;
        }
    }
    cr.len = k;
}

// union or intersection
export fn cr_op(cr: *CharRange, a_pt: [*c]const u32, a_len: c_int, b_pt: [*c]const u32, b_len: c_int, op: c_int) callconv(.c) c_int {
    var a_idx: usize = 0;
    var b_idx: usize = 0;
    const a_n: usize = @intCast(a_len);
    const b_n: usize = @intCast(b_len);
    while (true) {
        // get one more point from a or b in increasing order
        var v: u32 = undefined;
        if (a_idx < a_n and b_idx < b_n) {
            if (a_pt[a_idx] < b_pt[b_idx]) {
                v = a_pt[a_idx];
                a_idx += 1;
            } else if (a_pt[a_idx] == b_pt[b_idx]) {
                v = a_pt[a_idx];
                a_idx += 1;
                b_idx += 1;
            } else {
                v = b_pt[b_idx];
                b_idx += 1;
            }
        } else if (a_idx < a_n) {
            v = a_pt[a_idx];
            a_idx += 1;
        } else if (b_idx < b_n) {
            v = b_pt[b_idx];
            b_idx += 1;
        } else {
            break;
        }
        // add the point if the in/out status changes
        const is_in: usize = switch (op) {
            CR_OP_UNION => (a_idx & 1) | (b_idx & 1),
            CR_OP_INTER => (a_idx & 1) & (b_idx & 1),
            CR_OP_XOR => (a_idx & 1) ^ (b_idx & 1),
            CR_OP_SUB => (a_idx & 1) & ((b_idx & 1) ^ 1),
            else => abort(),
        };
        if (is_in != @as(usize, @intCast(cr.len & 1))) {
            if (cr_add_point(cr, v) != 0) return -1;
        }
    }
    cr_compress(cr);
    return 0;
}

export fn cr_op1(cr: *CharRange, b_pt: [*c]const u32, b_len: c_int, op: c_int) callconv(.c) c_int {
    var a = cr.*;
    cr.len = 0;
    cr.size = 0;
    cr.points = null;
    const ret = cr_op(cr, a.points, a.len, b_pt, b_len, op);
    cr_free(&a);
    return ret;
}

export fn cr_invert(cr: *CharRange) callconv(.c) c_int {
    const len = cr.len;
    if (cr_realloc(cr, len + 2) != 0) return -1;
    _ = memmove(@ptrCast(cr.points + 1), @ptrCast(cr.points), @as(usize, @intCast(len)) * @sizeOf(u32));
    cr.points[0] = 0;
    cr.points[@intCast(len + 1)] = 0xFFFFFFFF; // UINT32_MAX
    cr.len = len + 2;
    cr_compress(cr);
    return 0;
}

// ---------------------------------------------------------------------------
// Table-driven property lookups (Unicode 17.0 tables via libunicode-table.h).
//
// get_le24 / get_index_pos / lre_is_in_table are private copies of the same
// static helpers in libunicode.c (those stay in C because many not-yet-ported
// C functions still use them).
// ---------------------------------------------------------------------------
// Generated Unicode tables (Unicode 17.0). Zig 0.17 removed @cImport, so they
// are accessed through external pointer symbols defined in libunicode.c.
extern const zig_case_conv_table1: [*]const u32;
extern const zig_case_conv_table1_len: c_int;
extern const zig_case_conv_table2: [*]const u8;
extern const zig_case_conv_ext: [*]const u16;
extern const zig_prop_Cased1_table: [*]const u8;
extern const zig_prop_Cased1_index: [*]const u8;
extern const zig_prop_Cased1_index_len: c_int;
extern const zig_prop_Case_Ignorable_table: [*]const u8;
extern const zig_prop_Case_Ignorable_index: [*]const u8;
extern const zig_prop_Case_Ignorable_index_len: c_int;
extern const zig_prop_ID_Start_table: [*]const u8;
extern const zig_prop_ID_Start_index: [*]const u8;
extern const zig_prop_ID_Start_index_len: c_int;
extern const zig_prop_ID_Continue1_table: [*]const u8;
extern const zig_prop_ID_Continue1_index: [*]const u8;
extern const zig_prop_ID_Continue1_index_len: c_int;

const UNICODE_INDEX_BLOCK_LEN: c_int = 32;

fn get_le24(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) | (@as(u32, ptr[1]) << 8) | (@as(u32, ptr[2]) << 16);
}

// return -1 if not in table, otherwise the offset in the block
fn get_index_pos(pcode: *u32, c: u32, index_table: [*]const u8, index_table_len: c_int) c_int {
    var idx_min: c_int = 0;
    var v = get_le24(index_table);
    var code = v & ((1 << 21) - 1);
    if (c < code) {
        pcode.* = 0;
        return 0;
    }
    var idx_max: c_int = index_table_len - 1;
    code = get_le24(index_table + @as(usize, @intCast(idx_max)) * 3);
    if (c >= code) return -1;
    // invariant: tab[idx_min] <= c < tab2[idx_max]
    while ((idx_max - idx_min) > 1) {
        const idx: c_int = @intCast(@as(c_uint, @intCast(idx_max + idx_min)) / 2);
        v = get_le24(index_table + @as(usize, @intCast(idx)) * 3);
        code = v & ((1 << 21) - 1);
        if (c < code) {
            idx_max = idx;
        } else {
            idx_min = idx;
        }
    }
    v = get_le24(index_table + @as(usize, @intCast(idx_min)) * 3);
    pcode.* = v & ((1 << 21) - 1);
    return (idx_min + 1) * UNICODE_INDEX_BLOCK_LEN + @as(c_int, @intCast(v >> 21));
}

fn lre_is_in_table(c: u32, table: [*]const u8, index_table: [*]const u8, index_table_len: c_int) bool {
    var code: u32 = undefined;
    const pos = get_index_pos(&code, c, index_table, index_table_len);
    if (pos < 0) return false; // outside the table
    var p = table + @as(usize, @intCast(pos));
    var bit: u32 = 0;
    // Compressed run length encoding; ranges alternate between false and true.
    while (true) {
        const b: u32 = p[0];
        p += 1;
        if (b < 64) {
            code += (b >> 3) + 1;
            if (c < code) return bit != 0;
            bit ^= 1;
            code += (b & 7) + 1;
        } else if (b >= 0x80) {
            code += b - 0x80 + 1;
        } else if (b < 0x60) {
            code += (((b - 0x40) << 8) | p[0]) + 1;
            p += 1;
        } else {
            code += (((b - 0x60) << 16) | (@as(u32, p[0]) << 8) | p[1]) + 1;
            p += 2;
        }
        if (c < code) return bit != 0;
        bit ^= 1;
    }
}

export fn lre_is_cased(c: u32) callconv(.c) c_int {
    var idx_min: c_int = 0;
    var idx_max: c_int = zig_case_conv_table1_len - 1;
    while (idx_min <= idx_max) {
        const idx: c_int = @intCast(@as(c_uint, @intCast(idx_max + idx_min)) / 2);
        const v = zig_case_conv_table1[@intCast(idx)];
        const code = v >> (32 - 17);
        const len = (v >> (32 - 17 - 7)) & 0x7f;
        if (c < code) {
            idx_max = idx - 1;
        } else if (c >= code + len) {
            idx_min = idx + 1;
        } else {
            return 1;
        }
    }
    return @intFromBool(lre_is_in_table(
        c,
        zig_prop_Cased1_table,
        zig_prop_Cased1_index,
        @divTrunc(zig_prop_Cased1_index_len, 3),
    ));
}

export fn lre_is_case_ignorable(c: u32) callconv(.c) c_int {
    return @intFromBool(lre_is_in_table(
        c,
        zig_prop_Case_Ignorable_table,
        zig_prop_Case_Ignorable_index,
        @divTrunc(zig_prop_Case_Ignorable_index_len, 3),
    ));
}

export fn lre_is_id_start(c: u32) callconv(.c) c_int {
    return @intFromBool(lre_is_in_table(
        c,
        zig_prop_ID_Start_table,
        zig_prop_ID_Start_index,
        @divTrunc(zig_prop_ID_Start_index_len, 3),
    ));
}

export fn lre_is_id_continue(c: u32) callconv(.c) c_int {
    if (lre_is_id_start(c) != 0) return 1;
    return @intFromBool(lre_is_in_table(
        c,
        zig_prop_ID_Continue1_table,
        zig_prop_ID_Continue1_index,
        @divTrunc(zig_prop_ID_Continue1_index_len, 3),
    ));
}

// ---------------------------------------------------------------------------
// Case conversion / canonicalization (lre_case_conv, lre_canonicalize).
//
// The exported entry points are ported here; the static helpers lre_case_conv1,
// lre_case_conv_entry and lre_case_folding_entry have private Zig copies (the C
// originals stay in libunicode.c, still used by cr_regexp_canonicalize).
// Tables: case_conv_table1 (u32), case_conv_table2 (u8), case_conv_ext (u16).
// ---------------------------------------------------------------------------

const LRE_CC_RES_LEN_MAX = 3;

// RUN_TYPE_* enum (libunicode.c)
const RUN_TYPE_U: u32 = 0;
const RUN_TYPE_L: u32 = 1;
const RUN_TYPE_UF: u32 = 2;
const RUN_TYPE_LF: u32 = 3;
const RUN_TYPE_UL: u32 = 4;
const RUN_TYPE_LSU: u32 = 5;
const RUN_TYPE_U2L_399_EXT2: u32 = 6;
const RUN_TYPE_UF_D20: u32 = 7;
const RUN_TYPE_UF_D1_EXT: u32 = 8;
const RUN_TYPE_U_EXT: u32 = 9;
const RUN_TYPE_LF_EXT: u32 = 10;
const RUN_TYPE_UF_EXT2: u32 = 11;
const RUN_TYPE_LF_EXT2: u32 = 12;
const RUN_TYPE_UF_EXT3: u32 = 13;

inline fn t1(i: u32) u32 {
    return zig_case_conv_table1[i];
}
inline fn t2(i: u32) u32 {
    return @as(u32, zig_case_conv_table2[i]);
}
inline fn ext(i: u32) u32 {
    return @as(u32, zig_case_conv_ext[i]);
}

fn lre_case_conv1(c: u32, conv_type: c_int) u32 {
    var res: [LRE_CC_RES_LEN_MAX]u32 = undefined;
    _ = lre_case_conv(&res, c, conv_type);
    return res[0];
}

// case conversion using the table entry 'idx' with value 'v'
fn lre_case_conv_entry(res: [*c]u32, c_in: u32, conv_type: c_int, idx: u32, v: u32) c_int {
    var c = c_in;
    const is_lower: u32 = if (conv_type != 0) 1 else 0;
    const typ: u32 = (v >> (32 - 17 - 7 - 4)) & 0xf;
    const data: u32 = ((v & 0xf) << 8) | t2(idx);
    const code: u32 = v >> (32 - 17);
    switch (typ) {
        RUN_TYPE_U, RUN_TYPE_L, RUN_TYPE_UF, RUN_TYPE_LF => {
            if (conv_type == @as(c_int, @intCast(typ & 1)) or
                (typ >= RUN_TYPE_UF and conv_type == 2))
            {
                c = c -% code +% (t1(data) >> (32 - 17));
            }
        },
        RUN_TYPE_UL => {
            const a = c -% code;
            if ((a & 1) == (1 -% is_lower)) {
                c = (a ^ 1) +% code;
            }
        },
        RUN_TYPE_LSU => {
            const a = c -% code;
            if (a == 1) {
                c = c +% (2 *% is_lower -% 1);
            } else if (a == (1 -% is_lower) *% 2) {
                c = c +% ((2 *% is_lower -% 1) *% 2);
            }
        },
        RUN_TYPE_U2L_399_EXT2 => {
            if (is_lower == 0) {
                res[0] = c -% code +% ext(data >> 6);
                res[1] = 0x399;
                return 2;
            } else {
                c = c -% code +% ext(data & 0x3f);
            }
        },
        RUN_TYPE_UF_D20 => {
            if (conv_type != 1) {
                c = data +% (if (conv_type == 2) @as(u32, 0x20) else 0);
            }
        },
        RUN_TYPE_UF_D1_EXT => {
            if (conv_type != 1) {
                c = ext(data) +% (if (conv_type == 2) @as(u32, 1) else 0);
            }
        },
        RUN_TYPE_U_EXT, RUN_TYPE_LF_EXT => {
            if (is_lower == (typ -% RUN_TYPE_U_EXT)) {
                c = ext(data);
            }
        },
        RUN_TYPE_LF_EXT2 => {
            if (is_lower != 0) {
                res[0] = c -% code +% ext(data >> 6);
                res[1] = ext(data & 0x3f);
                return 2;
            }
        },
        RUN_TYPE_UF_EXT2 => {
            if (conv_type != 1) {
                res[0] = c -% code +% ext(data >> 6);
                res[1] = ext(data & 0x3f);
                if (conv_type == 2) {
                    // convert to lower
                    res[0] = lre_case_conv1(res[0], 1);
                    res[1] = lre_case_conv1(res[1], 1);
                }
                return 2;
            }
        },
        // RUN_TYPE_UF_EXT3 shares the C 'default' body, so it falls to else.
        else => {
            if (conv_type != 1) {
                res[0] = ext(data >> 8);
                res[1] = ext((data >> 4) & 0xf);
                res[2] = ext(data & 0xf);
                if (conv_type == 2) {
                    // convert to lower
                    res[0] = lre_case_conv1(res[0], 1);
                    res[1] = lre_case_conv1(res[1], 1);
                    res[2] = lre_case_conv1(res[2], 1);
                }
                return 3;
            }
        },
    }
    res[0] = c;
    return 1;
}

// conv_type: 0 = to upper, 1 = to lower, 2 = case folding
export fn lre_case_conv(res: [*c]u32, c_in: u32, conv_type: c_int) callconv(.c) c_int {
    var c = c_in;
    if (c < 128) {
        if (conv_type != 0) {
            if (c >= 'A' and c <= 'Z') c = c - 'A' + 'a';
        } else {
            if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
        }
    } else {
        var idx_min: c_int = 0;
        var idx_max: c_int = zig_case_conv_table1_len - 1;
        while (idx_min <= idx_max) {
            const idx: c_int = @intCast(@as(c_uint, @intCast(idx_max + idx_min)) / 2);
            const v = t1(@intCast(idx));
            const code = v >> (32 - 17);
            const len = (v >> (32 - 17 - 7)) & 0x7f;
            if (c < code) {
                idx_max = idx - 1;
            } else if (c >= code + len) {
                idx_min = idx + 1;
            } else {
                return lre_case_conv_entry(res, c, conv_type, @intCast(idx), v);
            }
        }
    }
    res[0] = c;
    return 1;
}

fn lre_case_folding_entry(c_in: u32, idx: u32, v: u32, is_unicode: c_int) c_int {
    var c = c_in;
    var res: [LRE_CC_RES_LEN_MAX]u32 = undefined;
    if (is_unicode != 0) {
        const len = lre_case_conv_entry(&res, c, 2, idx, v);
        if (len == 1) {
            c = res[0];
        } else {
            // handle the few specific multi-character cases
            if (c == 0xfb06) {
                c = 0xfb05;
            } else if (c == 0x01fd3) {
                c = 0x390;
            } else if (c == 0x01fe3) {
                c = 0x3b0;
            }
        }
    } else {
        if (c < 128) {
            if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
        } else {
            // legacy regexp: to upper case if single char >= 128
            const len = lre_case_conv_entry(&res, c, 0, idx, v);
            if (len == 1 and res[0] >= 128) c = res[0];
        }
    }
    return @intCast(c);
}

// JS regexp specific rules for case folding
export fn lre_canonicalize(c_in: u32, is_unicode: c_int) callconv(.c) c_int {
    var c = c_in;
    if (c < 128) {
        // fast case
        if (is_unicode != 0) {
            if (c >= 'A' and c <= 'Z') c = c - 'A' + 'a';
        } else {
            if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
        }
    } else {
        var idx_min: c_int = 0;
        var idx_max: c_int = zig_case_conv_table1_len - 1;
        while (idx_min <= idx_max) {
            const idx: c_int = @intCast(@as(c_uint, @intCast(idx_max + idx_min)) / 2);
            const v = t1(@intCast(idx));
            const code = v >> (32 - 17);
            const len = (v >> (32 - 17 - 7)) & 0x7f;
            if (c < code) {
                idx_max = idx - 1;
            } else if (c >= code + len) {
                idx_min = idx + 1;
            } else {
                return lre_case_folding_entry(c, @intCast(idx), v, is_unicode);
            }
        }
    }
    return @intCast(c);
}

// ---------------------------------------------------------------------------
// lre_is_space_non_ascii — non-ASCII White_Space (Zs/Zl/Zp + BOM).
// ---------------------------------------------------------------------------

// code point ranges for Zs,Zl or Zp property
const char_range_s = [_]u16{
    10,
    0x0009, 0x000D + 1,
    0x0020, 0x0020 + 1,
    0x00A0, 0x00A0 + 1,
    0x1680, 0x1680 + 1,
    0x2000, 0x200A + 1,
    0x2028, 0x2029 + 1,
    0x202F, 0x202F + 1,
    0x205F, 0x205F + 1,
    0x3000, 0x3000 + 1,
    0xFEFF, 0xFEFF + 1,
};

export fn lre_is_space_non_ascii(c: u32) callconv(.c) c_int {
    const n = char_range_s.len;
    var i: usize = 5;
    while (i < n) : (i += 2) {
        const low: u32 = char_range_s[i];
        const high: u32 = char_range_s[i + 1];
        if (c < low) return 0;
        if (c < high) return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Unicode normalization (NFC/NFD/NFKC/NFKD): unicode_normalize and its private
// helpers. Tables: unicode_decomp_table1 (u32), unicode_decomp_table2 (u16),
// unicode_decomp_data (u8), unicode_comp_table (u16), unicode_cc_table/index.
// ---------------------------------------------------------------------------

const DynBuf = extern struct {
    buf: [*c]u8,
    size: usize,
    allocated_size: usize,
    err: c_int,
    realloc_func: ?*const DynBufReallocFunc,
    opaque_ptr: ?*anyopaque,
};

extern fn dbuf_init2(s: *DynBuf, opaque_ptr: ?*anyopaque, realloc_func: ?*const DynBufReallocFunc) callconv(.c) void;
extern fn dbuf_claim(s: *DynBuf, len: usize) callconv(.c) c_int;
extern fn __dbuf_put_u32(s: *DynBuf, val: u32) callconv(.c) c_int;

inline fn dbuf_put_u32(s: *DynBuf, val: u32) void {
    _ = __dbuf_put_u32(s, val);
}

const UNICODE_NFC: c_int = 0;
const UNICODE_DECOMP_LEN_MAX = 18;

// translate-c can't translate the larger generated tables, so they are reached
// through external pointer symbols defined in libunicode.c.
extern const zig_unicode_cc_table: [*]const u8;
extern const zig_unicode_cc_index: [*]const u8;
extern const zig_unicode_cc_index_len: c_int;
extern const zig_unicode_decomp_table1: [*]const u32;
extern const zig_unicode_decomp_table1_len: c_int;
extern const zig_unicode_decomp_table2: [*]const u16;
extern const zig_unicode_decomp_data: [*]const u8;
extern const zig_unicode_comp_table: [*]const u16;
extern const zig_unicode_comp_table_len: c_int;

// DecompTypeEnum
const DECOMP_TYPE_C1: u32 = 0;
const DECOMP_TYPE_L1: u32 = 1;
const DECOMP_TYPE_L2: u32 = 2;
const DECOMP_TYPE_L3: u32 = 3;
const DECOMP_TYPE_L4: u32 = 4;
const DECOMP_TYPE_L5: u32 = 5;
const DECOMP_TYPE_L6: u32 = 6;
const DECOMP_TYPE_L7: u32 = 7;
const DECOMP_TYPE_LL1: u32 = 8;
const DECOMP_TYPE_LL2: u32 = 9;
const DECOMP_TYPE_S1: u32 = 10;
const DECOMP_TYPE_S2: u32 = 11;
const DECOMP_TYPE_S3: u32 = 12;
const DECOMP_TYPE_S4: u32 = 13;
const DECOMP_TYPE_S5: u32 = 14;
const DECOMP_TYPE_I1: u32 = 15;
const DECOMP_TYPE_I2_0: u32 = 16;
const DECOMP_TYPE_I2_1: u32 = 17;
const DECOMP_TYPE_I3_1: u32 = 18;
const DECOMP_TYPE_I3_2: u32 = 19;
const DECOMP_TYPE_I4_1: u32 = 20;
const DECOMP_TYPE_I4_2: u32 = 21;
const DECOMP_TYPE_B1: u32 = 22;
const DECOMP_TYPE_B2: u32 = 23;
const DECOMP_TYPE_B3: u32 = 24;
const DECOMP_TYPE_B4: u32 = 25;
const DECOMP_TYPE_B5: u32 = 26;
const DECOMP_TYPE_B6: u32 = 27;
const DECOMP_TYPE_B7: u32 = 28;
const DECOMP_TYPE_B8: u32 = 29;
const DECOMP_TYPE_B18: u32 = 30;
const DECOMP_TYPE_LS2: u32 = 31;
const DECOMP_TYPE_PAT3: u32 = 32;
const DECOMP_TYPE_S2_UL: u32 = 33;
const DECOMP_TYPE_LS2_UL: u32 = 34;

fn unicode_get_short_code(c: u32) u32 {
    const unicode_short_table = [2]u16{ 0x2044, 0x2215 };
    if (c < 0x80) {
        return c;
    } else if (c < 0x80 + 0x50) {
        return c - 0x80 + 0x300;
    } else {
        return @as(u32, unicode_short_table[c - 0x80 - 0x50]);
    }
}

fn unicode_get_lower_simple(c_in: u32) u32 {
    var c = c_in;
    if (c < 0x100 or (c >= 0x410 and c <= 0x42f)) {
        c += 0x20;
    } else {
        c += 1;
    }
    return c;
}

fn unicode_get16(p: [*]const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8);
}

fn unicode_decomp_entry(res: [*c]u32, c_in: u32, idx: c_int, code: u32, len: u32, typ: u32) c_int {
    var c = c_in;
    if (typ == DECOMP_TYPE_C1) {
        res[0] = @as(u32, zig_unicode_decomp_table2[@intCast(idx)]);
        return 1;
    }
    const base: [*]const u8 = zig_unicode_decomp_data;
    var d = base + @as(usize, zig_unicode_decomp_table2[@intCast(idx)]);
    switch (typ) {
        DECOMP_TYPE_L1, DECOMP_TYPE_L2, DECOMP_TYPE_L3, DECOMP_TYPE_L4, DECOMP_TYPE_L5, DECOMP_TYPE_L6, DECOMP_TYPE_L7 => {
            const l = typ - DECOMP_TYPE_L1 + 1;
            d += @as(usize, (c - code) * l * 2);
            var i: u32 = 0;
            while (i < l) : (i += 1) {
                res[i] = unicode_get16(d + @as(usize, 2 * i));
                if (res[i] == 0) return 0;
            }
            return @intCast(l);
        },
        DECOMP_TYPE_LL1, DECOMP_TYPE_LL2 => {
            const l = typ - DECOMP_TYPE_LL1 + 1;
            var k: u32 = (c - code) * l;
            const p: u32 = len * l * 2;
            var i: u32 = 0;
            while (i < l) : (i += 1) {
                const shift: u3 = @intCast((k % 4) * 2);
                const byte_val: u8 = d[@as(usize, p + (k / 4))];
                const hi: u32 = (@as(u32, (byte_val >> shift) & 3) << 16);
                const c1 = unicode_get16(d + @as(usize, 2 * k)) | hi;
                if (c1 == 0) return 0;
                res[i] = c1;
                k += 1;
            }
            return @intCast(l);
        },
        DECOMP_TYPE_S1, DECOMP_TYPE_S2, DECOMP_TYPE_S3, DECOMP_TYPE_S4, DECOMP_TYPE_S5 => {
            const l = typ - DECOMP_TYPE_S1 + 1;
            d += @as(usize, (c - code) * l);
            var i: u32 = 0;
            while (i < l) : (i += 1) {
                res[i] = unicode_get_short_code(d[i]);
                if (res[i] == 0) return 0;
            }
            return @intCast(l);
        },
        DECOMP_TYPE_I1, DECOMP_TYPE_I2_0, DECOMP_TYPE_I2_1, DECOMP_TYPE_I3_1, DECOMP_TYPE_I3_2, DECOMP_TYPE_I4_1, DECOMP_TYPE_I4_2 => {
            var l: u32 = undefined;
            var p: u32 = undefined;
            if (typ == DECOMP_TYPE_I1) {
                l = 1;
                p = 0;
            } else {
                l = 2 + ((typ - DECOMP_TYPE_I2_0) >> 1);
                p = ((typ - DECOMP_TYPE_I2_0) & 1) + @intFromBool(l > 2);
            }
            var i: u32 = 0;
            while (i < l) : (i += 1) {
                var c1 = unicode_get16(d + @as(usize, 2 * i));
                if (i == p) c1 += c - code;
                res[i] = c1;
            }
            return @intCast(l);
        },
        DECOMP_TYPE_B1, DECOMP_TYPE_B2, DECOMP_TYPE_B3, DECOMP_TYPE_B4, DECOMP_TYPE_B5, DECOMP_TYPE_B6, DECOMP_TYPE_B7, DECOMP_TYPE_B8, DECOMP_TYPE_B18 => {
            const l: u32 = if (typ == DECOMP_TYPE_B18) 18 else (typ - DECOMP_TYPE_B1 + 1);
            const c_min = unicode_get16(d);
            d += @as(usize, 2 + (c - code) * l);
            var i: u32 = 0;
            while (i < l) : (i += 1) {
                var c1: u32 = d[i];
                if (c1 == 0xff) {
                    c1 = 0x20;
                } else {
                    c1 += c_min;
                }
                res[i] = c1;
            }
            return @intCast(l);
        },
        DECOMP_TYPE_LS2 => {
            d += @as(usize, (c - code) * 3);
            res[0] = unicode_get16(d);
            if (res[0] == 0) return 0;
            res[1] = unicode_get_short_code(d[2]);
            return 2;
        },
        DECOMP_TYPE_PAT3 => {
            res[0] = unicode_get16(d);
            res[2] = unicode_get16(d + 2);
            d += @as(usize, 4 + (c - code) * 2);
            res[1] = unicode_get16(d);
            return 3;
        },
        DECOMP_TYPE_S2_UL, DECOMP_TYPE_LS2_UL => {
            const c1 = c - code;
            if (typ == DECOMP_TYPE_S2_UL) {
                d += @as(usize, c1 & ~@as(u32, 1));
                c = unicode_get_short_code(d[0]);
                d += 1;
            } else {
                d += @as(usize, (c1 >> 1) * 3);
                c = unicode_get16(d);
                d += 2;
            }
            if ((c1 & 1) != 0) c = unicode_get_lower_simple(c);
            res[0] = c;
            res[1] = unicode_get_short_code(d[0]);
            return 2;
        },
        else => {},
    }
    return 0;
}

// return the length of the decomposition or 0 if no decomposition
fn unicode_decomp_char(res: [*c]u32, c: u32, is_compat1: c_int) c_int {
    var idx_min: c_int = 0;
    var idx_max: c_int = @as(c_int, @intCast(zig_unicode_decomp_table1_len)) - 1;
    while (idx_min <= idx_max) {
        const idx = @divTrunc(idx_max + idx_min, 2);
        const v = zig_unicode_decomp_table1[@intCast(idx)];
        const code = v >> (32 - 18);
        const len = (v >> (32 - 18 - 7)) & 0x7f;
        if (c < code) {
            idx_max = idx - 1;
        } else if (c >= code + len) {
            idx_min = idx + 1;
        } else {
            const is_compat = v & 1;
            if (@as(u32, @intCast(is_compat1)) < is_compat) break;
            const typ = (v >> (32 - 18 - 7 - 6)) & 0x3f;
            return unicode_decomp_entry(res, c, idx, code, len, typ);
        }
    }
    return 0;
}

// return 0 if no pair found
fn unicode_compose_pair(c0: u32, c1: u32) c_int {
    var idx_min: c_int = 0;
    var idx_max: c_int = @as(c_int, @intCast(zig_unicode_comp_table_len)) - 1;
    var pair: [2]u32 = undefined;
    while (idx_min <= idx_max) {
        const idx = @divTrunc(idx_max + idx_min, 2);
        const idx1: u32 = zig_unicode_comp_table[@intCast(idx)];
        // idx1 represents an entry of the decomposition table
        const d_idx = idx1 >> 6;
        const d_offset = idx1 & 0x3f;
        const v = zig_unicode_decomp_table1[d_idx];
        const code = v >> (32 - 18);
        const len = (v >> (32 - 18 - 7)) & 0x7f;
        const typ = (v >> (32 - 18 - 7 - 6)) & 0x3f;
        const ch = code + d_offset;
        _ = unicode_decomp_entry(&pair, ch, @intCast(d_idx), code, len, typ);
        var d: c_int = @as(c_int, @intCast(c0)) - @as(c_int, @intCast(pair[0]));
        if (d == 0) d = @as(c_int, @intCast(c1)) - @as(c_int, @intCast(pair[1]));
        if (d < 0) {
            idx_max = idx - 1;
        } else if (d > 0) {
            idx_min = idx + 1;
        } else {
            return @intCast(ch);
        }
    }
    return 0;
}

// return the combining class of character c (between 0 and 255)
fn unicode_get_cc(c: u32) c_int {
    var code: u32 = undefined;
    const pos = get_index_pos(&code, c, zig_unicode_cc_index, @divTrunc(zig_unicode_cc_index_len, 3));
    if (pos < 0) return 0;
    var p = zig_unicode_cc_table + @as(usize, @intCast(pos));
    while (true) {
        const b: u32 = p[0];
        p += 1;
        const typ = b >> 6;
        var n = b & 0x3f;
        if (n < 48) {
            // n unchanged
        } else if (n < 56) {
            n = (n - 48) << 8;
            n |= p[0];
            p += 1;
            n += 48;
        } else {
            n = (n - 56) << 8;
            n |= @as(u32, p[0]) << 8;
            p += 1;
            n |= p[0];
            p += 1;
            n += 48 + (1 << 11);
        }
        if (typ <= 1) p += 1;
        const c1 = code + n + 1;
        if (c < c1) {
            const cc: u32 = switch (typ) {
                0 => (p - 1)[0],
                1 => @as(u32, (p - 1)[0]) + c - code,
                2 => 0,
                else => 230,
            };
            return @intCast(cc);
        }
        code = c1;
    }
}

fn sort_cc(buf: [*c]c_int, len: c_int) void {
    var i: c_int = 0;
    while (i < len) : (i += 1) {
        const cc = unicode_get_cc(@bitCast(buf[@intCast(i)]));
        if (cc != 0) {
            const start = i;
            var j = i + 1;
            while (j < len) {
                const ch1 = buf[@intCast(j)];
                const cc1 = unicode_get_cc(@bitCast(ch1));
                if (cc1 == 0) break;
                var k = j - 1;
                while (k >= start) {
                    if (unicode_get_cc(@bitCast(buf[@intCast(k)])) <= cc1) break;
                    buf[@intCast(k + 1)] = buf[@intCast(k)];
                    k -= 1;
                }
                buf[@intCast(k + 1)] = ch1;
                j += 1;
            }
            i = j;
        }
    }
}

fn to_nfd_rec(dbuf: *DynBuf, src: [*c]const c_int, src_len: c_int, is_compat: c_int) void {
    var res: [UNICODE_DECOMP_LEN_MAX]u32 = undefined;
    var i: c_int = 0;
    while (i < src_len) : (i += 1) {
        var c: u32 = @bitCast(src[@intCast(i)]);
        if (c >= 0xac00 and c < 0xd7a4) {
            // Hangul decomposition
            c -= 0xac00;
            dbuf_put_u32(dbuf, 0x1100 + c / 588);
            dbuf_put_u32(dbuf, 0x1161 + (c % 588) / 28);
            const v = c % 28;
            if (v != 0) dbuf_put_u32(dbuf, 0x11a7 + v);
        } else {
            const l = unicode_decomp_char(&res, c, is_compat);
            if (l != 0) {
                to_nfd_rec(dbuf, @ptrCast(&res), l, is_compat);
            } else {
                dbuf_put_u32(dbuf, c);
            }
        }
    }
}

// return 0 if not found
fn compose_pair(c0: u32, c1: u32) c_int {
    // Hangul composition
    if (c0 >= 0x1100 and c0 < 0x1100 + 19 and c1 >= 0x1161 and c1 < 0x1161 + 21) {
        return @intCast(0xac00 + (c0 - 0x1100) * 588 + (c1 - 0x1161) * 28);
    } else if (c0 >= 0xac00 and c0 < 0xac00 + 11172 and (c0 - 0xac00) % 28 == 0 and
        c1 >= 0x11a7 and c1 < 0x11a7 + 28)
    {
        return @intCast(c0 + c1 - 0x11a7);
    } else {
        return unicode_compose_pair(c0, c1);
    }
}

export fn unicode_normalize(pdst: [*c][*c]u32, src: [*c]const u32, src_len: c_int, n_type: c_int, opaque_ptr: ?*anyopaque, realloc_func: ?*const DynBufReallocFunc) callconv(.c) c_int {
    const is_compat: c_int = n_type >> 1;
    var dbuf_s: DynBuf = undefined;
    const dbuf = &dbuf_s;

    dbuf_init2(dbuf, opaque_ptr, realloc_func);
    if (dbuf_claim(dbuf, @sizeOf(c_int) * @as(usize, @intCast(src_len))) != 0) {
        pdst.* = null;
        return -1;
    }

    // common case: latin1 is unaffected by NFC
    if (n_type == UNICODE_NFC) {
        var latin1 = true;
        var i: c_int = 0;
        while (i < src_len) : (i += 1) {
            if (src[@intCast(i)] >= 0x100) {
                latin1 = false;
                break;
            }
        }
        if (latin1) {
            const buf: [*c]c_int = @ptrCast(@alignCast(dbuf.buf));
            if (src_len != 0)
                _ = memcpy(@ptrCast(buf), @ptrCast(src), @as(usize, @intCast(src_len)) * @sizeOf(c_int));
            pdst.* = @ptrCast(buf);
            return src_len;
        }
    }

    to_nfd_rec(dbuf, @ptrCast(src), src_len, is_compat);
    if (dbuf.err != 0) {
        pdst.* = null;
        return -1;
    }
    const buf: [*c]c_int = @ptrCast(@alignCast(dbuf.buf));
    const buf_len: c_int = @intCast(dbuf.size / @sizeOf(c_int));

    sort_cc(buf, buf_len);

    if (buf_len <= 1 or (n_type & 1) != 0) {
        // NFD / NFKD
        pdst.* = @ptrCast(buf);
        return buf_len;
    }

    var i: c_int = 1;
    var out_len: c_int = 1;
    while (i < buf_len) {
        // find the starter character and test if it is blocked from buf[i]
        var last_cc = unicode_get_cc(@bitCast(buf[@intCast(i)]));
        var starter_pos = out_len - 1;
        var do_next = false;
        while (starter_pos >= 0) {
            const cc = unicode_get_cc(@bitCast(buf[@intCast(starter_pos)]));
            if (cc == 0) break;
            if (cc >= last_cc) {
                do_next = true;
                break;
            }
            last_cc = 256;
            starter_pos -= 1;
        }
        if (!do_next and starter_pos >= 0) {
            const p = compose_pair(@bitCast(buf[@intCast(starter_pos)]), @bitCast(buf[@intCast(i)]));
            if (p != 0) {
                buf[@intCast(starter_pos)] = p;
                i += 1;
                continue;
            }
        }
        // next:
        buf[@intCast(out_len)] = buf[@intCast(i)];
        out_len += 1;
        i += 1;
    }
    pdst.* = @ptrCast(buf);
    return out_len;
}

// ---------------------------------------------------------------------------
// Regexp case-folding CharRange construction: unicode_case1, point_cmp,
// cr_sort_and_remove_overlap, cr_regexp_canonicalize.
// ---------------------------------------------------------------------------

const CASE_U: c_int = 1;
const CASE_L: c_int = 2;
const CASE_F: c_int = 4;

const RqsortCmp = *const fn (a: ?*const anyopaque, b: ?*const anyopaque, arg: ?*anyopaque) callconv(.c) c_int;
extern fn rqsort(base: ?*anyopaque, nmemb: usize, size: usize, cmp: RqsortCmp, arg: ?*anyopaque) callconv(.c) void;

// static inline cr_add_interval from libunicode.h
fn cr_add_interval(cr: *CharRange, c1: u32, c2: u32) c_int {
    if ((cr.len + 2) > cr.size) {
        if (cr_realloc(cr, cr.len + 2) != 0) return -1;
    }
    cr.points[@intCast(cr.len)] = c1;
    cr.len += 1;
    cr.points[@intCast(cr.len)] = c2;
    cr.len += 1;
    return 0;
}

inline fn MR(rt: u32) u32 {
    return @as(u32, 1) << @as(u5, @intCast(rt));
}

export fn unicode_case1(cr: *CharRange, case_mask: c_int) callconv(.c) c_int {
    const tab_run_mask = [3]u32{
        MR(RUN_TYPE_U) | MR(RUN_TYPE_UF) | MR(RUN_TYPE_UL) | MR(RUN_TYPE_LSU) | MR(RUN_TYPE_U2L_399_EXT2) | MR(RUN_TYPE_UF_D20) | MR(RUN_TYPE_UF_D1_EXT) | MR(RUN_TYPE_U_EXT) | MR(RUN_TYPE_UF_EXT2) | MR(RUN_TYPE_UF_EXT3),
        MR(RUN_TYPE_L) | MR(RUN_TYPE_LF) | MR(RUN_TYPE_UL) | MR(RUN_TYPE_LSU) | MR(RUN_TYPE_U2L_399_EXT2) | MR(RUN_TYPE_LF_EXT) | MR(RUN_TYPE_LF_EXT2),
        MR(RUN_TYPE_UF) | MR(RUN_TYPE_LF) | MR(RUN_TYPE_UL) | MR(RUN_TYPE_LSU) | MR(RUN_TYPE_U2L_399_EXT2) | MR(RUN_TYPE_LF_EXT) | MR(RUN_TYPE_LF_EXT2) | MR(RUN_TYPE_UF_D20) | MR(RUN_TYPE_UF_D1_EXT) | MR(RUN_TYPE_LF_EXT) | MR(RUN_TYPE_UF_EXT2) | MR(RUN_TYPE_UF_EXT3),
    };
    if (case_mask == 0) return 0;
    var mask: u32 = 0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (((case_mask >> @as(u5, @intCast(i))) & 1) != 0) mask |= tab_run_mask[i];
    }
    var idx: u32 = 0;
    while (idx < @as(u32, @intCast(zig_case_conv_table1_len))) : (idx += 1) {
        const v = zig_case_conv_table1[idx];
        const typ = (v >> (32 - 17 - 7 - 4)) & 0xf;
        var code = v >> (32 - 17);
        const len = (v >> (32 - 17 - 7)) & 0x7f;
        if (((mask >> @as(u5, @intCast(typ))) & 1) != 0) {
            if (typ == RUN_TYPE_UL) {
                if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                    if (cr_add_interval(cr, code, code + len) != 0) return -1; // def_case
                } else {
                    code += @as(u32, @intFromBool((case_mask & CASE_U) != 0));
                    var j: u32 = 0;
                    while (j < len) : (j += 2) {
                        if (cr_add_interval(cr, code + j, code + j + 1) != 0) return -1;
                    }
                }
            } else if (typ == RUN_TYPE_LSU) {
                if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                    if (cr_add_interval(cr, code, code + len) != 0) return -1; // def_case
                } else {
                    if ((case_mask & CASE_U) == 0) {
                        if (cr_add_interval(cr, code, code + 1) != 0) return -1;
                    }
                    if (cr_add_interval(cr, code + 1, code + 2) != 0) return -1;
                    if ((case_mask & CASE_U) != 0) {
                        if (cr_add_interval(cr, code + 2, code + 3) != 0) return -1;
                    }
                }
            } else {
                if (cr_add_interval(cr, code, code + len) != 0) return -1;
            }
        }
    }
    return 0;
}

fn point_cmp(p1: ?*const anyopaque, p2: ?*const anyopaque, arg: ?*anyopaque) callconv(.c) c_int {
    _ = arg;
    const v1 = @as(*const u32, @ptrCast(@alignCast(p1))).*;
    const v2 = @as(*const u32, @ptrCast(@alignCast(p2))).*;
    return @as(c_int, @intFromBool(v1 > v2)) - @as(c_int, @intFromBool(v1 < v2));
}

fn cr_sort_and_remove_overlap(cr: *CharRange) void {
    // the resulting ranges are not necessarily sorted and may overlap
    rqsort(@ptrCast(cr.points), @intCast(@divTrunc(cr.len, 2)), @sizeOf(u32) * 2, &point_cmp, null);
    const len: u32 = @intCast(cr.len);
    var j: u32 = 0;
    var i: u32 = 0;
    while (i < len) {
        const start = cr.points[i];
        var end = cr.points[i + 1];
        i += 2;
        while (i < len) {
            const start1 = cr.points[i];
            const end1 = cr.points[i + 1];
            if (start1 > end) {
                break;
            } else if (end1 <= end) {
                i += 2;
            } else {
                end = end1;
                i += 2;
            }
        }
        cr.points[j] = start;
        cr.points[j + 1] = end;
        j += 2;
    }
    cr.len = @intCast(j);
}

// canonicalize a character set using the JS regex case folding rules
export fn cr_regexp_canonicalize(cr: *CharRange, is_unicode: c_int) callconv(.c) c_int {
    var cr_inter: CharRange = undefined;
    var cr_mask: CharRange = undefined;
    var cr_result: CharRange = undefined;
    var cr_sub: CharRange = undefined;

    cr_init(&cr_mask, cr.mem_opaque, cr.realloc_func);
    cr_init(&cr_inter, cr.mem_opaque, cr.realloc_func);
    cr_init(&cr_result, cr.mem_opaque, cr.realloc_func);
    cr_init(&cr_sub, cr.mem_opaque, cr.realloc_func);

    var ok = false;
    blk: {
        if (unicode_case1(&cr_mask, if (is_unicode != 0) CASE_F else CASE_U) != 0) break :blk;
        if (cr_op(&cr_inter, cr_mask.points, cr_mask.len, cr.points, cr.len, CR_OP_INTER) != 0) break :blk;

        if (cr_invert(&cr_mask) != 0) break :blk;
        if (cr_op(&cr_sub, cr_mask.points, cr_mask.len, cr.points, cr.len, CR_OP_INTER) != 0) break :blk;

        // cr_inter = cr & cr_mask ; cr_sub = cr & ~cr_mask
        // use the case conversion table to compute the result
        var d_start: u32 = 0xFFFFFFFF; // -1
        var d_end: u32 = 0xFFFFFFFF;
        var idx: u32 = 0;
        var v = zig_case_conv_table1[idx];
        var code = v >> (32 - 17);
        var len = (v >> (32 - 17 - 7)) & 0x7f;
        var i: u32 = 0;
        const inter_len: u32 = @intCast(cr_inter.len);
        while (i < inter_len) : (i += 2) {
            const start = cr_inter.points[i];
            const end = cr_inter.points[i + 1];
            var c = start;
            while (c < end) : (c += 1) {
                while (true) {
                    if (c >= code and c < code + len) break;
                    idx += 1;
                    v = zig_case_conv_table1[idx];
                    code = v >> (32 - 17);
                    len = (v >> (32 - 17 - 7)) & 0x7f;
                }
                const d: u32 = @intCast(lre_case_folding_entry(c, idx, v, is_unicode));
                // try to merge with the current interval
                if (d_start == 0xFFFFFFFF) {
                    d_start = d;
                    d_end = d + 1;
                } else if (d_end == d) {
                    d_end += 1;
                } else {
                    _ = cr_add_interval(&cr_result, d_start, d_end);
                    d_start = d;
                    d_end = d + 1;
                }
            }
        }
        if (d_start != 0xFFFFFFFF) {
            if (cr_add_interval(&cr_result, d_start, d_end) != 0) break :blk;
        }

        // the resulting ranges are not necessarily sorted and may overlap
        cr_sort_and_remove_overlap(&cr_result);

        // or with the characters not affected by the case folding
        cr.len = 0;
        if (cr_op(cr, cr_result.points, cr_result.len, cr_sub.points, cr_sub.len, CR_OP_UNION) != 0) break :blk;
        ok = true;
    }
    cr_free(&cr_inter);
    cr_free(&cr_mask);
    cr_free(&cr_result);
    cr_free(&cr_sub);
    return if (ok) 0 else -1;
}
