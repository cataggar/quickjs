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
