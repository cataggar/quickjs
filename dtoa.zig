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
