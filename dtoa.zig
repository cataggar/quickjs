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
