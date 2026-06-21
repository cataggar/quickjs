//! Incremental Zig port of quickjs.c.
//!
//! quickjs.c is a ~61k-line monolith whose functions mostly operate on internal
//! structs (JSContext/JSValue/JSObject/...) defined inside the .c file. We port
//! it the same way as the other modules: self-contained functions are moved here
//! and exported with the C ABI, while the C side keeps a prototype and links
//! against the Zig symbol. We start with leaf functions that depend only on
//! primitive types (and already-ported helpers), then work outward.
//!
//! Zig 0.17 has no @cImport, so any C constant/struct a ported function needs is
//! mirrored here explicitly (see the JS_PROP_* values below, which mirror the
//! public, ABI-stable definitions in quickjs.h).

const std = @import("std");

extern "c" fn pow(a: f64, b: f64) f64;

// MAX_SAFE_INTEGER (quickjs.c): ((int64_t)1 << 53) - 1
const MAX_SAFE_INTEGER: f64 = @floatFromInt((@as(i64, 1) << 53) - 1);

// Property flags, mirrored from quickjs.h:298-316 (public, ABI-stable).
const JS_PROP_CONFIGURABLE: c_int = 1 << 0;
const JS_PROP_WRITABLE: c_int = 1 << 1;
const JS_PROP_ENUMERABLE: c_int = 1 << 2;
const JS_PROP_C_W_E: c_int = JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE | JS_PROP_ENUMERABLE;
const JS_PROP_TMASK: c_int = 3 << 4;
const JS_PROP_GETSET: c_int = 1 << 4;
const JS_PROP_HAS_SHIFT: u5 = 8;
const JS_PROP_HAS_CONFIGURABLE: c_int = 1 << 8;
const JS_PROP_HAS_WRITABLE: c_int = 1 << 9;
const JS_PROP_HAS_ENUMERABLE: c_int = 1 << 10;
const JS_PROP_HAS_GET: c_int = 1 << 11;
const JS_PROP_HAS_SET: c_int = 1 << 12;
const JS_PROP_HAS_VALUE: c_int = 1 << 13;

// pow() that is not compatible with IEEE 754: 1 ^ +/-Infinity is NaN.
export fn js_pow(a: f64, b: f64) callconv(.c) f64 {
    if (!std.math.isFinite(b) and @abs(a) == 1) {
        return std.math.nan(f64);
    } else {
        return pow(a, b);
    }
}

export fn is_safe_integer(d: f64) callconv(.c) c_int {
    return @intFromBool(std.math.isFinite(d) and std.math.floor(d) == d and
        @abs(d) <= MAX_SAFE_INTEGER);
}

export fn get_prop_flags(flags: c_int, def_flags: c_int) callconv(.c) c_int {
    const mask = (flags >> JS_PROP_HAS_SHIFT) & JS_PROP_C_W_E;
    return (flags & mask) | (def_flags & ~mask);
}

// JS_MALLOC_BLOCK_SIZE_COUNT (quickjs.c:251)
const JS_MALLOC_BLOCK_SIZE_COUNT: c_int = 31;

export fn get_block_size_index(size: usize) callconv(.c) c_int {
    if (size <= 16) {
        return 0;
    } else if (size <= 128) {
        return @intCast((size + 7) / 8 - 2);
    } else if (size <= 256) {
        return @intCast((size + 15) / 16 + 6);
    } else if (size <= 512) {
        return @intCast((size + 31) / 32 + 14);
    } else {
        return JS_MALLOC_BLOCK_SIZE_COUNT;
    }
}

export fn count_ascii(buf: [*c]const u8, len: usize) callconv(.c) usize {
    var p: usize = 0;
    while (p < len and buf[p] < 128) p += 1;
    return p;
}

// round to nearest, ties to even, shifting right by n.
export fn shr_rndn(a: u64, n: c_int) callconv(.c) u64 {
    const sh: u6 = @intCast(n);
    const addend: u64 = ((a >> sh) & 1) + ((@as(u64, 1) << @as(u6, @intCast(n - 1))) - 1);
    return (a +% addend) >> sh;
}

export fn check_define_prop_flags(prop_flags: c_int, flags: c_int) callconv(.c) c_int {
    if ((prop_flags & JS_PROP_CONFIGURABLE) == 0) {
        if ((flags & (JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE)) ==
            (JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE))
        {
            return 0;
        }
        if ((flags & JS_PROP_HAS_ENUMERABLE) != 0 and
            (flags & JS_PROP_ENUMERABLE) != (prop_flags & JS_PROP_ENUMERABLE))
            return 0;
        if ((flags & (JS_PROP_HAS_VALUE | JS_PROP_HAS_WRITABLE |
            JS_PROP_HAS_GET | JS_PROP_HAS_SET)) != 0)
        {
            const has_accessor = (flags & (JS_PROP_HAS_GET | JS_PROP_HAS_SET)) != 0;
            const is_getset = (prop_flags & JS_PROP_TMASK) == JS_PROP_GETSET;
            if (has_accessor != is_getset)
                return 0;
            if (!is_getset and (prop_flags & JS_PROP_WRITABLE) == 0) {
                if ((flags & (JS_PROP_HAS_WRITABLE | JS_PROP_WRITABLE)) ==
                    (JS_PROP_HAS_WRITABLE | JS_PROP_WRITABLE))
                    return 0;
            }
        }
    }
    return 1;
}

// ===========================================================================
// BigInt multi-precision limb primitives (quickjs.c bigint mp_* cluster).
// Config-generic: 64-bit limbs (u128 intermediate) when usize is 64-bit,
// else 32-bit limbs (u64 intermediate), mirroring quickjs.h:67-71.
// ===========================================================================

const limb_is_64 = (@sizeOf(usize) >= 8);
const js_limb_t = if (limb_is_64) u64 else u32;
const js_dlimb_t = if (limb_is_64) u128 else u64;
const js_slimb_t = if (limb_is_64) i64 else i32;
const JS_LIMB_BITS: comptime_int = @bitSizeOf(js_limb_t);
const LBs = std.math.Log2Int(js_limb_t); // shift-amount type for a limb
const DBs = std.math.Log2Int(js_dlimb_t); // shift-amount type for a double-limb
const UDIV1NORM_THRESHOLD: js_limb_t = 3;

inline fn idx(i: anytype) usize {
    return @intCast(i);
}

inline fn min_int(a: c_int, b: c_int) c_int {
    return @min(a, b);
}
inline fn max_int(a: c_int, b: c_int) c_int {
    return @max(a, b);
}

export fn mp_add(res: [*c]js_limb_t, op1: [*c]const js_limb_t, op2: [*c]const js_limb_t, n: js_limb_t, carry_in: js_limb_t) callconv(.c) js_limb_t {
    var carry = carry_in;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = op1[i];
        var a = v +% op2[i];
        const k1: js_limb_t = @intFromBool(a < v);
        const k = carry;
        a = a +% k;
        carry = @intFromBool(a < k) | k1;
        res[i] = a;
    }
    return carry;
}

export fn mp_sub(res: [*c]js_limb_t, op1: [*c]const js_limb_t, op2: [*c]const js_limb_t, n: c_int, carry: js_limb_t) callconv(.c) js_limb_t {
    var k = carry;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const v0 = op1[idx(i)];
        const a = v0 -% op2[idx(i)];
        const k1: js_limb_t = @intFromBool(a > v0);
        const v = a -% k;
        k = @intFromBool(v > a) | k1;
        res[idx(i)] = v;
    }
    return k;
}

// compute 0 - op2. carry = 0 or 1.
export fn mp_neg(res: [*c]js_limb_t, op2: [*c]const js_limb_t, n: c_int) callconv(.c) js_limb_t {
    var carry: js_limb_t = 1;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const v = ~op2[idx(i)] +% carry;
        carry = @intFromBool(v < carry);
        res[idx(i)] = v;
    }
    return carry;
}

// tabr[] = taba[] * b + l. Return the high carry.
export fn mp_mul1(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: js_limb_t, b: js_limb_t, l_in: js_limb_t) callconv(.c) js_limb_t {
    var l = l_in;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t: js_dlimb_t = @as(js_dlimb_t, taba[i]) * @as(js_dlimb_t, b) + l;
        tabr[i] = @truncate(t);
        l = @truncate(t >> @as(DBs, JS_LIMB_BITS));
    }
    return l;
}

export fn mp_div1(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: js_limb_t, b: js_limb_t, r_in: js_limb_t) callconv(.c) js_limb_t {
    var r = r_in;
    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const a1: js_dlimb_t = (@as(js_dlimb_t, r) << @as(DBs, JS_LIMB_BITS)) | taba[idx(i)];
        tabr[idx(i)] = @truncate(a1 / b);
        r = @truncate(a1 % b);
    }
    return r;
}

// tabr[] += taba[] * b, return the high word.
export fn mp_add_mul1(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: js_limb_t, b: js_limb_t) callconv(.c) js_limb_t {
    var l: js_limb_t = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t: js_dlimb_t = @as(js_dlimb_t, taba[i]) * @as(js_dlimb_t, b) + l + tabr[i];
        tabr[i] = @truncate(t);
        l = @truncate(t >> @as(DBs, JS_LIMB_BITS));
    }
    return l;
}

// size of the result: op1_size + op2_size.
export fn mp_mul_basecase(result: [*c]js_limb_t, op1: [*c]const js_limb_t, op1_size: js_limb_t, op2: [*c]const js_limb_t, op2_size: js_limb_t) callconv(.c) void {
    result[idx(op1_size)] = mp_mul1(result, op1, op1_size, op2[0], 0);
    var i: usize = 1;
    while (i < op2_size) : (i += 1) {
        const r = mp_add_mul1(result + i, op1, op1_size, op2[i]);
        result[i + idx(op1_size)] = r;
    }
}

// tabr[] -= taba[] * b. Return the value to subtract from the high word.
export fn mp_sub_mul1(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: js_limb_t, b: js_limb_t) callconv(.c) js_limb_t {
    var l: js_limb_t = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t: js_dlimb_t = @as(js_dlimb_t, tabr[i]) -% @as(js_dlimb_t, taba[i]) *% @as(js_dlimb_t, b) -% @as(js_dlimb_t, l);
        tabr[i] = @truncate(t);
        l = 0 -% @as(js_limb_t, @truncate(t >> @as(DBs, JS_LIMB_BITS)));
    }
    return l;
}

// WARNING: d must be >= 2^(JS_LIMB_BITS-1)
fn udiv1norm_init(d: js_limb_t) js_limb_t {
    const a1: js_limb_t = (0 -% d) -% 1;
    const a0: js_limb_t = ~@as(js_limb_t, 0);
    return @truncate(((@as(js_dlimb_t, a1) << @as(DBs, JS_LIMB_BITS)) | a0) / d);
}

// quotient (returned) and remainder in *pr of 'a1*2^LB+a0 / d' with 0 <= a1 < d.
fn udiv1norm(pr: *js_limb_t, a1: js_limb_t, a0: js_limb_t, d: js_limb_t, d_inv: js_limb_t) js_limb_t {
    const n1m: js_limb_t = @bitCast(@as(js_slimb_t, @bitCast(a0)) >> (JS_LIMB_BITS - 1));
    const n_adj: js_limb_t = a0 +% (n1m & d);
    var a: js_dlimb_t = @as(js_dlimb_t, d_inv) *% @as(js_dlimb_t, a1 -% n1m) +% @as(js_dlimb_t, n_adj);
    var q: js_limb_t = @as(js_limb_t, @truncate(a >> @as(DBs, JS_LIMB_BITS))) +% a1;
    a = (@as(js_dlimb_t, a1) << @as(DBs, JS_LIMB_BITS)) | a0;
    a = a -% @as(js_dlimb_t, q) *% @as(js_dlimb_t, d) -% @as(js_dlimb_t, d);
    const ah: js_limb_t = @truncate(a >> @as(DBs, JS_LIMB_BITS));
    q +%= 1 +% ah;
    const r: js_limb_t = @as(js_limb_t, @truncate(a)) +% (ah & d);
    pr.* = r;
    return q;
}

// b must be >= 1 << (JS_LIMB_BITS - 1)
export fn mp_div1norm(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: js_limb_t, b: js_limb_t, r_in: js_limb_t) callconv(.c) js_limb_t {
    var r = r_in;
    if (n >= UDIV1NORM_THRESHOLD) {
        const b_inv = udiv1norm_init(b);
        var i: isize = @as(isize, @intCast(n)) - 1;
        while (i >= 0) : (i -= 1) {
            tabr[idx(i)] = udiv1norm(&r, r, taba[idx(i)], b, b_inv);
        }
    } else {
        var i: isize = @as(isize, @intCast(n)) - 1;
        while (i >= 0) : (i -= 1) {
            const a1: js_dlimb_t = (@as(js_dlimb_t, r) << @as(DBs, JS_LIMB_BITS)) | taba[idx(i)];
            tabr[idx(i)] = @truncate(a1 / b);
            r = @truncate(a1 % b);
        }
    }
    return r;
}

// base case division: divides taba[0..na-1] by tabb[0..nb-1]. tabb[nb-1] must
// be >= 1 << (JS_LIMB_BITS - 1). na - nb >= 0. 'taba' is modified and contains
// the remainder (nb limbs). tabq[0..na-nb] contains the quotient.
export fn mp_divnorm(tabq: [*c]js_limb_t, taba: [*c]js_limb_t, na: js_limb_t, tabb: [*c]const js_limb_t, nb: js_limb_t) callconv(.c) void {
    const b1 = tabb[idx(nb - 1)];
    if (nb == 1) {
        taba[0] = mp_div1norm(tabq, taba, na, b1, 0);
        return;
    }
    const n: js_limb_t = na - nb;

    var b1_inv: js_limb_t = 0;
    if (n >= UDIV1NORM_THRESHOLD)
        b1_inv = udiv1norm_init(b1);

    // first iteration: the quotient is only 0 or 1
    var q: js_limb_t = 1;
    var j: isize = @as(isize, @intCast(nb)) - 1;
    while (j >= 0) : (j -= 1) {
        if (taba[idx(@as(isize, @intCast(n)) + j)] != tabb[idx(j)]) {
            if (taba[idx(@as(isize, @intCast(n)) + j)] < tabb[idx(j)])
                q = 0;
            break;
        }
    }
    tabq[idx(n)] = q;
    if (q != 0) {
        _ = mp_sub(taba + idx(n), taba + idx(n), tabb, @intCast(nb), 0);
    }

    var i: isize = @as(isize, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        var r: js_limb_t = undefined;
        const inb = idx(i + @as(isize, @intCast(nb)));
        if (taba[inb] >= b1) {
            q = ~@as(js_limb_t, 0); // -1
        } else if (b1_inv != 0) {
            var dummy_r: js_limb_t = undefined;
            q = udiv1norm(&dummy_r, taba[inb], taba[inb - 1], b1, b1_inv);
        } else {
            const al: js_dlimb_t = (@as(js_dlimb_t, taba[inb]) << @as(DBs, JS_LIMB_BITS)) | taba[inb - 1];
            q = @truncate(al / b1);
        }
        r = mp_sub_mul1(taba + idx(i), tabb, nb, q);

        const v = taba[inb];
        const a = v -% r;
        var c: js_limb_t = @intFromBool(a > v);
        taba[inb] = a;

        if (c != 0) {
            // negative result
            while (true) {
                q -%= 1;
                c = mp_add(taba + idx(i), taba + idx(i), tabb, nb, 0);
                if (c != 0) {
                    taba[inb] +%= 1;
                    if (taba[inb] == 0) break;
                }
            }
        }
        tabq[idx(i)] = q;
    }
}

// 1 <= shift <= JS_LIMB_BITS - 1
export fn mp_shl(tabr: [*c]js_limb_t, taba: [*c]const js_limb_t, n: c_int, shift: c_int) callconv(.c) js_limb_t {
    var l: js_limb_t = 0;
    const sh: LBs = @intCast(shift);
    const sh2: LBs = @intCast(JS_LIMB_BITS - shift);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const v = taba[idx(i)];
        tabr[idx(i)] = (v << sh) | l;
        l = v >> sh2;
    }
    return l;
}

// r = (a + high*B^n) >> shift. Return remainder r. 1 <= shift <= LIMB_BITS-1.
export fn mp_shr(tab_r: [*c]js_limb_t, tab: [*c]const js_limb_t, n: c_int, shift: c_int, high: js_limb_t) callconv(.c) js_limb_t {
    var l = high;
    const sh: LBs = @intCast(shift);
    const sh2: LBs = @intCast(JS_LIMB_BITS - shift);
    var i: c_int = n - 1;
    while (i >= 0) : (i -= 1) {
        const a = tab[idx(i)];
        tab_r[idx(i)] = (a >> sh) | (l << sh2);
        l = a;
    }
    return l & ((@as(js_limb_t, 1) << sh) - 1);
}

// ===========================================================================
// Assorted pure leaf helpers (math, date integer math, hashing, scanning).
// ===========================================================================

extern "c" fn fmin(a: f64, b: f64) f64;
extern "c" fn fmax(a: f64, b: f64) f64;
extern "c" fn memchr(s: ?*const anyopaque, c: c_int, n: usize) ?*const anyopaque;

// precondition: a and b are not NaN
export fn js_fmin(a: f64, b: f64) callconv(.c) f64 {
    if (a == 0 and b == 0) {
        return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    } else {
        return fmin(a, b);
    }
}

export fn js_fmax(a: f64, b: f64) callconv(.c) f64 {
    if (a == 0 and b == 0) {
        return @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b)));
    } else {
        return fmax(a, b);
    }
}

export fn js_math_sign(a: f64) callconv(.c) f64 {
    if (std.math.isNan(a) or a == 0.0) return a;
    if (a < 0) return -1;
    return 1;
}

export fn js_math_round(a: f64) callconv(.c) f64 {
    var u: u64 = @bitCast(a);
    const e: u32 = @intCast((u >> 52) & 0x7ff);
    if (e < 1023) {
        if (e == (1023 - 1) and u != 0xbfe0000000000000) {
            u = (u & (@as(u64, 1) << 63)) | (@as(u64, 1023) << 52);
        } else {
            u &= @as(u64, 1) << 63;
        }
    } else if (e < (1023 + 52)) {
        const s: u64 = u >> 63;
        const one: u64 = @as(u64, 1) << @as(u6, @intCast(52 - (e - 1023)));
        const frac_mask = one - 1;
        u +%= (one >> 1) -% s;
        u &= ~frac_mask;
    }
    return @bitCast(u);
}

export fn js_math_fround(a: f64) callconv(.c) f64 {
    return @as(f64, @as(f32, @floatCast(a)));
}

// return positive modulo
export fn math_mod(a: i64, b: i64) callconv(.c) i64 {
    const m = @rem(a, b);
    return m + @as(i64, @intFromBool(m < 0)) * b;
}

// integer division rounding toward -Infinity
export fn floor_div(a: i64, b: i64) callconv(.c) i64 {
    const m = @rem(a, b);
    return @divTrunc(a - (m + @as(i64, @intFromBool(m < 0)) * b), b);
}

export fn is_valid_raw_json_char(c: c_int) callconv(.c) c_int {
    return @intFromBool((c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or
        c == '"');
}

export fn has_lf_in_range(p1_in: [*c]const u8, p2_in: [*c]const u8) callconv(.c) c_int {
    var p1 = p1_in;
    var p2 = p2_in;
    if (@intFromPtr(p1) > @intFromPtr(p2)) {
        const tmp = p1;
        p1 = p2;
        p2 = tmp;
    }
    const len = @intFromPtr(p2) - @intFromPtr(p1);
    return @intFromBool(memchr(p1, '\n', len) != null);
}

// same magic hash multiplier as the Linux kernel
export fn shape_hash(h: u32, val: u32) callconv(.c) u32 {
    return (h +% val) *% 0x9e370001;
}

// truncate the shape hash to 'hash_bits' bits
export fn get_shape_hash(h: u32, hash_bits: c_int) callconv(.c) u32 {
    return h >> @as(u5, @intCast(32 - hash_bits));
}

// ===========================================================================
// Parser/bytecode pure scanning + flag helpers.
// ===========================================================================

extern fn unicode_from_utf8(p: [*c]const u8, max_len: c_int, pp: [*c][*c]const u8) callconv(.c) c_int;

const UTF8_CHAR_LEN_MAX: c_int = 6; // cutils.h:330
const CP_LS: c_int = 0x2028; // quickjs.c:21500
const CP_PS: c_int = 0x2029; // quickjs.c:21501

export fn skip_shebang(pp: [*c][*c]const u8, buf_end: [*c]const u8) callconv(.c) void {
    var p = pp[0];
    if (p[0] == '#' and p[1] == '!') {
        p += 2;
        while (@intFromPtr(p) < @intFromPtr(buf_end)) {
            if (p[0] == '\n' or p[0] == '\r') {
                break;
            } else if (p[0] >= 0x80) {
                const c = unicode_from_utf8(p, UTF8_CHAR_LEN_MAX, &p);
                if (c == CP_LS or c == CP_PS) {
                    break;
                } else if (c == -1) {
                    p += 1; // skip invalid UTF-8
                }
            } else {
                p += 1;
            }
        }
        pp[0] = p;
    }
}

// return the zero based line number; column number via *pcol_num.
export fn get_line_col(pcol_num: *c_int, buf: [*c]const u8, len: usize) callconv(.c) c_int {
    var line_num: c_int = 0;
    var col_num: c_int = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const c = buf[i];
        if (c == '\n') {
            line_num += 1;
            col_num = 0;
        } else if (c < 0x80 or c >= 0xc0) {
            col_num += 1;
        }
    }
    pcol_num.* = col_num;
    return line_num;
}

export fn bc_set_flags(pflags: *u32, pidx: *c_int, val: u32, n: c_int) callconv(.c) void {
    pflags.* = pflags.* | (val << @as(u5, @intCast(pidx.*)));
    pidx.* += n;
}

// XXX: this does not work for n == 32
export fn bc_get_flags(flags: u32, pidx: *c_int, n: c_int) callconv(.c) u32 {
    const val = (flags >> @as(u5, @intCast(pidx.*))) & ((@as(u32, 1) << @as(u5, @intCast(n))) - 1);
    pidx.* += n;
    return val;
}

// ===========================================================================
// Parser/optimizer opcode & token predicates. The OP_*/TOK_* enum values are
// exported from C (zig_* symbols) so the C compiler computes them — no drift.
// ===========================================================================

extern const zig_OP_scope_get_var_undef: c_int;
extern const zig_OP_with_get_var: c_int;
extern const zig_OP_scope_get_var: c_int;
extern const zig_OP_put_ref_value: c_int;
extern const zig_OP_insert3: c_int;
extern const zig_OP_perm4: c_int;
extern const zig_OP_nop: c_int;
extern const zig_OP_rot3l: c_int;

extern const zig_TOK_IDENT: c_int;
extern const zig_TOK_FIRST_KEYWORD: c_int;
extern const zig_TOK_LAST_KEYWORD: c_int;
extern const zig_TOK_NUMBER: c_int;
extern const zig_TOK_STRING: c_int;
extern const zig_TOK_REGEXP: c_int;
extern const zig_TOK_DEC: c_int;
extern const zig_TOK_INC: c_int;
extern const zig_TOK_NULL: c_int;
extern const zig_TOK_FALSE: c_int;
extern const zig_TOK_TRUE: c_int;
extern const zig_TOK_THIS: c_int;

export fn get_with_scope_opcode(op: c_int) callconv(.c) c_int {
    if (op == zig_OP_scope_get_var_undef)
        return zig_OP_with_get_var;
    return zig_OP_with_get_var + (op - zig_OP_scope_get_var);
}

export fn can_opt_put_ref_value(bc_buf: [*c]const u8, pos: c_int) callconv(.c) c_int {
    const opcode: c_int = bc_buf[idx(pos)];
    return @intFromBool(@as(c_int, bc_buf[idx(pos + 1)]) == zig_OP_put_ref_value and
        (opcode == zig_OP_insert3 or opcode == zig_OP_perm4 or
            opcode == zig_OP_nop or opcode == zig_OP_rot3l));
}

export fn can_opt_put_global_ref_value(bc_buf: [*c]const u8, pos: c_int) callconv(.c) c_int {
    const opcode: c_int = bc_buf[idx(pos)];
    return @intFromBool(@as(c_int, bc_buf[idx(pos + 1)]) == zig_OP_put_ref_value and
        (opcode == zig_OP_insert3 or opcode == zig_OP_perm4 or
            opcode == zig_OP_nop or opcode == zig_OP_rot3l));
}

// Accept keywords and reserved words as property names.
export fn token_is_ident(tok: c_int) callconv(.c) c_int {
    return @intFromBool(tok == zig_TOK_IDENT or
        (tok >= zig_TOK_FIRST_KEYWORD and tok <= zig_TOK_LAST_KEYWORD));
}

// return TRUE if a regexp literal is allowed after this token
export fn is_regexp_allowed(tok: c_int) callconv(.c) c_int {
    if (tok == zig_TOK_NUMBER or tok == zig_TOK_STRING or tok == zig_TOK_REGEXP or
        tok == zig_TOK_DEC or tok == zig_TOK_INC or tok == zig_TOK_NULL or
        tok == zig_TOK_FALSE or tok == zig_TOK_TRUE or tok == zig_TOK_THIS or
        tok == ')' or tok == ']' or tok == '}' or tok == zig_TOK_IDENT)
        return 0; // FALSE
    return 1; // TRUE
}

// ===========================================================================
// BigInt arithmetic layer (operates on JSBigInt, sits on the mp_* primitives).
// JSContext is opaque here; allocation/normalization stay in C and are called
// via extern. JSBigInt mirrors quickjs.c:519-524.
// ===========================================================================

const JSBigInt = extern struct { len: u32 };
// Offset of the flexible js_limb_t tab[] within JSBigInt (len + alignment pad).
const BI_TAB_OFF: usize = std.mem.alignForward(usize, @sizeOf(u32), @alignOf(js_limb_t));

inline fn biTab(a: *JSBigInt) [*c]js_limb_t {
    return @ptrFromInt(@intFromPtr(a) + BI_TAB_OFF);
}
inline fn biTabC(a: *const JSBigInt) [*c]const js_limb_t {
    return @ptrFromInt(@intFromPtr(a) + BI_TAB_OFF);
}
// return 0 or 1 depending on the sign
inline fn biSign(a: *const JSBigInt) js_limb_t {
    return biTabC(a)[a.len - 1] >> (JS_LIMB_BITS - 1);
}

const AddcResult = struct { res: js_limb_t, carry: js_limb_t };
inline fn addc(op1: js_limb_t, op2: js_limb_t, carry_in: js_limb_t) AddcResult {
    const v = op1;
    var a = v +% op2;
    const k1: js_limb_t = @intFromBool(a < v);
    a = a +% carry_in;
    return .{ .res = a, .carry = @as(js_limb_t, @intFromBool(a < carry_in)) | k1 };
}

extern fn js_bigint_new(ctx: ?*anyopaque, len: c_int) callconv(.c) ?*JSBigInt;
extern fn js_bigint_extend(ctx: ?*anyopaque, r: *JSBigInt, op1: js_limb_t) callconv(.c) ?*JSBigInt;
extern fn js_bigint_normalize(ctx: ?*anyopaque, a: *JSBigInt) callconv(.c) ?*JSBigInt;

// Compute a + b (b_neg = 0) or a - b (b_neg = 1). Return NULL on error.
export fn js_bigint_add(ctx: ?*anyopaque, a: *const JSBigInt, b: *const JSBigInt, b_neg: c_int) callconv(.c) ?*JSBigInt {
    const n2 = max_int(@intCast(a.len), @intCast(b.len));
    const n1 = min_int(@intCast(a.len), @intCast(b.len));
    const r = js_bigint_new(ctx, n2) orelse return null;
    const rt = biTab(r);
    const at = biTabC(a);
    const bt = biTabC(b);
    const nbn: js_limb_t = 0 -% @as(js_limb_t, @intCast(b_neg));
    var carry: js_limb_t = @intCast(b_neg);
    var i: c_int = 0;
    while (i < n1) : (i += 1) {
        const rr = addc(at[idx(i)], bt[idx(i)] ^ nbn, carry);
        rt[idx(i)] = rr.res;
        carry = rr.carry;
    }
    const a_sign: js_limb_t = 0 -% biSign(a);
    const b_sign: js_limb_t = (0 -% biSign(b)) ^ nbn;
    if (a.len > b.len) {
        while (i < n2) : (i += 1) {
            const rr = addc(at[idx(i)], b_sign, carry);
            rt[idx(i)] = rr.res;
            carry = rr.carry;
        }
    } else if (a.len < b.len) {
        while (i < n2) : (i += 1) {
            const rr = addc(a_sign, bt[idx(i)] ^ nbn, carry);
            rt[idx(i)] = rr.res;
            carry = rr.carry;
        }
    }
    return js_bigint_extend(ctx, r, a_sign +% b_sign +% carry);
}

export fn js_bigint_mul(ctx: ?*anyopaque, a: *const JSBigInt, b: *const JSBigInt) callconv(.c) ?*JSBigInt {
    const r = js_bigint_new(ctx, @as(c_int, @intCast(a.len)) + @as(c_int, @intCast(b.len))) orelse return null;
    const rt = biTab(r);
    const at = biTabC(a);
    const bt = biTabC(b);
    mp_mul_basecase(rt, at, a.len, bt, b.len);
    // correct the result if negative operands (no overflow is possible)
    if (biSign(a) != 0)
        _ = mp_sub(rt + idx(a.len), rt + idx(a.len), bt, @intCast(b.len), 0);
    if (biSign(b) != 0)
        _ = mp_sub(rt + idx(b.len), rt + idx(b.len), at, @intCast(a.len), 0);
    return js_bigint_normalize(ctx, r);
}

extern fn js_bigint_new_si(ctx: ?*anyopaque, a: js_slimb_t) callconv(.c) ?*JSBigInt;
extern "c" fn abort() noreturn;

extern const zig_OP_or: c_int;
extern const zig_OP_and: c_int;
extern const zig_OP_xor: c_int;

export fn js_bigint_neg(ctx: ?*anyopaque, a: *const JSBigInt) callconv(.c) ?*JSBigInt {
    var buf: [2]js_limb_t align(@alignOf(js_limb_t)) = undefined;
    const b: *JSBigInt = @ptrCast(&buf);
    b.len = 1;
    biTab(b)[0] = 0;
    return js_bigint_add(ctx, b, a, 1);
}

export fn js_bigint_cmp(ctx: ?*anyopaque, a: *const JSBigInt, b: *const JSBigInt) callconv(.c) c_int {
    _ = ctx;
    const a_sign: c_int = @intCast(biSign(a));
    const b_sign: c_int = @intCast(biSign(b));
    var res: c_int = 0;
    if (a_sign != b_sign) {
        res = 1 - 2 * a_sign;
    } else if (a.len != b.len) {
        // we assume the numbers are normalized
        if (a.len < b.len) {
            res = 2 * a_sign - 1;
        } else {
            res = 1 - 2 * a_sign;
        }
    } else {
        const at = biTabC(a);
        const bt = biTabC(b);
        var i: isize = @as(isize, @intCast(a.len)) - 1;
        while (i >= 0) : (i -= 1) {
            if (at[idx(i)] != bt[idx(i)]) {
                res = if (at[idx(i)] < bt[idx(i)]) -1 else 1;
                break;
            }
        }
    }
    return res;
}

export fn js_bigint_not(ctx: ?*anyopaque, a: *const JSBigInt) callconv(.c) ?*JSBigInt {
    const r = js_bigint_new(ctx, @intCast(a.len)) orelse return null;
    const rt = biTab(r);
    const at = biTabC(a);
    var i: usize = 0;
    while (i < a.len) : (i += 1) rt[i] = ~at[i];
    return r; // no normalization is needed
}

// and, or, xor
export fn js_bigint_logic(ctx: ?*anyopaque, a_in: *const JSBigInt, b_in: *const JSBigInt, op: c_int) callconv(.c) ?*JSBigInt {
    var a = a_in;
    var b = b_in;
    if (a.len < b.len) {
        const tmp = a;
        a = b;
        b = tmp;
    }
    const a_len = a.len;
    const b_len = b.len;
    const b_sign: js_limb_t = 0 -% biSign(b);
    const r = js_bigint_new(ctx, @intCast(a_len)) orelse return null;
    const rt = biTab(r);
    const at = biTabC(a);
    const bt = biTabC(b);
    var i: usize = 0;
    if (op == zig_OP_or) {
        while (i < b_len) : (i += 1) rt[i] = at[i] | bt[i];
        while (i < a_len) : (i += 1) rt[i] = at[i] | b_sign;
    } else if (op == zig_OP_and) {
        while (i < b_len) : (i += 1) rt[i] = at[i] & bt[i];
        while (i < a_len) : (i += 1) rt[i] = at[i] & b_sign;
    } else if (op == zig_OP_xor) {
        while (i < b_len) : (i += 1) rt[i] = at[i] ^ bt[i];
        while (i < a_len) : (i += 1) rt[i] = at[i] ^ b_sign;
    } else {
        abort();
    }
    return js_bigint_normalize(ctx, r);
}

export fn js_bigint_shl(ctx: ?*anyopaque, a: *const JSBigInt, shift1: c_uint) callconv(.c) ?*JSBigInt {
    const at = biTabC(a);
    if (a.len == 1 and at[0] == 0)
        return js_bigint_new_si(ctx, 0); // zero case
    const d: c_int = @intCast(shift1 / JS_LIMB_BITS);
    const shift: c_int = @intCast(shift1 % JS_LIMB_BITS);
    var r = js_bigint_new(ctx, @as(c_int, @intCast(a.len)) + d) orelse return null;
    var rt = biTab(r);
    var i: c_int = 0;
    while (i < d) : (i += 1) rt[idx(i)] = 0;
    if (shift == 0) {
        i = 0;
        while (i < a.len) : (i += 1) rt[idx(i + d)] = at[idx(i)];
    } else {
        var l = mp_shl(rt + idx(d), at, @intCast(a.len), shift);
        if (biSign(a) != 0)
            l |= (~@as(js_limb_t, 0)) << @as(LBs, @intCast(shift));
        r = js_bigint_extend(ctx, r, l) orelse return null;
    }
    return r;
}

export fn js_bigint_shr(ctx: ?*anyopaque, a: *const JSBigInt, shift1: c_uint) callconv(.c) ?*JSBigInt {
    const d: c_int = @intCast(shift1 / JS_LIMB_BITS);
    const shift: c_int = @intCast(shift1 % JS_LIMB_BITS);
    const a_sign: c_int = @intCast(biSign(a));
    if (d >= a.len)
        return js_bigint_new_si(ctx, -a_sign);
    const n1: c_int = @as(c_int, @intCast(a.len)) - d;
    var r = js_bigint_new(ctx, n1) orelse return null;
    const rt = biTab(r);
    const at = biTabC(a);
    if (shift == 0) {
        var i: c_int = 0;
        while (i < n1) : (i += 1) rt[idx(i)] = at[idx(i + d)];
        // no normalization is needed
    } else {
        _ = mp_shr(rt, at + idx(d), n1, shift, 0 -% @as(js_limb_t, @intCast(a_sign)));
        r = js_bigint_normalize(ctx, r) orelse return null;
    }
    return r;
}
