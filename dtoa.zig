//! dtoa — Zig port of dtoa.c (incremental).
//!
//! First increment: the integer-to-ASCII conversions (u32toa/i32toa/u64toa/
//! i64toa and their radix variants), exported with the C ABI to match dtoa.h.
//! The bignum-based float conversions remain in dtoa.c for now.

extern "c" fn memcpy(noalias dest: ?*anyopaque, noalias src: ?*const anyopaque, n: usize) ?*anyopaque;

inline fn clz32(a: u32) c_int {
    return @intCast(@clz(a));
}
inline fn clz64(a: u64) c_int {
    return @intCast(@clz(a));
}

fn u32toa_len(buf: [*c]u8, n_in: u32, len: usize) void {
    var n = n_in;
    var i: isize = @as(isize, @intCast(len)) - 1;
    while (i >= 0) : (i -= 1) {
        const digit = n % 10;
        n = n / 10;
        buf[@intCast(i)] = @intCast(digit + '0');
    }
}

// for power of 2 radixes. len >= 1
fn u64toa_bin_len(buf: [*c]u8, n_in: u64, radix_bits: u32, len: c_int) void {
    var n = n_in;
    const mask: u64 = (@as(u64, 1) << @intCast(radix_bits)) - 1;
    var i: c_int = len - 1;
    while (i >= 0) : (i -= 1) {
        var digit: u32 = @intCast(n & mask);
        n >>= @intCast(radix_bits);
        if (digit < 10) digit += '0' else digit += 'a' - 10;
        buf[@intCast(i)] = @intCast(digit);
    }
}

export fn u32toa(buf: [*c]u8, n_in: u32) callconv(.c) usize {
    var n = n_in;
    var buf1: [10]u8 = undefined;
    var q: usize = buf1.len;
    while (true) {
        q -= 1;
        buf1[q] = @intCast(n % 10 + '0');
        n /= 10;
        if (n == 0) break;
    }
    const len = buf1.len - q;
    _ = memcpy(@ptrCast(buf), @ptrCast(&buf1[q]), len);
    return len;
}

export fn i32toa(buf: [*c]u8, n: i32) callconv(.c) usize {
    if (n >= 0) return u32toa(buf, @intCast(n));
    buf[0] = '-';
    return u32toa(buf + 1, 0 -% @as(u32, @bitCast(n))) + 1;
}

export fn u64toa(buf: [*c]u8, n_in: u64) callconv(.c) usize {
    var n = n_in;
    if (n < 0x100000000) return u32toa(buf, @intCast(n));
    var q = buf;
    var n1 = n / 1000000000;
    n %= 1000000000;
    if (n1 >= 0x100000000) {
        var n2: u32 = @intCast(n1 / 1000000000);
        n1 = n1 % 1000000000;
        // at most two digits
        if (n2 >= 10) {
            q[0] = @intCast(n2 / 10 + '0');
            q += 1;
            n2 %= 10;
        }
        q[0] = @intCast(n2 + '0');
        q += 1;
        u32toa_len(q, @intCast(n1), 9);
        q += 9;
    } else {
        q += u32toa(q, @intCast(n1));
    }
    u32toa_len(q, @intCast(n), 9);
    q += 9;
    return @intFromPtr(q) - @intFromPtr(buf);
}

export fn i64toa(buf: [*c]u8, n: i64) callconv(.c) usize {
    if (n >= 0) return u64toa(buf, @intCast(n));
    buf[0] = '-';
    return u64toa(buf + 1, 0 -% @as(u64, @bitCast(n))) + 1;
}

// XXX: only tested for 1 <= n < 2^53
export fn u64toa_radix(buf: [*c]u8, n_in: u64, radix: c_uint) callconv(.c) usize {
    var n = n_in;
    if (radix == 10) return u64toa(buf, n);
    if ((radix & (radix - 1)) == 0) {
        const radix_bits: u32 = @intCast(31 - clz32(@intCast(radix)));
        var l: c_int = undefined;
        if (n == 0) {
            l = 1;
        } else {
            l = @divTrunc(64 - clz64(n) + @as(c_int, @intCast(radix_bits)) - 1, @as(c_int, @intCast(radix_bits)));
        }
        u64toa_bin_len(buf, n, radix_bits, l);
        return @intCast(l);
    } else {
        var buf1: [41]u8 = undefined; // maximum length for radix = 3
        var q: usize = buf1.len;
        const r: u64 = radix;
        while (true) {
            var digit: u32 = @intCast(n % r);
            n /= r;
            if (digit < 10) digit += '0' else digit += 'a' - 10;
            q -= 1;
            buf1[q] = @intCast(digit);
            if (n == 0) break;
        }
        const len = buf1.len - q;
        _ = memcpy(@ptrCast(buf), @ptrCast(&buf1[q]), len);
        return len;
    }
}

export fn i64toa_radix(buf: [*c]u8, n: i64, radix: c_uint) callconv(.c) usize {
    if (n >= 0) return u64toa_radix(buf, @intCast(n), radix);
    buf[0] = '-';
    return u64toa_radix(buf + 1, 0 -% @as(u64, @bitCast(n)), radix) + 1;
}

// ===========================================================================
// dtoa: low-level multi-precision primitives (limb arrays).
// ===========================================================================

const limb_t = u32;
const slimb_t = i32;
const dlimb_t = u64;
const mp_size_t = isize;
const LIMB_BITS: u6 = 32;

export fn mp_add_ui(tab: [*c]limb_t, b: limb_t, n: usize) callconv(.c) limb_t {
    var k: limb_t = b;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (k == 0) break;
        const a = tab[i] +% k;
        k = @intFromBool(a < k);
        tab[i] = a;
    }
    return k;
}

// tabr[] = taba[] * b + l. Return the high carry.
export fn mp_mul1(tabr: [*c]limb_t, taba: [*c]const limb_t, n: limb_t, b: limb_t, l_in: limb_t) callconv(.c) limb_t {
    var l: limb_t = l_in;
    var i: limb_t = 0;
    while (i < n) : (i += 1) {
        const t: dlimb_t = @as(dlimb_t, taba[i]) * @as(dlimb_t, b) + l;
        tabr[i] = @truncate(t);
        l = @truncate(t >> LIMB_BITS);
    }
    return l;
}

// WARNING: d must be >= 2^(LIMB_BITS-1)
export fn udiv1norm_init(d: limb_t) callconv(.c) limb_t {
    const a1: limb_t = (0 -% d) -% 1;
    const a0: limb_t = 0xFFFFFFFF;
    return @truncate(((@as(dlimb_t, a1) << LIMB_BITS) | a0) / d);
}

// quotient + remainder in *pr of 'a1*2^LIMB_BITS+a0 / d' with 0 <= a1 < d.
fn udiv1norm(pr: *limb_t, a1: limb_t, a0: limb_t, d: limb_t, d_inv: limb_t) limb_t {
    const n1m: limb_t = @bitCast(@as(slimb_t, @bitCast(a0)) >> (LIMB_BITS - 1));
    const n_adj: limb_t = a0 +% (n1m & d);
    var a: dlimb_t = @as(dlimb_t, d_inv) * @as(dlimb_t, a1 -% n1m) + n_adj;
    var q: limb_t = @truncate((a >> LIMB_BITS) +% @as(dlimb_t, a1));
    a = (@as(dlimb_t, a1) << LIMB_BITS) | a0;
    a = a -% @as(dlimb_t, q) *% @as(dlimb_t, d) -% @as(dlimb_t, d);
    const ah: limb_t = @truncate(a >> LIMB_BITS);
    q +%= 1 +% ah;
    const r: limb_t = @as(limb_t, @truncate(a)) +% (ah & d);
    pr.* = r;
    return q;
}

export fn mp_div1(tabr: [*c]limb_t, taba: [*c]const limb_t, n: limb_t, b: limb_t, r_in: limb_t) callconv(.c) limb_t {
    var r: limb_t = r_in;
    var i: slimb_t = @as(slimb_t, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        const a1: dlimb_t = (@as(dlimb_t, r) << LIMB_BITS) | taba[@intCast(i)];
        tabr[@intCast(i)] = @truncate(a1 / b);
        r = @truncate(a1 % b);
    }
    return r;
}

// r = (a + high*B^n) >> shift. Return remainder r. 1 <= shift <= LIMB_BITS-1.
export fn mp_shr(tab_r: [*c]limb_t, tab: [*c]const limb_t, n: mp_size_t, shift: c_int, high: limb_t) callconv(.c) limb_t {
    var l: limb_t = high;
    const sh: u5 = @intCast(shift);
    const sh2: u5 = @intCast(LIMB_BITS - shift);
    var i: mp_size_t = n - 1;
    while (i >= 0) : (i -= 1) {
        const a = tab[@intCast(i)];
        tab_r[@intCast(i)] = (a >> sh) | (l << sh2);
        l = a;
    }
    return l & ((@as(limb_t, 1) << sh) - 1);
}

// r = (a << shift) + low. 1 <= shift <= LIMB_BITS-1, 0 <= low < 2^shift.
export fn mp_shl(tab_r: [*c]limb_t, tab: [*c]const limb_t, n: mp_size_t, shift: c_int, low: limb_t) callconv(.c) limb_t {
    var l: limb_t = low;
    const sh: u5 = @intCast(shift);
    const sh2: u5 = @intCast(LIMB_BITS - shift);
    var i: mp_size_t = 0;
    while (i < n) : (i += 1) {
        const a = tab[@intCast(i)];
        tab_r[@intCast(i)] = (a << sh) | l;
        l = a >> sh2;
    }
    return l;
}

export fn mp_div1norm(tabr: [*c]limb_t, taba: [*c]const limb_t, n: limb_t, b: limb_t, r_in: limb_t, b_inv: limb_t, shift: c_int) callconv(.c) limb_t {
    var r: limb_t = r_in;
    if (shift != 0) {
        r = (r << @as(u5, @intCast(shift))) | mp_shl(tabr, taba, @intCast(n), shift, 0);
    }
    var i: slimb_t = @as(slimb_t, @intCast(n)) - 1;
    while (i >= 0) : (i -= 1) {
        tabr[@intCast(i)] = udiv1norm(&r, r, taba[@intCast(i)], b, b_inv);
    }
    r >>= @as(u5, @intCast(shift));
    return r;
}

// ===========================================================================
// dtoa: mpb_t (renormalizable bignum) helpers + power/log helpers.
// ===========================================================================

const mpb_t = extern struct { len: c_int };

inline fn mpbTab(r: *mpb_t) [*c]limb_t {
    return @ptrFromInt(@intFromPtr(r) + @sizeOf(mpb_t));
}
inline fn mpbTabC(r: *const mpb_t) [*c]const limb_t {
    return @ptrFromInt(@intFromPtr(r) + @sizeOf(mpb_t));
}

const JS_RADIX_MAX: c_int = 36;

const JS_RNDN: c_int = 0; // round to nearest, ties to even
const JS_RNDNA: c_int = 1; // round to nearest, ties away from zero
const JS_RNDZ: c_int = 2;

const pow5_table = [17]u32{
    0x00000005, 0x00000019, 0x0000007d, 0x00000271,
    0x00000c35, 0x00003d09, 0x0001312d, 0x0005f5e1,
    0x001dcd65, 0x009502f9, 0x02e90edd, 0x0e8d4a51,
    0x48c27395, 0x6bcc41e9, 0x1afd498d, 0x86f26fc1,
    0xa2bc2ec5,
};
const pow5h_table = [4]u8{ 0x01, 0x07, 0x23, 0xb1 };
const pow5_inv_table = [13]u32{
    0x99999999, 0x47ae147a, 0x0624dd2f, 0xa36e2eb1,
    0x4f8b588e, 0x0c6f7a0b, 0xad7f29ab, 0x5798ee23,
    0x12e0be82, 0xb7cdfd9d, 0x5fd7fe17, 0x19799812,
    0xc25c2684,
};

const MUL_LOG2_RADIX_BASE_LOG2: u6 = 24;
const mul_log2_radix_table = [35]u32{
    0x000000, 0xa1849d, 0x000000, 0x6e40d2,
    0x6308c9, 0x5b3065, 0x000000, 0x50c24e,
    0x4d104d, 0x4a0027, 0x4768ce, 0x452e54,
    0x433d00, 0x418677, 0x000000, 0x3ea16b,
    0x3d645a, 0x3c43c2, 0x3b3b9a, 0x3a4899,
    0x39680b, 0x3897b3, 0x37d5af, 0x372069,
    0x367686, 0x35d6df, 0x354072, 0x34b261,
    0x342bea, 0x33ac62, 0x000000, 0x32bfd9,
    0x3251dd, 0x31e8d6, 0x318465,
};

export fn mpb_renorm(r: *mpb_t) callconv(.c) void {
    const t = mpbTab(r);
    while (r.len > 1 and t[@intCast(r.len - 1)] == 0) r.len -= 1;
}

export fn pow_ui(a: u32, b: u32) callconv(.c) u64 {
    if (b == 0) return 1;
    if (b == 1) return a;
    if ((a == 5 or a == 10) and b <= 17) {
        var r: u64 = pow5_table[b - 1];
        if (b >= 14) r |= @as(u64, pow5h_table[b - 14]) << 32;
        if (a == 10) r <<= @intCast(b);
        return r;
    }
    var r: u64 = a;
    const n_bits: c_int = 32 - @as(c_int, @clz(b));
    var i: c_int = n_bits - 2;
    while (i >= 0) : (i -= 1) {
        r *%= r;
        if ((b >> @intCast(i)) & 1 != 0) r *%= @as(u64, a);
    }
    return r;
}

export fn pow_ui_inv(pr_inv: *u32, pshift: *c_int, a: u32, b: u32) callconv(.c) u32 {
    var r: u32 = undefined;
    var r_inv: u32 = undefined;
    var shift: c_int = undefined;
    if (a == 5 and b >= 1 and b <= 13) {
        r = pow5_table[b - 1];
        shift = @clz(r);
        r <<= @intCast(shift);
        r_inv = pow5_inv_table[b - 1];
    } else {
        r = @truncate(pow_ui(a, b));
        shift = @clz(r);
        r <<= @intCast(shift);
        r_inv = udiv1norm_init(r);
    }
    pshift.* = shift;
    pr_inv.* = r_inv;
    return r;
}

export fn mpb_get_bit(r: *const mpb_t, k_in: c_int) callconv(.c) c_int {
    const ku: u32 = @bitCast(k_in);
    const l: u32 = ku / 32;
    const kbit: u5 = @intCast(ku & 31);
    if (l >= @as(u32, @intCast(r.len))) return 0;
    return @intCast((mpbTabC(r)[l] >> kbit) & 1);
}

// compute round(r / 2^shift). 'shift' can be negative.
export fn mpb_shr_round(r: *mpb_t, shift_in: c_int, rnd_mode: c_int) callconv(.c) void {
    var shift = shift_in;
    const t = mpbTab(r);
    if (shift == 0) return;
    if (shift < 0) {
        shift = -shift;
        const l: c_int = @intCast(@as(u32, @bitCast(shift)) / 32);
        shift = shift & 31;
        if (shift != 0) {
            t[@intCast(r.len)] = mp_shl(t, t, @intCast(r.len), shift, 0);
            r.len += 1;
            mpb_renorm(r);
        }
        if (l > 0) {
            var i: c_int = r.len - 1;
            while (i >= 0) : (i -= 1) t[@intCast(i + l)] = t[@intCast(i)];
            i = 0;
            while (i < l) : (i += 1) t[@intCast(i)] = 0;
            r.len += l;
        }
    } else {
        var add_one: c_int = 0;
        switch (rnd_mode) {
            JS_RNDN, JS_RNDNA => {
                const bit1 = mpb_get_bit(r, shift - 1);
                if (bit1 != 0) {
                    var bit2: limb_t = 0;
                    if (rnd_mode == JS_RNDNA) {
                        bit2 = 1;
                    } else {
                        if (shift >= 2) {
                            var k: c_int = shift - 1;
                            const l2: c_int = @intCast(@as(u32, @bitCast(k)) / 32);
                            k = k & 31;
                            const lim = @min(l2, r.len);
                            var i: c_int = 0;
                            while (i < lim) : (i += 1) bit2 |= t[@intCast(i)];
                            if (l2 < r.len)
                                bit2 |= t[@intCast(l2)] & ((@as(limb_t, 1) << @as(u5, @intCast(k))) - 1);
                        }
                    }
                    if (bit2 != 0) {
                        add_one = 1;
                    } else {
                        add_one = mpb_get_bit(r, shift);
                    }
                }
            },
            else => {},
        }
        const l: c_int = @intCast(@as(u32, @bitCast(shift)) / 32);
        shift = shift & 31;
        if (l >= r.len) {
            r.len = 1;
            t[0] = @intCast(add_one);
        } else {
            if (l > 0) {
                r.len -= l;
                var i: c_int = 0;
                while (i < r.len) : (i += 1) t[@intCast(i)] = t[@intCast(i + l)];
            }
            if (shift != 0) {
                _ = mp_shr(t, t, @intCast(r.len), shift, 0);
                mpb_renorm(r);
            }
            if (add_one != 0) {
                const a = mp_add_ui(t, 1, @intCast(r.len));
                if (a != 0) {
                    t[@intCast(r.len)] = a;
                    r.len += 1;
                }
            }
        }
    }
}

export fn mpb_cmp(a: *const mpb_t, b: *const mpb_t) callconv(.c) c_int {
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    const ta = mpbTabC(a);
    const tb = mpbTabC(b);
    var i: c_int = a.len - 1;
    while (i >= 0) : (i -= 1) {
        const av = ta[@intCast(i)];
        const bv = tb[@intCast(i)];
        if (av != bv) return if (av < bv) -1 else 1;
    }
    return 0;
}

export fn mpb_set_u64(r: *mpb_t, m: u64) callconv(.c) void {
    const t = mpbTab(r);
    t[0] = @truncate(m);
    t[1] = @truncate(m >> 32);
    r.len = if (t[1] == 0) 1 else 2;
}

export fn mpb_get_u64(r: *mpb_t) callconv(.c) u64 {
    const t = mpbTab(r);
    if (r.len == 1) return t[0];
    return @as(u64, t[0]) | (@as(u64, t[1]) << 32);
}

// floor_log2() = position of the first non zero bit or -1 if zero.
export fn mpb_floor_log2(a: *mpb_t) callconv(.c) c_int {
    const t = mpbTab(a);
    const v = t[@intCast(a.len - 1)];
    if (v == 0) return -1;
    return a.len * 32 - 1 - @as(c_int, @clz(v));
}

// return floor(a / log2(radix)) for -2048 <= a <= 2047
export fn mul_log2_radix(a: c_int, radix: c_int) callconv(.c) c_int {
    if ((radix & (radix - 1)) == 0) {
        const radix_bits: c_int = 31 - @as(c_int, @clz(@as(u32, @intCast(radix))));
        var aa = a;
        if (aa < 0) aa -= radix_bits - 1;
        return @divTrunc(aa, radix_bits);
    } else {
        const mult = mul_log2_radix_table[@intCast(radix - 2)];
        return @intCast((@as(i64, a) * @as(i64, mult)) >> MUL_LOG2_RADIX_BASE_LOG2);
    }
}

// ===========================================================================
// dtoa: float<->string entry points (js_dtoa, js_atod) and helpers.
// ===========================================================================

const std = @import("std");

extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn strstart(str: [*c]const u8, val: [*c]const u8, ptr: [*c][*c]const u8) callconv(.c) c_int;

inline fn ctz32(a: u32) c_int {
    return @intCast(@ctz(a));
}
inline fn min_int(a: c_int, b: c_int) c_int {
    return @min(a, b);
}
inline fn max_int(a: c_int, b: c_int) c_int {
    return @max(a, b);
}
inline fn float64_as_uint64(d: f64) u64 {
    return @bitCast(d);
}
inline fn uint64_as_float64(u: u64) f64 {
    return @bitCast(u);
}

const DBIGNUM_LEN_MAX: usize = 52;
const MANT_LEN_MAX: usize = 18;
const JS_DTOA_MAX_DIGITS: c_int = 101;

const JS_DTOA_FORMAT_FREE: c_int = 0 << 0;
const JS_DTOA_FORMAT_FIXED: c_int = 1 << 0;
const JS_DTOA_FORMAT_FRAC: c_int = 2 << 0;
const JS_DTOA_FORMAT_MASK: c_int = 3 << 0;
const JS_DTOA_EXP_AUTO: c_int = 0 << 2;
const JS_DTOA_EXP_ENABLED: c_int = 1 << 2;
const JS_DTOA_EXP_DISABLED: c_int = 2 << 2;
const JS_DTOA_EXP_MASK: c_int = 3 << 2;
const JS_DTOA_MINUS_ZERO: c_int = 1 << 4;

const JS_ATOD_INT_ONLY: c_int = 1 << 0;
const JS_ATOD_ACCEPT_BIN_OCT: c_int = 1 << 1;
const JS_ATOD_ACCEPT_LEGACY_OCTAL: c_int = 1 << 2;
const JS_ATOD_ACCEPT_UNDERSCORES: c_int = 1 << 3;

const JSDTOATempMem = extern struct { mem: [37]u64 };
const JSATODTempMem = extern struct { mem: [27]u64 };

const digits_per_limb_table = [35]u8{
    32, 20, 16, 13, 12, 11, 10, 10, 9, 9, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
};
const radix_base_table = [35]u32{
    0x00000000, 0xcfd41b91, 0x00000000, 0x48c27395,
    0x81bf1000, 0x75db9c97, 0x40000000, 0xcfd41b91,
    0x3b9aca00, 0x8c8b6d2b, 0x19a10000, 0x309f1021,
    0x57f6c100, 0x98c29b81, 0x00000000, 0x18754571,
    0x247dbc80, 0x3547667b, 0x4c4b4000, 0x6b5a6e1d,
    0x94ace180, 0xcaf18367, 0x0b640000, 0x0e8d4a51,
    0x1269ae40, 0x17179149, 0x1cb91000, 0x23744899,
    0x2b73a840, 0x34e63b41, 0x40000000, 0x4cfa3cc1,
    0x5c13d840, 0x6d91b519, 0x81bf1000,
};
const dtoa_max_digits_table = [35]u8{
    54, 35, 28, 24, 22, 20, 19, 18, 17, 17, 16, 16, 15, 15, 15, 14, 14, 14, 14, 14, 13, 13, 13, 13, 13, 13, 13, 12, 12, 12, 12, 12, 12, 12, 12,
};
const atod_max_digits_table = [35]u8{
    64, 80, 32, 55, 49, 45, 21, 40, 38, 37, 35, 34, 33, 32, 16, 31, 30, 30, 29, 29, 28, 28, 27, 27, 27, 26, 26, 26, 26, 25, 12, 25, 25, 24, 24,
};
const max_exponent = [35]i16{
    1024, 647,  512,  442,  397,  365,  342,  324,
    309,  297,  286,  277,  269,  263,  256,  251,
    246,  242,  237,  234,  230,  227,  224,  221,
    218,  216,  214,  211,  209,  207,  205,  203,
    202,  200,  199,
};
const min_exponent = [35]i16{
    -1075, -679, -538, -463, -416, -383, -359, -340,
    -324,  -311, -300, -291, -283, -276, -269, -263,
    -258,  -254, -249, -245, -242, -238, -235, -232,
    -229,  -227, -224, -222, -220, -217, -215, -214,
    -212,  -210, -208,
};

// len >= 1. 2 <= radix <= 36
fn limb_to_a(buf: [*c]u8, n_in: limb_t, radix: u32, len: c_int) void {
    if (radix == 10) {
        u32toa_len(buf, n_in, @intCast(len));
    } else {
        var n = n_in;
        var i: c_int = len - 1;
        while (i >= 0) : (i -= 1) {
            var digit: limb_t = n % radix;
            n = n / radix;
            if (digit < 10) digit += '0' else digit += 'a' - 10;
            buf[@intCast(i)] = @intCast(digit);
        }
    }
}

fn output_digits(buf: [*c]u8, a: *mpb_t, radix: c_int, n_digits1: c_int, dot_pos: c_int) c_int {
    var n_digits = n_digits1;
    var radix_bits: c_int = 0;
    if ((radix & (radix - 1)) == 0) {
        radix_bits = 31 - @as(c_int, @clz(@as(u32, @intCast(radix))));
    }
    const digits_per_limb: c_int = digits_per_limb_table[@intCast(radix - 2)];
    const t = mpbTab(a);
    if (radix_bits != 0) {
        while (true) {
            const n = min_int(n_digits, digits_per_limb);
            n_digits -= n;
            u64toa_bin_len(buf + @as(usize, @intCast(n_digits)), t[0], @intCast(radix_bits), n);
            if (n_digits == 0) break;
            mpb_shr_round(a, digits_per_limb * radix_bits, JS_RNDZ);
        }
    } else {
        while (n_digits != 0) {
            const n = min_int(n_digits, digits_per_limb);
            n_digits -= n;
            const r = mp_div1(t, t, @intCast(a.len), radix_base_table[@intCast(radix - 2)], 0);
            mpb_renorm(a);
            limb_to_a(buf + @as(usize, @intCast(n_digits)), r, @intCast(radix), n);
        }
    }
    var len = n_digits1;
    if (dot_pos != n_digits1) {
        _ = memmove(buf + @as(usize, @intCast(dot_pos + 1)), buf + @as(usize, @intCast(dot_pos)), @intCast(n_digits1 - dot_pos));
        buf[@intCast(dot_pos)] = '.';
        len += 1;
    }
    return len;
}

// return (a, e_offset) such that a = a * (radix1*2^radix_shift)^f * 2^-e_offset.
fn mul_pow(a: *mpb_t, radix1: c_int, radix_shift: c_int, f_in: c_int, is_int: c_int, e: c_int) c_int {
    var f = f_in;
    var e_offset: c_int = -f * radix_shift;
    const t = mpbTab(a);
    if (radix1 != 1) {
        const d: c_int = digits_per_limb_table[@intCast(radix1 - 2)];
        if (f >= 0) {
            var b: limb_t = 0;
            var n0: c_int = 0;
            while (f != 0) {
                const n = min_int(f, d);
                if (n != n0) {
                    b = @intCast(pow_ui(@intCast(radix1), @intCast(n)));
                    n0 = n;
                }
                const h = mp_mul1(t, t, @intCast(a.len), b, 0);
                if (h != 0) {
                    t[@intCast(a.len)] = h;
                    a.len += 1;
                }
                f -= n;
            }
        } else {
            f = -f;
            const l: c_int = @divTrunc(f + d - 1, d);
            e_offset += l * 32;
            var extra_bits: c_int = undefined;
            if (is_int == 0) {
                extra_bits = max_int(e - mpb_floor_log2(a), 0);
            } else {
                extra_bits = max_int(2 + e - e_offset, 0);
            }
            e_offset += extra_bits;
            mpb_shr_round(a, -(l * 32 + extra_bits), JS_RNDZ);

            var b: limb_t = 0;
            var b_inv: limb_t = 0;
            var shift: c_int = 0;
            var n0: c_int = 0;
            var rem: limb_t = 0;
            while (f != 0) {
                const n = min_int(f, d);
                if (n != n0) {
                    b = pow_ui_inv(&b_inv, &shift, @intCast(radix1), @intCast(n));
                    n0 = n;
                }
                const r = mp_div1norm(t, t, @intCast(a.len), b, 0, b_inv, shift);
                rem |= r;
                mpb_renorm(a);
                f -= n;
            }
            t[0] |= @intFromBool(rem != 0);
        }
    }
    return e_offset;
}

// tmp1 = round(m*2^e*radix^f).
fn mul_pow_round(tmp1: *mpb_t, m: u64, e: c_int, radix1: c_int, radix_shift: c_int, f: c_int, rnd_mode: c_int) void {
    mpb_set_u64(tmp1, m);
    const e_offset = mul_pow(tmp1, radix1, radix_shift, f, 1, e);
    mpb_shr_round(tmp1, -e + e_offset, rnd_mode);
}

// return round(a*2^e_offset) rounded as a float64.
fn round_to_d(pe: *c_int, a: *mpb_t, e_offset: c_int, rnd_mode: c_int) u64 {
    var e: c_int = undefined;
    var m: u64 = undefined;
    const t = mpbTab(a);
    if (t[0] == 0 and a.len == 1) {
        m = 0;
        e = 0;
    } else {
        e = mpb_floor_log2(a) + 1 - e_offset;
        const prec1: c_int = 53;
        const e_min: c_int = -1021;
        var prec: c_int = prec1;
        if (e < e_min) {
            prec = prec1 - (e_min - e);
        }
        mpb_shr_round(a, e + e_offset - prec, rnd_mode);
        m = mpb_get_u64(a);
        m <<= @intCast(53 - prec);
        if (m >= @as(u64, 1) << 53) {
            m >>= 1;
            e += 1;
        }
    }
    pe.* = e;
    return m;
}

fn mul_pow_round_to_d(pe: *c_int, a: *mpb_t, radix1: c_int, radix_shift: c_int, f: c_int, rnd_mode: c_int) u64 {
    const e_offset = mul_pow(a, radix1, radix_shift, f, 0, 55);
    return round_to_d(pe, a, e_offset, rnd_mode);
}

export fn js_dtoa_max_len(d: f64, radix: c_int, n_digits: c_int, flags: c_int) callconv(.c) c_int {
    const fmt = flags & JS_DTOA_FORMAT_MASK;
    var n: c_int = undefined;
    var e: c_int = undefined;
    var a: u64 = undefined;
    if (fmt != JS_DTOA_FORMAT_FRAC) {
        if (fmt == JS_DTOA_FORMAT_FREE) {
            n = dtoa_max_digits_table[@intCast(radix - 2)];
        } else {
            n = n_digits;
        }
        if ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_DISABLED) {
            a = float64_as_uint64(d);
            e = @intCast((a >> 52) & 0x7ff);
            if (e == 0x7ff) {
                n = 0;
            } else {
                e -= 1023;
                n += 10 + @as(c_int, @intCast(@abs(mul_log2_radix(e - 1, radix))));
            }
        } else {
            n += 1 + 1 + 6;
        }
    } else {
        a = float64_as_uint64(d);
        e = @intCast((a >> 52) & 0x7ff);
        if (e == 0x7ff) {
            n = 0;
        } else {
            e -= 1023;
            if (e < 0) {
                n = 1;
            } else {
                n = 2 + mul_log2_radix(e - 1, radix);
            }
            n += 1 + 1 + 1 + n_digits;
        }
    }
    return max_int(n, 9);
}

fn dtoa_malloc(pptr: *[*c]u64, size: usize) [*c]u8 {
    const ret = pptr.*;
    pptr.* += (size + 7) / 8;
    return @ptrCast(ret);
}
fn dtoa_free(ptr: [*c]u8) void {
    _ = ptr;
}

export fn js_dtoa(buf: [*c]u8, d: f64, radix: c_int, n_digits: c_int, flags: c_int, tmp_mem: *JSDTOATempMem) callconv(.c) c_int {
    var mptr: [*c]u64 = &tmp_mem.mem[0];
    const fmt = flags & JS_DTOA_FORMAT_MASK;
    var E: c_int = undefined;
    var P: c_int = undefined;

    const tmp1: *mpb_t = @ptrCast(@alignCast(dtoa_malloc(&mptr, @sizeOf(mpb_t) + @sizeOf(limb_t) * DBIGNUM_LEN_MAX)));
    const mant_max: *mpb_t = @ptrCast(@alignCast(dtoa_malloc(&mptr, @sizeOf(mpb_t) + @sizeOf(limb_t) * MANT_LEN_MAX)));
    std.debug.assert((@intFromPtr(mptr) - @intFromPtr(&tmp_mem.mem[0])) / 8 <= @sizeOf(JSDTOATempMem) / 8);

    const radix_shift = ctz32(@intCast(radix));
    const radix1 = radix >> @intCast(radix_shift);
    const a = float64_as_uint64(d);
    const sgn: c_int = @intCast(a >> 63);
    var e: c_int = @intCast((a >> 52) & 0x7ff);
    var m: u64 = a & ((@as(u64, 1) << 52) - 1);
    var q = buf;
    const t1 = mpbTab(tmp1);

    done_blk: {
        output_blk: {
            if (e == 0x7ff) {
                if (m == 0) {
                    if (sgn != 0) {
                        q[0] = '-';
                        q += 1;
                    }
                    _ = memcpy(q, "Infinity", 8);
                    q += 8;
                } else {
                    _ = memcpy(q, "NaN", 3);
                    q += 3;
                }
                break :done_blk;
            } else if (e == 0) {
                if (m == 0) {
                    tmp1.len = 1;
                    t1[0] = 0;
                    E = 1;
                    if (fmt == JS_DTOA_FORMAT_FREE) {
                        P = 1;
                    } else if (fmt == JS_DTOA_FORMAT_FRAC) {
                        P = n_digits + 1;
                    } else {
                        P = n_digits;
                    }
                    if (sgn != 0 and (flags & JS_DTOA_MINUS_ZERO) != 0) {
                        q[0] = '-';
                        q += 1;
                    }
                    break :output_blk;
                }
                const l: c_int = clz64(m) - 11;
                e -= l - 1;
                m <<= @intCast(l);
            } else {
                m |= @as(u64, 1) << 52;
            }
            if (sgn != 0) {
                q[0] = '-';
                q += 1;
            }
            e -= 1022;
            if (fmt == JS_DTOA_FORMAT_FREE and
                e >= 1 and e <= 53 and
                (m & ((@as(u64, 1) << @as(u6, @intCast(53 - e))) - 1)) == 0 and
                (flags & JS_DTOA_EXP_MASK) != JS_DTOA_EXP_ENABLED)
            {
                m >>= @intCast(53 - e);
                q += u64toa_radix(q, m, @intCast(radix));
                break :done_blk;
            }

            E = 1 + mul_log2_radix(e - 1, radix);

            if (fmt == JS_DTOA_FORMAT_FREE) {
                const P_max: c_int = dtoa_max_digits_table[@intCast(radix - 2)];
                const E0 = E;
                var E_found: c_int = 0;
                var P_found: c_int = 0;
                var mant_found: u64 = 0;
                P = P_max;
                while (true) {
                    const mant_max1 = pow_ui(@intCast(radix), @intCast(P));
                    E = E0;
                    var mant: u64 = undefined;
                    while (true) {
                        mul_pow_round(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDN);
                        mant = mpb_get_u64(tmp1);
                        if (mant < mant_max1) break;
                        E += 1;
                    }
                    while ((mant % @as(u64, @intCast(radix))) == 0) {
                        mant /= @as(u64, @intCast(radix));
                        P -= 1;
                    }
                    var prec_found = false;
                    if (P_found == 0) {
                        prec_found = true;
                    } else {
                        mpb_set_u64(tmp1, mant);
                        var e1: c_int = undefined;
                        const m1 = mul_pow_round_to_d(&e1, tmp1, radix1, radix_shift, E - P, JS_RNDN);
                        if (m1 == m and e1 == e) {
                            prec_found = true;
                        }
                    }
                    if (prec_found) {
                        P_found = P;
                        E_found = E;
                        mant_found = mant;
                        if (P == 1) break;
                        P -= 1;
                    } else {
                        break;
                    }
                }
                P = P_found;
                E = E_found;
                mpb_set_u64(tmp1, mant_found);
            } else if (fmt == JS_DTOA_FORMAT_FRAC) {
                mul_pow_round(tmp1, m, e - 53, radix1, radix_shift, n_digits, JS_RNDNA);
                var len = output_digits(q, tmp1, radix, max_int(E + 1, 1) + n_digits, max_int(E + 1, 1));
                if (q[0] == '0' and len >= 2 and q[1] != '.') {
                    len -= 1;
                    _ = memmove(q, q + 1, @intCast(len));
                }
                q += @as(usize, @intCast(len));
                break :done_blk;
            } else {
                P = n_digits;
                mant_max.len = 1;
                mpbTab(mant_max)[0] = 1;
                const pow_shift = mul_pow(mant_max, radix1, radix_shift, P, 0, 0);
                mpb_shr_round(mant_max, pow_shift, JS_RNDZ);
                while (true) {
                    mul_pow_round(tmp1, m, e - 53, radix1, radix_shift, P - E, JS_RNDNA);
                    if (mpb_cmp(tmp1, mant_max) < 0) break;
                    E += 1;
                }
            }
            break :output_blk;
        }
        // output:
        var E_max: c_int = undefined;
        if (fmt == JS_DTOA_FORMAT_FIXED) {
            E_max = n_digits;
        } else {
            E_max = @as(c_int, dtoa_max_digits_table[@intCast(radix - 2)]) + 4;
        }
        if ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_ENABLED or
            ((flags & JS_DTOA_EXP_MASK) == JS_DTOA_EXP_AUTO and (E <= -6 or E > E_max)))
        {
            q += @as(usize, @intCast(output_digits(q, tmp1, radix, P, 1)));
            E -= 1;
            if (radix == 10) {
                q[0] = 'e';
                q += 1;
            } else if (radix1 == 1 and radix_shift <= 4) {
                E *= radix_shift;
                q[0] = 'p';
                q += 1;
            } else {
                q[0] = '@';
                q += 1;
            }
            if (E < 0) {
                q[0] = '-';
                q += 1;
                E = -E;
            } else {
                q[0] = '+';
                q += 1;
            }
            q += u32toa(q, @intCast(E));
        } else if (E <= 0) {
            q[0] = '0';
            q += 1;
            q[0] = '.';
            q += 1;
            var i: c_int = 0;
            while (i < -E) : (i += 1) {
                q[0] = '0';
                q += 1;
            }
            q += @as(usize, @intCast(output_digits(q, tmp1, radix, P, P)));
        } else {
            q += @as(usize, @intCast(output_digits(q, tmp1, radix, P, min_int(P, E))));
            var i: c_int = 0;
            while (i < E - P) : (i += 1) {
                q[0] = '0';
                q += 1;
            }
        }
    }
    // done:
    q[0] = 0;
    dtoa_free(@ptrCast(mant_max));
    dtoa_free(@ptrCast(tmp1));
    return @intCast(@intFromPtr(q) - @intFromPtr(buf));
}

inline fn to_digit(c: c_int) c_int {
    if (c >= '0' and c <= '9') {
        return c - '0';
    } else if (c >= 'A' and c <= 'Z') {
        return c - 'A' + 10;
    } else if (c >= 'a' and c <= 'z') {
        return c - 'a' + 10;
    } else {
        return 36;
    }
}

// r = r * radix_base + a. radix_base = 0 means radix_base = 2^32
fn mpb_mul1_base(r: *mpb_t, radix_base: limb_t, a: limb_t) void {
    const t = mpbTab(r);
    if (t[0] == 0 and r.len == 1) {
        t[0] = a;
    } else {
        if (radix_base == 0) {
            var i: c_int = r.len;
            while (i >= 0) : (i -= 1) t[@intCast(i + 1)] = t[@intCast(i)];
            t[0] = a;
        } else {
            t[@intCast(r.len)] = mp_mul1(t, t, @intCast(r.len), radix_base, a);
        }
        r.len += 1;
        mpb_renorm(r);
    }
}

export fn js_atod(str: [*c]const u8, pnext: [*c][*c]const u8, radix_in: c_int, flags: c_int, tmp_mem: *JSATODTempMem) callconv(.c) f64 {
    var radix = radix_in;
    var mptr: [*c]u64 = &tmp_mem.mem[0];
    var dval: f64 = undefined;

    const tmp0: *mpb_t = @ptrCast(@alignCast(dtoa_malloc(&mptr, @sizeOf(mpb_t) + @sizeOf(limb_t) * DBIGNUM_LEN_MAX)));
    std.debug.assert((@intFromPtr(mptr) - @intFromPtr(&tmp_mem.mem[0])) / 8 <= @sizeOf(JSATODTempMem) / 8);
    var sep: c_int = if ((flags & JS_ATOD_ACCEPT_UNDERSCORES) != 0) '_' else 256;

    var p = str;
    var is_neg: c_int = 0;
    var p_start: [*c]const u8 = undefined;
    if (p[0] == '+') {
        p += 1;
        p_start = p;
    } else if (p[0] == '-') {
        is_neg = 1;
        p += 1;
        p_start = p;
    } else {
        p_start = p;
    }

    const t0 = mpbTab(tmp0);
    var a: u64 = undefined;

    done1_blk: {
        done_blk: {
            if (p[0] == '0') {
                no_prefix: {
                    if ((p[1] == 'x' or p[1] == 'X') and (radix == 0 or radix == 16)) {
                        p += 2;
                        radix = 16;
                    } else if ((p[1] == 'o' or p[1] == 'O') and radix == 0 and (flags & JS_ATOD_ACCEPT_BIN_OCT) != 0) {
                        p += 2;
                        radix = 8;
                    } else if ((p[1] == 'b' or p[1] == 'B') and radix == 0 and (flags & JS_ATOD_ACCEPT_BIN_OCT) != 0) {
                        p += 2;
                        radix = 2;
                    } else if ((p[1] >= '0' and p[1] <= '9') and radix == 0 and (flags & JS_ATOD_ACCEPT_LEGACY_OCTAL) != 0) {
                        sep = 256;
                        var i: usize = 1;
                        while (p[i] >= '0' and p[i] <= '7') : (i += 1) {}
                        if (p[i] == '8' or p[i] == '9') break :no_prefix;
                        p += 1;
                        radix = 8;
                    } else {
                        break :no_prefix;
                    }
                    if (to_digit(p[0]) >= radix) {
                        dval = nan_val;
                        break :done1_blk;
                    }
                }
            } else {
                if ((flags & JS_ATOD_INT_ONLY) == 0 and strstart(p, "Infinity", &p) != 0) {
                    a = @as(u64, 0x7ff) << 52;
                    break :done_blk;
                }
            }
            if (radix == 0) radix = 10;

            var cur_limb: limb_t = 0;
            var expn_offset: c_int = 0;
            var digit_count: c_int = 0;
            var limb_digit_count: c_int = 0;
            const max_digits: c_int = atod_max_digits_table[@intCast(radix - 2)];
            const digits_per_limb: c_int = digits_per_limb_table[@intCast(radix - 2)];
            const radix_base: limb_t = radix_base_table[@intCast(radix - 2)];
            const radix_shift = ctz32(@intCast(radix));
            const radix1 = radix >> @intCast(radix_shift);
            var radix_bits: c_int = 0;
            if (radix1 == 1) radix_bits = radix_shift;
            tmp0.len = 1;
            t0[0] = 0;
            var extra_digits: limb_t = 0;
            var pos: c_int = 0;
            var dot_pos: c_int = -1;
            // skip leading zeros
            while (true) {
                if (p[0] == '.' and (ptrGtU(p, p_start) or to_digit(p[1]) < radix) and (flags & JS_ATOD_INT_ONLY) == 0) {
                    if (p[0] == sep) {
                        dval = nan_val;
                        break :done1_blk;
                    }
                    if (dot_pos >= 0) break;
                    dot_pos = pos;
                    p += 1;
                }
                if (p[0] == sep and ptrGtU(p, p_start) and p[1] == '0') p += 1;
                if (p[0] != '0') break;
                p += 1;
                pos += 1;
            }

            const sig_pos = pos;
            while (true) {
                if (p[0] == '.' and (ptrGtU(p, p_start) or to_digit(p[1]) < radix) and (flags & JS_ATOD_INT_ONLY) == 0) {
                    if (p[0] == sep) {
                        dval = nan_val;
                        break :done1_blk;
                    }
                    if (dot_pos >= 0) break;
                    dot_pos = pos;
                    p += 1;
                }
                if (p[0] == sep and ptrGtU(p, p_start) and to_digit(p[1]) < radix) p += 1;
                const c: limb_t = @intCast(to_digit(p[0]));
                if (c >= radix) break;
                p += 1;
                pos += 1;
                if (digit_count < max_digits) {
                    cur_limb = cur_limb * @as(limb_t, @intCast(radix)) + c;
                    limb_digit_count += 1;
                    if (limb_digit_count == digits_per_limb) {
                        mpb_mul1_base(tmp0, radix_base, cur_limb);
                        cur_limb = 0;
                        limb_digit_count = 0;
                    }
                    digit_count += 1;
                } else {
                    extra_digits |= c;
                }
            }
            if (limb_digit_count != 0) {
                mpb_mul1_base(tmp0, @intCast(pow_ui(@intCast(radix), @intCast(limb_digit_count))), cur_limb);
            }
            var is_zero: bool = undefined;
            if (digit_count == 0) {
                is_zero = true;
                expn_offset = 0;
            } else {
                is_zero = false;
                if (dot_pos < 0) dot_pos = pos;
                expn_offset = sig_pos + digit_count - dot_pos;
            }

            if (radix_bits != 0 and extra_digits != 0) {
                t0[0] |= 1;
            }

            var expn: c_int = 0;
            var expn_overflow: bool = false;
            var is_bin_exp: bool = false;
            if ((flags & JS_ATOD_INT_ONLY) == 0 and
                ((radix == 10 and (p[0] == 'e' or p[0] == 'E')) or
                    (radix != 10 and (p[0] == '@' or
                        (radix_bits >= 1 and radix_bits <= 4 and (p[0] == 'p' or p[0] == 'P'))))) and
                ptrGtU(p, p_start))
            {
                is_bin_exp = (p[0] == 'p' or p[0] == 'P');
                p += 1;
                var exp_is_neg: c_int = 0;
                if (p[0] == '+') {
                    p += 1;
                } else if (p[0] == '-') {
                    exp_is_neg = 1;
                    p += 1;
                }
                var c: c_int = to_digit(p[0]);
                if (c >= 10) {
                    dval = nan_val;
                    break :done1_blk;
                }
                expn = c;
                p += 1;
                while (true) {
                    if (p[0] == sep and to_digit(p[1]) < 10) p += 1;
                    c = to_digit(p[0]);
                    if (c >= 10) break;
                    if (!expn_overflow) {
                        if (expn > (@as(c_int, 2147483647) - 2 - 9) / 10) {
                            expn_overflow = true;
                        } else {
                            expn = expn * 10 + c;
                        }
                    }
                    p += 1;
                }
                if (exp_is_neg != 0) expn = -expn;
                if (!is_zero and expn_overflow) {
                    if (exp_is_neg != 0) {
                        a = 0;
                    } else {
                        a = @as(u64, 0x7ff) << 52;
                    }
                    break :done_blk;
                }
            }

            if (ptrEqU(p, p_start)) {
                dval = nan_val;
                break :done1_blk;
            }

            if (is_zero) {
                a = 0;
            } else {
                var e: c_int = undefined;
                var m: u64 = undefined;
                var expn1: c_int = undefined;
                ow_blk: {
                    uf_blk: {
                        if (radix_bits != 0) {
                            if (!is_bin_exp) expn *= radix_bits;
                            expn -= expn_offset * radix_bits;
                            expn1 = expn + digit_count * radix_bits;
                            if (expn1 >= 1024 + radix_bits) break :ow_blk;
                            if (expn1 <= -1075) break :uf_blk;
                            m = round_to_d(&e, tmp0, -expn, JS_RNDN);
                        } else {
                            expn -= expn_offset;
                            expn1 = expn + digit_count;
                            if (expn1 >= @as(c_int, max_exponent[@intCast(radix - 2)]) + 1) break :ow_blk;
                            if (expn1 <= min_exponent[@intCast(radix - 2)]) break :uf_blk;
                            m = mul_pow_round_to_d(&e, tmp0, radix1, radix_shift, expn, JS_RNDN);
                        }
                        if (m == 0) break :uf_blk;
                        if (e > 1024) break :ow_blk;
                        if (e < -1073) {
                            a = 0;
                        } else if (e < -1021) {
                            a = m >> @as(u6, @intCast(-e - 1021));
                        } else {
                            a = (@as(u64, @intCast(e + 1022)) << 52) | (m & ((@as(u64, 1) << 52) - 1));
                        }
                        break :done_blk;
                    }
                    // underflow:
                    a = 0;
                    break :done_blk;
                }
                // overflow:
                a = @as(u64, 0x7ff) << 52;
            }
            break :done_blk;
        }
        // done:
        a |= @as(u64, @intCast(is_neg)) << 63;
        dval = uint64_as_float64(a);
    }
    // done1:
    if (pnext != null) pnext.* = p;
    dtoa_free(@ptrCast(tmp0));
    return dval;
}

const nan_val: f64 = std.math.nan(f64);

inline fn ptrGtU(a: [*c]const u8, b: [*c]const u8) bool {
    return @intFromPtr(a) > @intFromPtr(b);
}
inline fn ptrEqU(a: [*c]const u8, b: [*c]const u8) bool {
    return @intFromPtr(a) == @intFromPtr(b);
}
