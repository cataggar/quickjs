//! C utilities — Zig port of cutils.c (incremental).
//!
//! These functions are exported with the C ABI and match the prototypes in
//! cutils.h, so the remaining C translation units link against them unchanged.
//!
//! Still implemented in cutils.c (ported in a later increment):
//!   - dbuf_printf  (C varargs; @cVaStart is disabled in Zig 0.16)
//!   - rqsort       (and its static helpers)

const std = @import("std");

extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn memcpy(noalias dest: ?*anyopaque, noalias src: ?*const anyopaque, n: usize) ?*anyopaque;
extern "c" fn memset(dest: ?*anyopaque, c: c_int, n: usize) ?*anyopaque;
extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
extern "c" fn strlen(s: [*c]const u8) usize;

const TRUE: c_int = 1;

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

export fn pstrcpy(buf: [*c]u8, buf_size: c_int, str: [*c]const u8) callconv(.c) void {
    if (buf_size <= 0) return;
    const size: usize = @intCast(buf_size);
    var i: usize = 0;
    var si: usize = 0;
    while (true) {
        const ch = str[si];
        si += 1;
        if (ch == 0 or i >= size - 1) break;
        buf[i] = ch;
        i += 1;
    }
    buf[i] = 0;
}

// strcat and truncate.
export fn pstrcat(buf: [*c]u8, buf_size: c_int, s: [*c]const u8) callconv(.c) [*c]u8 {
    const len: c_int = @intCast(strlen(buf));
    if (len < buf_size) {
        pstrcpy(buf + @as(usize, @intCast(len)), buf_size - len, s);
    }
    return buf;
}

export fn strstart(str: [*c]const u8, val: [*c]const u8, ptr: [*c][*c]const u8) callconv(.c) c_int {
    var p = str;
    var q = val;
    while (q[0] != 0) {
        if (p[0] != q[0]) return 0;
        p += 1;
        q += 1;
    }
    if (ptr != null) ptr[0] = p;
    return 1;
}

export fn has_suffix(str: [*c]const u8, suffix: [*c]const u8) callconv(.c) c_int {
    const len = strlen(str);
    const slen = strlen(suffix);
    if (len >= slen and memcmp(@ptrCast(str + (len - slen)), @ptrCast(suffix), slen) == 0)
        return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// Dynamic buffer
// ---------------------------------------------------------------------------

const DynBufReallocFunc = fn (opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

const DynBuf = extern struct {
    buf: [*c]u8,
    size: usize,
    allocated_size: usize,
    err: c_int,
    realloc_func: ?*const DynBufReallocFunc,
    opaque_ptr: ?*anyopaque,
};

fn dbuf_default_realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    _ = opaque_ptr;
    return realloc(ptr, size);
}

export fn dbuf_init2(s: *DynBuf, opaque_ptr: ?*anyopaque, realloc_func: ?*const DynBufReallocFunc) callconv(.c) void {
    _ = memset(@ptrCast(s), 0, @sizeOf(DynBuf));
    s.realloc_func = realloc_func orelse &dbuf_default_realloc;
    s.opaque_ptr = opaque_ptr;
}

export fn dbuf_init(s: *DynBuf) callconv(.c) void {
    dbuf_init2(s, null, null);
}

// Try to allocate 'len' more bytes. return < 0 if error.
export fn dbuf_claim(s: *DynBuf, len: usize) callconv(.c) c_int {
    var new_size = s.size +% len;
    if (new_size < len) return -1; // overflow case
    if (new_size > s.allocated_size) {
        if (s.err != 0) return -1;
        const size = s.allocated_size +% (s.allocated_size / 2);
        if (size < s.allocated_size) return -1; // overflow case
        if (size > new_size) new_size = size;
        const new_buf = s.realloc_func.?(s.opaque_ptr, s.buf, new_size);
        if (new_buf == null) {
            s.err = TRUE;
            return -1;
        }
        s.buf = @ptrCast(new_buf);
        s.allocated_size = new_size;
    }
    return 0;
}

export fn dbuf_put(s: *DynBuf, data: [*c]const u8, len: usize) callconv(.c) c_int {
    if ((s.allocated_size - s.size) < len) {
        if (dbuf_claim(s, len) != 0) return -1;
    }
    if (len != 0) _ = memcpy(@ptrCast(s.buf + s.size), @ptrCast(data), len);
    s.size += len;
    return 0;
}

export fn dbuf_put_self(s: *DynBuf, offset: usize, len: usize) callconv(.c) c_int {
    if ((s.allocated_size - s.size) < len) {
        if (dbuf_claim(s, len) != 0) return -1;
    }
    _ = memcpy(@ptrCast(s.buf + s.size), @ptrCast(s.buf + offset), len);
    s.size += len;
    return 0;
}

export fn __dbuf_putc(s: *DynBuf, c: u8) callconv(.c) c_int {
    var v = c;
    return dbuf_put(s, @ptrCast(&v), 1);
}

export fn __dbuf_put_u16(s: *DynBuf, val: u16) callconv(.c) c_int {
    var v = val;
    return dbuf_put(s, @ptrCast(&v), 2);
}

export fn __dbuf_put_u32(s: *DynBuf, val: u32) callconv(.c) c_int {
    var v = val;
    return dbuf_put(s, @ptrCast(&v), 4);
}

export fn __dbuf_put_u64(s: *DynBuf, val: u64) callconv(.c) c_int {
    var v = val;
    return dbuf_put(s, @ptrCast(&v), 8);
}

export fn dbuf_putstr(s: *DynBuf, str: [*c]const u8) callconv(.c) c_int {
    return dbuf_put(s, str, strlen(str));
}

export fn dbuf_free(s: *DynBuf) callconv(.c) void {
    // we test s->buf as a fail safe to avoid crashing if dbuf_free()
    // is called twice
    if (s.buf != null) {
        _ = s.realloc_func.?(s.opaque_ptr, s.buf, 0);
    }
    _ = memset(@ptrCast(s), 0, @sizeOf(DynBuf));
}

// ---------------------------------------------------------------------------
// UTF-8
// ---------------------------------------------------------------------------

// Note: at most 31 bits are encoded. At most UTF8_CHAR_LEN_MAX bytes are output.
export fn unicode_to_utf8(buf: [*c]u8, c: c_uint) callconv(.c) c_int {
    var i: usize = 0;
    if (c < 0x80) {
        buf[i] = @truncate(c);
        i += 1;
    } else {
        if (c < 0x800) {
            buf[i] = @truncate((c >> 6) | 0xc0);
            i += 1;
        } else {
            if (c < 0x10000) {
                buf[i] = @truncate((c >> 12) | 0xe0);
                i += 1;
            } else {
                if (c < 0x00200000) {
                    buf[i] = @truncate((c >> 18) | 0xf0);
                    i += 1;
                } else {
                    if (c < 0x04000000) {
                        buf[i] = @truncate((c >> 24) | 0xf8);
                        i += 1;
                    } else if (c < 0x80000000) {
                        buf[i] = @truncate((c >> 30) | 0xfc);
                        i += 1;
                        buf[i] = @truncate(((c >> 24) & 0x3f) | 0x80);
                        i += 1;
                    } else {
                        return 0;
                    }
                    buf[i] = @truncate(((c >> 18) & 0x3f) | 0x80);
                    i += 1;
                }
                buf[i] = @truncate(((c >> 12) & 0x3f) | 0x80);
                i += 1;
            }
            buf[i] = @truncate(((c >> 6) & 0x3f) | 0x80);
            i += 1;
        }
        buf[i] = @truncate((c & 0x3f) | 0x80);
        i += 1;
    }
    return @intCast(i);
}

const utf8_min_code = [5]c_uint{ 0x80, 0x800, 0x10000, 0x00200000, 0x04000000 };
const utf8_first_code_mask = [5]u8{ 0x1f, 0xf, 0x7, 0x3, 0x1 };

// return -1 if error. *pp is not updated in this case. max_len must
// be >= 1. The maximum length for a UTF8 byte sequence is 6 bytes.
export fn unicode_from_utf8(p_in: [*c]const u8, max_len: c_int, pp: [*c][*c]const u8) callconv(.c) c_int {
    var p = p_in;
    var c: c_int = p[0];
    p += 1;
    if (c < 0x80) {
        pp[0] = p;
        return c;
    }
    const l: c_int = switch (c) {
        0xc0...0xdf => 1,
        0xe0...0xef => 2,
        0xf0...0xf7 => 3,
        0xf8...0xfb => 4,
        0xfc...0xfd => 5,
        else => return -1,
    };
    // check that we have enough characters
    if (l > (max_len - 1)) return -1;
    const idx: usize = @intCast(l - 1);
    c &= @as(c_int, utf8_first_code_mask[idx]);
    var i: c_int = 0;
    while (i < l) : (i += 1) {
        const b: c_int = p[0];
        p += 1;
        if (b < 0x80 or b >= 0xc0) return -1;
        c = (c << 6) | (b & 0x3f);
    }
    if (@as(c_uint, @intCast(c)) < utf8_min_code[idx]) return -1;
    pp[0] = p;
    return c;
}

// ---------------------------------------------------------------------------
// rqsort — reentrant quicksort with median-of-3, 3-way partition, heapsort
// fallback and an insertion-sort threshold. Port of the C implementation.
// ---------------------------------------------------------------------------

const ExchangeFn = *const fn (a: ?*anyopaque, b: ?*anyopaque, size: usize) void;
const CmpFn = *const fn (a: ?*const anyopaque, b: ?*const anyopaque, opaque_ptr: ?*anyopaque) callconv(.c) c_int;

fn exchange_bytes(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    var ap: [*]u8 = @ptrCast(a);
    var bp: [*]u8 = @ptrCast(b);
    var n = size;
    while (n != 0) : (n -= 1) {
        const t = ap[0];
        ap[0] = bp[0];
        bp[0] = t;
        ap += 1;
        bp += 1;
    }
}

fn exchange_one_byte(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    _ = size;
    const ap: [*]u8 = @ptrCast(a);
    const bp: [*]u8 = @ptrCast(b);
    const t = ap[0];
    ap[0] = bp[0];
    bp[0] = t;
}

fn exchange_int16s(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    var ap: [*]u16 = @ptrCast(@alignCast(a));
    var bp: [*]u16 = @ptrCast(@alignCast(b));
    var n = size / @sizeOf(u16);
    while (n != 0) : (n -= 1) {
        const t = ap[0];
        ap[0] = bp[0];
        bp[0] = t;
        ap += 1;
        bp += 1;
    }
}

fn exchange_one_int16(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    _ = size;
    const ap: [*]u16 = @ptrCast(@alignCast(a));
    const bp: [*]u16 = @ptrCast(@alignCast(b));
    const t = ap[0];
    ap[0] = bp[0];
    bp[0] = t;
}

fn exchange_int32s(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    var ap: [*]u32 = @ptrCast(@alignCast(a));
    var bp: [*]u32 = @ptrCast(@alignCast(b));
    var n = size / @sizeOf(u32);
    while (n != 0) : (n -= 1) {
        const t = ap[0];
        ap[0] = bp[0];
        bp[0] = t;
        ap += 1;
        bp += 1;
    }
}

fn exchange_one_int32(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    _ = size;
    const ap: [*]u32 = @ptrCast(@alignCast(a));
    const bp: [*]u32 = @ptrCast(@alignCast(b));
    const t = ap[0];
    ap[0] = bp[0];
    bp[0] = t;
}

fn exchange_int64s(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    var ap: [*]u64 = @ptrCast(@alignCast(a));
    var bp: [*]u64 = @ptrCast(@alignCast(b));
    var n = size / @sizeOf(u64);
    while (n != 0) : (n -= 1) {
        const t = ap[0];
        ap[0] = bp[0];
        bp[0] = t;
        ap += 1;
        bp += 1;
    }
}

fn exchange_one_int64(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    _ = size;
    const ap: [*]u64 = @ptrCast(@alignCast(a));
    const bp: [*]u64 = @ptrCast(@alignCast(b));
    const t = ap[0];
    ap[0] = bp[0];
    bp[0] = t;
}

fn exchange_int128s(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    var ap: [*]u64 = @ptrCast(@alignCast(a));
    var bp: [*]u64 = @ptrCast(@alignCast(b));
    var n = size / (@sizeOf(u64) * 2);
    while (n != 0) : (n -= 1) {
        const t = ap[0];
        const u = ap[1];
        ap[0] = bp[0];
        ap[1] = bp[1];
        bp[0] = t;
        bp[1] = u;
        ap += 2;
        bp += 2;
    }
}

fn exchange_one_int128(a: ?*anyopaque, b: ?*anyopaque, size: usize) void {
    _ = size;
    const ap: [*]u64 = @ptrCast(@alignCast(a));
    const bp: [*]u64 = @ptrCast(@alignCast(b));
    const t = ap[0];
    const u = ap[1];
    ap[0] = bp[0];
    ap[1] = bp[1];
    bp[0] = t;
    bp[1] = u;
}

fn exchange_func(base_addr: usize, size: usize) ExchangeFn {
    return switch ((base_addr | size) & 15) {
        0 => if (size == @sizeOf(u64) * 2) &exchange_one_int128 else &exchange_int128s,
        8 => if (size == @sizeOf(u64)) &exchange_one_int64 else &exchange_int64s,
        4, 12 => if (size == @sizeOf(u32)) &exchange_one_int32 else &exchange_int32s,
        2, 6, 10, 14 => if (size == @sizeOf(u16)) &exchange_one_int16 else &exchange_int16s,
        else => if (size == 1) &exchange_one_byte else &exchange_bytes,
    };
}

inline fn cmpAt(cmp: CmpFn, a: [*]u8, b: [*]u8, opaque_ptr: ?*anyopaque) c_int {
    return cmp(@ptrCast(a), @ptrCast(b), opaque_ptr);
}

fn heapsortx(base: [*]u8, nmemb: usize, size: usize, cmp: CmpFn, opaque_ptr: ?*anyopaque) void {
    const swap = exchange_func(@intFromPtr(base), size);
    if (nmemb <= 1) return;

    var i: usize = (nmemb / 2) * size;
    const n: usize = nmemb * size;

    while (i > 0) {
        i -= size;
        var r = i;
        var c = r * 2 + size;
        while (c < n) : (c = r * 2 + size) {
            if (c < n - size and cmpAt(cmp, base + c, base + c + size, opaque_ptr) <= 0)
                c += size;
            if (cmpAt(cmp, base + r, base + c, opaque_ptr) > 0) break;
            swap(@ptrCast(base + r), @ptrCast(base + c), size);
            r = c;
        }
    }
    i = n - size;
    while (i > 0) : (i -= size) {
        swap(@ptrCast(base), @ptrCast(base + i), size);
        var r: usize = 0;
        var c = r * 2 + size;
        while (c < i) : (c = r * 2 + size) {
            if (c < i - size and cmpAt(cmp, base + c, base + c + size, opaque_ptr) <= 0)
                c += size;
            if (cmpAt(cmp, base + r, base + c, opaque_ptr) > 0) break;
            swap(@ptrCast(base + r), @ptrCast(base + c), size);
            r = c;
        }
    }
}

fn med3(a: [*]u8, b: [*]u8, c: [*]u8, cmp: CmpFn, opaque_ptr: ?*anyopaque) [*]u8 {
    return if (cmpAt(cmp, a, b, opaque_ptr) < 0)
        (if (cmpAt(cmp, b, c, opaque_ptr) < 0) b else (if (cmpAt(cmp, a, c, opaque_ptr) < 0) c else a))
    else
        (if (cmpAt(cmp, b, c, opaque_ptr) > 0) b else (if (cmpAt(cmp, a, c, opaque_ptr) < 0) a else c));
}

const StackEnt = struct { base: [*]u8, count: usize, depth: c_int };

// pointer based version with local stack and insertion sort threshold
export fn rqsort(base: ?*anyopaque, nmemb_in: usize, size: usize, cmp: CmpFn, opaque_ptr: ?*anyopaque) callconv(.c) void {
    var stack: [50]StackEnt = undefined;
    var sp: usize = 0;

    if (nmemb_in < 2 or size == 0) return;

    const basep: [*]u8 = @ptrCast(base);
    const swap = exchange_func(@intFromPtr(basep), size);
    const swap_block = exchange_func(@intFromPtr(basep), size | 128);

    stack[sp] = .{ .base = basep, .count = nmemb_in, .depth = 0 };
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        var ptr = stack[sp].base;
        var nmemb = stack[sp].count;
        var depth = stack[sp].depth;

        while (nmemb > 6) {
            depth += 1;
            if (depth > 50) {
                // depth check to ensure worst case logarithmic time
                heapsortx(ptr, nmemb, size, cmp, opaque_ptr);
                nmemb = 0;
                break;
            }
            // select median of 3 from 1/4, 1/2, 3/4 positions
            const m4 = (nmemb >> 2) * size;
            const m = med3(ptr + m4, ptr + 2 * m4, ptr + 3 * m4, cmp, opaque_ptr);
            swap(@ptrCast(ptr), @ptrCast(m), size); // move the pivot to the start of the array
            var i: usize = 1;
            var lt: usize = 1;
            var pi = ptr + size;
            var plt = ptr + size;
            var gt = nmemb;
            const top = ptr + nmemb * size;
            var pj = top;
            var pgt = top;
            while (true) {
                while (@intFromPtr(pi) < @intFromPtr(pj)) {
                    const c = cmpAt(cmp, ptr, pi, opaque_ptr);
                    if (c < 0) break;
                    if (c == 0) {
                        swap(@ptrCast(plt), @ptrCast(pi), size);
                        lt += 1;
                        plt += size;
                    }
                    i += 1;
                    pi += size;
                }
                while (true) {
                    pj -= size;
                    if (!(@intFromPtr(pi) < @intFromPtr(pj))) break;
                    const c = cmpAt(cmp, ptr, pj, opaque_ptr);
                    if (c > 0) break;
                    if (c == 0) {
                        gt -= 1;
                        pgt -= size;
                        swap(@ptrCast(pgt), @ptrCast(pj), size);
                    }
                }
                if (@intFromPtr(pi) >= @intFromPtr(pj)) break;
                swap(@ptrCast(pi), @ptrCast(pj), size);
                i += 1;
                pi += size;
            }
            // array has 4 parts:
            //  [0, lt)      : elements identical to pivot
            //  [lt, pi)     : elements smaller than pivot
            //  [pi, gt)     : elements greater than pivot
            //  [gt, n)      : elements identical to pivot
            // move elements identical to pivot into the middle of the array
            var span = @intFromPtr(plt) - @intFromPtr(ptr);
            var span2 = @intFromPtr(pi) - @intFromPtr(plt);
            lt = i - lt;
            if (span > span2) span = span2;
            swap_block(@ptrCast(ptr), @ptrCast(pi - span), span);

            span = @intFromPtr(top) - @intFromPtr(pgt);
            span2 = @intFromPtr(pgt) - @intFromPtr(pi);
            pgt = top - span2;
            gt = nmemb - (gt - i);
            if (span > span2) span = span2;
            swap_block(@ptrCast(pi), @ptrCast(top - span), span);

            // now array has 3 parts:
            //  [0, lt)  : smaller than pivot
            //  [lt, gt) : identical to pivot
            //  [gt, n)  : greater than pivot
            // stack the larger segment, keep processing the smaller one
            if (lt > nmemb - gt) {
                stack[sp] = .{ .base = ptr, .count = lt, .depth = depth };
                sp += 1;
                ptr = pgt;
                nmemb -= gt;
            } else {
                stack[sp] = .{ .base = pgt, .count = nmemb - gt, .depth = depth };
                sp += 1;
                nmemb = lt;
            }
        }
        // Use insertion sort for small fragments
        const top = ptr + nmemb * size;
        var pi = ptr + size;
        while (@intFromPtr(pi) < @intFromPtr(top)) : (pi += size) {
            var pj = pi;
            while (@intFromPtr(pj) > @intFromPtr(ptr) and cmpAt(cmp, pj - size, pj, opaque_ptr) > 0) : (pj -= size) {
                swap(@ptrCast(pj), @ptrCast(pj - size), size);
            }
        }
    }
}
