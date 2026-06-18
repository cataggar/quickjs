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

const utab = @import("unicode_table.zig").c;

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
    var idx_max: c_int = @as(c_int, @intCast(utab.case_conv_table1.len)) - 1;
    while (idx_min <= idx_max) {
        const idx: c_int = @intCast(@as(c_uint, @intCast(idx_max + idx_min)) / 2);
        const v = utab.case_conv_table1[@intCast(idx)];
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
        &utab.unicode_prop_Cased1_table,
        &utab.unicode_prop_Cased1_index,
        @intCast(utab.unicode_prop_Cased1_index.len / 3),
    ));
}

export fn lre_is_case_ignorable(c: u32) callconv(.c) c_int {
    return @intFromBool(lre_is_in_table(
        c,
        &utab.unicode_prop_Case_Ignorable_table,
        &utab.unicode_prop_Case_Ignorable_index,
        @intCast(utab.unicode_prop_Case_Ignorable_index.len / 3),
    ));
}

export fn lre_is_id_start(c: u32) callconv(.c) c_int {
    return @intFromBool(lre_is_in_table(
        c,
        &utab.unicode_prop_ID_Start_table,
        &utab.unicode_prop_ID_Start_index,
        @intCast(utab.unicode_prop_ID_Start_index.len / 3),
    ));
}

export fn lre_is_id_continue(c: u32) callconv(.c) c_int {
    if (lre_is_id_start(c) != 0) return 1;
    return @intFromBool(lre_is_in_table(
        c,
        &utab.unicode_prop_ID_Continue1_table,
        &utab.unicode_prop_ID_Continue1_index,
        @intCast(utab.unicode_prop_ID_Continue1_index.len / 3),
    ));
}
