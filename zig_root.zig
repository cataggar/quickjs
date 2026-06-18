//! Root source file for libquickjs's ported Zig code.
//!
//! As C modules are ported to Zig, import them here so their exported C-ABI
//! symbols are compiled into libquickjs. The remaining C translation units link
//! against these symbols via the existing `.h` headers.

comptime {
    _ = @import("cutils.zig");
    _ = @import("libunicode.zig");
}
