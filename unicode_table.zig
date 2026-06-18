//! Access to the generated Unicode tables (libunicode-table.h, Unicode 17.0).
//!
//! Zig has no Unicode Character Database in its standard library, so the
//! ported libunicode functions read the same compressed tables the C code
//! uses. translate-c emits each `static const` array as a Zig constant; only
//! the tables actually referenced are included in the final binary.

pub const c = @cImport({
    @cInclude("libunicode-table.h");
});
