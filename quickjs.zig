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
