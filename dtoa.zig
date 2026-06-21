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
