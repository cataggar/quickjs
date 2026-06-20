//! Regular expression engine — Zig port of libregexp.c (incremental).
//!
//! Exported with the C ABI to match the prototypes in libregexp.h, so the
//! remaining C in libregexp.c links against them unchanged.
//!
//! First increment: the compiled-bytecode header accessors.

// Compiled bytecode header layout (libregexp.c).
const RE_HEADER_FLAGS = 0;
const RE_HEADER_CAPTURE_COUNT = 2;
const RE_HEADER_REGISTER_COUNT = 3;
const RE_HEADER_BYTECODE_LEN = 4;
const RE_HEADER_LEN = 8;

const LRE_FLAG_NAMED_GROUPS: c_int = 1 << 7;

inline fn get_u16(p: [*c]const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8);
}

inline fn get_u32(p: [*c]const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) |
        (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

export fn lre_get_alloc_count(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @as(c_int, bc_buf[RE_HEADER_CAPTURE_COUNT]) * 2 +
        @as(c_int, bc_buf[RE_HEADER_REGISTER_COUNT]);
}

export fn lre_get_capture_count(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @as(c_int, bc_buf[RE_HEADER_CAPTURE_COUNT]);
}

export fn lre_get_flags(bc_buf: [*c]const u8) callconv(.c) c_int {
    return @intCast(get_u16(bc_buf + RE_HEADER_FLAGS));
}

// Return NULL if no group names. Otherwise, return a pointer to
// 'capture_count - 1' zero terminated UTF-8 strings.
export fn lre_get_groupnames(bc_buf: [*c]const u8) callconv(.c) [*c]const u8 {
    if ((lre_get_flags(bc_buf) & LRE_FLAG_NAMED_GROUPS) == 0)
        return null;
    const re_bytecode_len = get_u32(bc_buf + RE_HEADER_BYTECODE_LEN);
    return bc_buf + RE_HEADER_LEN + re_bytecode_len;
}

// ---------------------------------------------------------------------------
// lre_parse_escape — parse a regexp/string escape after the backslash.
// Private copies of the cutils.h inline helpers it needs.
// ---------------------------------------------------------------------------

inline fn from_hex(c: u32) c_int {
    if (c >= '0' and c <= '9') {
        return @intCast(c - '0');
    } else if (c >= 'A' and c <= 'F') {
        return @intCast(c - 'A' + 10);
    } else if (c >= 'a' and c <= 'f') {
        return @intCast(c - 'a' + 10);
    } else {
        return -1;
    }
}

inline fn is_digit(c: u32) bool {
    return c >= '0' and c <= '9';
}

inline fn is_hi_surrogate(c: u32) bool {
    return (c >> 10) == (0xD800 >> 10);
}

inline fn is_lo_surrogate(c: u32) bool {
    return (c >> 10) == (0xDC00 >> 10);
}

inline fn from_surrogate(hi: u32, lo: u32) u32 {
    return 0x10000 + 0x400 * (hi - 0xD800) + (lo - 0xDC00);
}

// Parse an escape sequence, *pp points after the '\'.
//   allow_utf16: 0 none, 1 UTF-16 escapes, 2 also convert surrogate pairs.
// Return the unicode char and update *pp, -1 if malformed, -2 otherwise.
export fn lre_parse_escape(pp: [*c][*c]const u8, allow_utf16: c_int) callconv(.c) c_int {
    var p = pp[0];
    var c: u32 = p[0];
    p += 1;
    switch (c) {
        'b' => c = 0x08,
        'f' => c = 0x0c,
        'n' => c = 0x0a,
        'r' => c = 0x0d,
        't' => c = 0x09,
        'v' => c = 0x0b,
        'x' => {
            const h0 = from_hex(p[0]);
            p += 1;
            if (h0 < 0) return -1;
            const h1 = from_hex(p[0]);
            p += 1;
            if (h1 < 0) return -1;
            c = @intCast((h0 << 4) | h1);
        },
        'u' => {
            if (p[0] == '{' and allow_utf16 != 0) {
                p += 1;
                c = 0;
                while (true) {
                    const h = from_hex(p[0]);
                    p += 1;
                    if (h < 0) return -1;
                    c = (c << 4) | @as(u32, @intCast(h));
                    if (c > 0x10FFFF) return -1;
                    if (p[0] == '}') break;
                }
                p += 1;
            } else {
                c = 0;
                var i: c_int = 0;
                while (i < 4) : (i += 1) {
                    const h = from_hex(p[0]);
                    p += 1;
                    if (h < 0) return -1;
                    c = (c << 4) | @as(u32, @intCast(h));
                }
                if (is_hi_surrogate(c) and allow_utf16 == 2 and p[0] == '\\' and p[1] == 'u') {
                    // convert an escaped surrogate pair into a unicode char
                    var c1: u32 = 0;
                    var k: c_int = 0;
                    while (k < 4) : (k += 1) {
                        const h = from_hex(p[@intCast(2 + k)]);
                        if (h < 0) break;
                        c1 = (c1 << 4) | @as(u32, @intCast(h));
                    }
                    if (k == 4 and is_lo_surrogate(c1)) {
                        p += 6;
                        c = from_surrogate(c, c1);
                    }
                }
            }
        },
        '0'...'7' => {
            c -= '0';
            if (allow_utf16 == 2) {
                // only accept \0 not followed by digit
                if (c != 0 or is_digit(p[0])) return -1;
            } else {
                // parse a legacy octal sequence
                oct: {
                    var v: u32 = @as(u32, p[0]) -% '0';
                    if (v > 7) break :oct;
                    c = (c << 3) | v;
                    p += 1;
                    if (c >= 32) break :oct;
                    v = @as(u32, p[0]) -% '0';
                    if (v > 7) break :oct;
                    c = (c << 3) | v;
                    p += 1;
                }
            }
        },
        else => return -2,
    }
    pp[0] = p;
    return @intCast(c);
}

// ---------------------------------------------------------------------------
// compute_register_count — walk the compiled bytecode to size the register
// stack and patch register indices. Opcode sizes/values come from C exports.
// ---------------------------------------------------------------------------

const RE_HEADER_LEN_C = 8; // RE_HEADER_LEN

extern const zig_reopcode_size: [*]const u8;
extern const zig_REGISTER_COUNT_MAX: c_int;
extern const zig_REOP_set_i32: c_int;
extern const zig_REOP_set_char_pos: c_int;
extern const zig_REOP_check_advance: c_int;
extern const zig_REOP_loop: c_int;
extern const zig_REOP_loop_split_goto_first: c_int;
extern const zig_REOP_loop_split_next_first: c_int;
extern const zig_REOP_loop_check_adv_split_goto_first: c_int;
extern const zig_REOP_loop_check_adv_split_next_first: c_int;
extern const zig_REOP_range: c_int;
extern const zig_REOP_range_i: c_int;
extern const zig_REOP_range32: c_int;
extern const zig_REOP_range32_i: c_int;
extern const zig_REOP_back_reference: c_int;
extern const zig_REOP_back_reference_i: c_int;
extern const zig_REOP_backward_back_reference: c_int;
extern const zig_REOP_backward_back_reference_i: c_int;

export fn compute_register_count(bc_buf_in: [*c]u8, bc_buf_len_in: c_int) callconv(.c) c_int {
    var stack_size: c_int = 0;
    var stack_size_max: c_int = 0;
    const bc_buf = bc_buf_in + RE_HEADER_LEN_C;
    const bc_buf_len = bc_buf_len_in - RE_HEADER_LEN_C;
    var pos: c_int = 0;
    while (pos < bc_buf_len) {
        const opcode = bc_buf[@intCast(pos)];
        var len: c_int = zig_reopcode_size[opcode];
        if (opcode == zig_REOP_set_i32 or opcode == zig_REOP_set_char_pos) {
            bc_buf[@intCast(pos + 1)] = @intCast(stack_size);
            stack_size += 1;
            if (stack_size > stack_size_max) {
                if (stack_size > zig_REGISTER_COUNT_MAX) return -1;
                stack_size_max = stack_size;
            }
        } else if (opcode == zig_REOP_check_advance or opcode == zig_REOP_loop or
            opcode == zig_REOP_loop_split_goto_first or opcode == zig_REOP_loop_split_next_first)
        {
            stack_size -= 1;
            bc_buf[@intCast(pos + 1)] = @intCast(stack_size);
        } else if (opcode == zig_REOP_loop_check_adv_split_goto_first or
            opcode == zig_REOP_loop_check_adv_split_next_first)
        {
            stack_size -= 2;
            bc_buf[@intCast(pos + 1)] = @intCast(stack_size);
        } else if (opcode == zig_REOP_range or opcode == zig_REOP_range_i) {
            const val = get_u16(bc_buf + @as(usize, @intCast(pos)) + 1);
            len += @as(c_int, @intCast(val)) * 4;
        } else if (opcode == zig_REOP_range32 or opcode == zig_REOP_range32_i) {
            const val = get_u16(bc_buf + @as(usize, @intCast(pos)) + 1);
            len += @as(c_int, @intCast(val)) * 8;
        } else if (opcode == zig_REOP_back_reference or opcode == zig_REOP_back_reference_i or
            opcode == zig_REOP_backward_back_reference or opcode == zig_REOP_backward_back_reference_i)
        {
            const val = bc_buf[@intCast(pos + 1)];
            len += @as(c_int, val);
        }
        pos += len;
    }
    return stack_size_max;
}

// ===========================================================================
// Backtracking VM: lre_exec / lre_exec_backtrack (port of the C executor).
// ===========================================================================

extern fn memcpy(noalias dest: ?*anyopaque, noalias src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn lre_realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn lre_check_timeout(opaque_ptr: ?*anyopaque) callconv(.c) c_int;
extern fn lre_canonicalize(c: u32, is_unicode: c_int) callconv(.c) c_int;
extern fn lre_is_space_non_ascii(c: u32) callconv(.c) c_int;
extern const lre_ctype_bits: [256]u8;

// Opcodes (mirror of libregexp-opcode.h order). A runtime check in lre_exec
// asserts these match the C-exported values.
const REOP = struct {
    const invalid: u32 = 0;
    const char: u32 = 1;
    const char_i: u32 = 2;
    const char32: u32 = 3;
    const char32_i: u32 = 4;
    const dot: u32 = 5;
    const any: u32 = 6;
    const space: u32 = 7;
    const not_space: u32 = 8;
    const line_start: u32 = 9;
    const line_start_m: u32 = 10;
    const line_end: u32 = 11;
    const line_end_m: u32 = 12;
    const goto_: u32 = 13;
    const split_goto_first: u32 = 14;
    const split_next_first: u32 = 15;
    const match: u32 = 16;
    const lookahead_match: u32 = 17;
    const negative_lookahead_match: u32 = 18;
    const save_start: u32 = 19;
    const save_end: u32 = 20;
    const save_reset: u32 = 21;
    const loop: u32 = 22;
    const loop_split_goto_first: u32 = 23;
    const loop_split_next_first: u32 = 24;
    const loop_check_adv_split_goto_first: u32 = 25;
    const loop_check_adv_split_next_first: u32 = 26;
    const set_i32: u32 = 27;
    const word_boundary: u32 = 28;
    const word_boundary_i: u32 = 29;
    const not_word_boundary: u32 = 30;
    const not_word_boundary_i: u32 = 31;
    const back_reference: u32 = 32;
    const back_reference_i: u32 = 33;
    const backward_back_reference: u32 = 34;
    const backward_back_reference_i: u32 = 35;
    const range: u32 = 36;
    const range_i: u32 = 37;
    const range32: u32 = 38;
    const range32_i: u32 = 39;
    const lookahead: u32 = 40;
    const negative_lookahead: u32 = 41;
    const set_char_pos: u32 = 42;
    const check_advance: u32 = 43;
    const prev: u32 = 44;
};

const RE_EXEC_STATE_SPLIT: u32 = 0;
const RE_EXEC_STATE_LOOKAHEAD: u32 = 1;
const RE_EXEC_STATE_NEGATIVE_LOOKAHEAD: u32 = 2;

const LRE_RET_MEMORY_ERROR: isize = -1;
const LRE_RET_TIMEOUT: isize = -2;
const INTERRUPT_COUNTER_INIT: c_int = 10000;
const CP_LS: u32 = 0x2028;
const CP_PS: u32 = 0x2029;

const LRE_FLAG_UNICODE: c_int = 1 << 4;
const LRE_FLAG_UNICODE_SETS: c_int = 1 << 8;

const UNICODE_C_SPACE: u8 = 1 << 0;
const UNICODE_C_DIGIT: u8 = 1 << 1;
const UNICODE_C_UPPER: u8 = 1 << 2;
const UNICODE_C_LOWER: u8 = 1 << 3;
const UNICODE_C_UNDER: u8 = 1 << 4;

const BP_TYPE_BITS: usize = if (@sizeOf(usize) >= 8) 3 else 2;
const BP_SHIFT: u6 = @intCast(@sizeOf(usize) * 8 - BP_TYPE_BITS);
const BP_MASK: usize = (@as(usize, 1) << BP_SHIFT) - 1;

const StackElem = extern union {
    ptr: [*c]u8,
    val: isize,
};

const REExecContext = extern struct {
    cbuf: [*c]const u8,
    cbuf_end: [*c]const u8,
    cbuf_type: c_int,
    capture_count: c_int,
    is_unicode: c_int,
    interrupt_counter: c_int,
    opaque_ptr: ?*anyopaque,
    stack_buf: [*c]StackElem,
    stack_size: usize,
    static_stack_buf: [32]StackElem,
};

inline fn bpType(e: StackElem) u32 {
    return @intCast(@as(usize, @bitCast(e.val)) >> BP_SHIFT);
}
inline fn bpVal(e: StackElem) usize {
    return @as(usize, @bitCast(e.val)) & BP_MASK;
}
inline fn makeBp(off: usize, typ: u32) StackElem {
    return .{ .val = @bitCast((off & BP_MASK) | (@as(usize, typ) << BP_SHIFT)) };
}

inline fn lre_is_word_byte(ch: u8) bool {
    return (lre_ctype_bits[ch] & (UNICODE_C_UPPER | UNICODE_C_LOWER | UNICODE_C_UNDER | UNICODE_C_DIGIT)) != 0;
}
inline fn lre_is_space(c: u32) bool {
    if (c < 256) return (lre_ctype_bits[c] & UNICODE_C_SPACE) != 0;
    return lre_is_space_non_ascii(c) != 0;
}
inline fn is_line_terminator(c: u32) bool {
    return c == '\n' or c == '\r' or c == CP_LS or c == CP_PS;
}

// signed relative pc jump
inline fn pcRel(pc: [*c]const u8, off: i32) [*c]const u8 {
    const base: isize = @bitCast(@intFromPtr(pc));
    return @ptrFromInt(@as(usize, @bitCast(base + off)));
}

inline fn ptrLt(a: anytype, b: anytype) bool {
    return @intFromPtr(a) < @intFromPtr(b);
}
inline fn ptrGt(a: anytype, b: anytype) bool {
    return @intFromPtr(a) > @intFromPtr(b);
}
inline fn ptrGe(a: anytype, b: anytype) bool {
    return @intFromPtr(a) >= @intFromPtr(b);
}
inline fn ptrEq(a: anytype, b: anytype) bool {
    return @intFromPtr(a) == @intFromPtr(b);
}

// --- character readers (port of the GET/PEEK/PREV_CHAR macros) ---
inline fn getChar(cptr: *[*c]const u8, cbuf_end: [*c]const u8, cbuf_type: c_int) u32 {
    if (cbuf_type == 0) {
        const c: u32 = cptr.*[0];
        cptr.* += 1;
        return c;
    }
    var p: [*c]const u16 = @ptrCast(@alignCast(cptr.*));
    const end: [*c]const u16 = @ptrCast(@alignCast(cbuf_end));
    var c: u32 = p[0];
    p += 1;
    if (is_hi_surrogate(c) and cbuf_type == 2) {
        if (ptrLt(p, end) and is_lo_surrogate(p[0])) {
            c = from_surrogate(c, p[0]);
            p += 1;
        }
    }
    cptr.* = @ptrCast(p);
    return c;
}
inline fn peekChar(cptr: [*c]const u8, cbuf_end: [*c]const u8, cbuf_type: c_int) u32 {
    if (cbuf_type == 0) return cptr[0];
    var p: [*c]const u16 = @ptrCast(@alignCast(cptr));
    const end: [*c]const u16 = @ptrCast(@alignCast(cbuf_end));
    var c: u32 = p[0];
    p += 1;
    if (is_hi_surrogate(c) and cbuf_type == 2) {
        if (ptrLt(p, end) and is_lo_surrogate(p[0])) {
            c = from_surrogate(c, p[0]);
        }
    }
    return c;
}
inline fn getPrevChar(cptr: *[*c]const u8, cbuf_start: [*c]const u8, cbuf_type: c_int) u32 {
    if (cbuf_type == 0) {
        cptr.* -= 1;
        return cptr.*[0];
    }
    var p: [*c]const u16 = @ptrCast(@alignCast(cptr.*));
    p -= 1;
    const start: [*c]const u16 = @ptrCast(@alignCast(cbuf_start));
    var c: u32 = p[0];
    if (is_lo_surrogate(c) and cbuf_type == 2) {
        if (ptrGt(p, start) and is_hi_surrogate((p - 1)[0])) {
            p -= 1;
            c = from_surrogate(p[0], c);
        }
    }
    cptr.* = @ptrCast(p);
    return c;
}
inline fn peekPrevChar(cptr: [*c]const u8, cbuf_start: [*c]const u8, cbuf_type: c_int) u32 {
    if (cbuf_type == 0) return (cptr - 1)[0];
    var p: [*c]const u16 = @ptrCast(@alignCast(cptr));
    p -= 1;
    const start: [*c]const u16 = @ptrCast(@alignCast(cbuf_start));
    var c: u32 = p[0];
    if (is_lo_surrogate(c) and cbuf_type == 2) {
        if (ptrGt(p, start) and is_hi_surrogate((p - 1)[0])) {
            c = from_surrogate((p - 1)[0], c);
        }
    }
    return c;
}
inline fn prevChar(cptr: *[*c]const u8, cbuf_start: [*c]const u8, cbuf_type: c_int) void {
    if (cbuf_type == 0) {
        cptr.* -= 1;
        return;
    }
    var p: [*c]const u16 = @ptrCast(@alignCast(cptr.*));
    p -= 1;
    const start: [*c]const u16 = @ptrCast(@alignCast(cbuf_start));
    if (is_lo_surrogate(p[0]) and cbuf_type == 2) {
        if (ptrGt(p, start) and is_hi_surrogate((p - 1)[0])) {
            p -= 1;
        }
    }
    cptr.* = @ptrCast(p);
}

fn lre_poll_timeout(s: *REExecContext) c_int {
    s.interrupt_counter -= 1;
    if (s.interrupt_counter <= 0) {
        s.interrupt_counter = INTERRUPT_COUNTER_INIT;
        if (lre_check_timeout(s.opaque_ptr) != 0) return @intCast(LRE_RET_TIMEOUT);
    }
    return 0;
}

fn stack_realloc(s: *REExecContext, n: usize) c_int {
    var new_size = s.stack_size * 3 / 2;
    if (new_size < n) new_size = n;
    if (ptrEq(s.stack_buf, &s.static_stack_buf)) {
        const new_stack = lre_realloc(s.opaque_ptr, null, new_size * @sizeOf(StackElem));
        if (new_stack == null) return -1;
        _ = memcpy(new_stack, @ptrCast(s.stack_buf), s.stack_size * @sizeOf(StackElem));
        s.stack_buf = @ptrCast(@alignCast(new_stack));
    } else {
        const new_stack = lre_realloc(s.opaque_ptr, @ptrCast(s.stack_buf), new_size * @sizeOf(StackElem));
        if (new_stack == null) return -1;
        s.stack_buf = @ptrCast(@alignCast(new_stack));
    }
    s.stack_size = new_size;
    return 0;
}

inline fn stackOff(s: *REExecContext, p: [*c]StackElem) usize {
    return (@intFromPtr(p) - @intFromPtr(s.stack_buf)) / @sizeOf(StackElem);
}

// CHECK_STACK_SPACE: ensure room for n elems; returns false on OOM.
inline fn checkStackSpace(s: *REExecContext, sp: *[*c]StackElem, bp: *[*c]StackElem, stack_end: *[*c]StackElem, n: usize) bool {
    if ((@intFromPtr(stack_end.*) - @intFromPtr(sp.*)) / @sizeOf(StackElem) < n) {
        const saved_sp = stackOff(s, sp.*);
        const saved_bp = stackOff(s, bp.*);
        if (stack_realloc(s, saved_sp + n) != 0) return false;
        stack_end.* = s.stack_buf + s.stack_size;
        sp.* = s.stack_buf + saved_sp;
        bp.* = s.stack_buf + saved_bp;
    }
    return true;
}

// SAVE_CAPTURE: push (idx, capture[idx]) undo record, then set capture[idx].
inline fn saveCapture(s: *REExecContext, capture: [*c][*c]u8, sp: *[*c]StackElem, bp: *[*c]StackElem, stack_end: *[*c]StackElem, idx: u32, value: [*c]u8) !void {
    if (!checkStackSpace(s, sp, bp, stack_end, 2)) return error.OutOfMemory;
    sp.*[0].val = idx;
    sp.*[1].ptr = capture[idx];
    sp.* += 2;
    capture[idx] = value;
}

// return 1 if match, 0 if not match or < 0 if error.
fn lre_exec_backtrack(s: *REExecContext, capture: [*c][*c]u8, pc_in: [*c]const u8, cptr_in: [*c]const u8) isize {
    var pc = pc_in;
    var cptr = cptr_in;
    const cbuf_type = s.cbuf_type;
    const cbuf_end = s.cbuf_end;
    var sp = s.stack_buf;
    var bp = s.stack_buf;
    var stack_end = s.stack_buf + s.stack_size;
    var val: u32 = undefined;
    var c: u32 = undefined;
    var idx: u32 = undefined;

    main: while (true) {
        const opcode: u32 = pc[0];
        pc += 1;
        backtrack: {
            switch (opcode) {
                REOP.match => return 1,
                REOP.lookahead_match => {
                    // pop saved states until reaching the start of the lookahead,
                    // keeping updated captures/vars and corresponding undo info.
                    var sp1: [*c]StackElem = undefined;
                    const sp_top = sp;
                    while (true) {
                        sp1 = sp;
                        sp = bp;
                        pc = @ptrCast((sp - 3)[0].ptr);
                        cptr = @ptrCast((sp - 2)[0].ptr);
                        const typ = bpType((sp - 1)[0]);
                        bp = s.stack_buf + bpVal((sp - 1)[0]);
                        (sp - 1)[0].ptr = @ptrCast(sp1); // save the next value for the copy step
                        sp -= 3;
                        if (typ == RE_EXEC_STATE_LOOKAHEAD) break;
                    }
                    if (sp != s.stack_buf) {
                        sp1 = sp;
                        while (ptrLt(sp1, sp_top)) {
                            const next_sp: [*c]StackElem = @ptrCast(@alignCast(sp1[2].ptr));
                            sp1 += 3;
                            while (ptrLt(sp1, next_sp)) {
                                sp[0] = sp1[0];
                                sp += 1;
                                sp1 += 1;
                            }
                        }
                    }
                    continue :main;
                },
                REOP.negative_lookahead_match => {
                    while (true) {
                        // undo the modifications to capture[]
                        while (ptrGt(sp, bp)) {
                            capture[@intCast((sp - 2)[0].val)] = (sp - 1)[0].ptr;
                            sp -= 2;
                        }
                        pc = @ptrCast((sp - 3)[0].ptr);
                        cptr = @ptrCast((sp - 2)[0].ptr);
                        const typ = bpType((sp - 1)[0]);
                        bp = s.stack_buf + bpVal((sp - 1)[0]);
                        sp -= 3;
                        if (typ == RE_EXEC_STATE_NEGATIVE_LOOKAHEAD) break;
                    }
                    break :backtrack; // goto no_match
                },
                REOP.char32, REOP.char32_i, REOP.char, REOP.char_i => {
                    if (opcode == REOP.char32 or opcode == REOP.char32_i) {
                        val = get_u32(pc);
                        pc += 4;
                    } else {
                        val = get_u16(pc);
                        pc += 2;
                    }
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (opcode == REOP.char_i or opcode == REOP.char32_i)
                        c = @intCast(lre_canonicalize(c, s.is_unicode));
                    if (val != c) break :backtrack;
                    continue :main;
                },
                REOP.split_goto_first, REOP.split_next_first => {
                    val = get_u32(pc);
                    pc += 4;
                    var pc1: [*c]const u8 = undefined;
                    if (opcode == REOP.split_next_first) {
                        pc1 = pcRel(pc, @bitCast(val));
                    } else {
                        pc1 = pc;
                        pc = pcRel(pc, @bitCast(val));
                    }
                    if (!checkStackSpace(s, &sp, &bp, &stack_end, 3)) return LRE_RET_MEMORY_ERROR;
                    sp[0].ptr = @constCast(pc1);
                    sp[1].ptr = @constCast(cptr);
                    sp[2] = makeBp(stackOff(s, bp), RE_EXEC_STATE_SPLIT);
                    sp += 3;
                    bp = sp;
                    continue :main;
                },
                REOP.lookahead, REOP.negative_lookahead => {
                    val = get_u32(pc);
                    pc += 4;
                    if (!checkStackSpace(s, &sp, &bp, &stack_end, 3)) return LRE_RET_MEMORY_ERROR;
                    sp[0].ptr = @constCast(pcRel(pc, @bitCast(val)));
                    sp[1].ptr = @constCast(cptr);
                    sp[2] = makeBp(stackOff(s, bp), RE_EXEC_STATE_LOOKAHEAD + (opcode - REOP.lookahead));
                    sp += 3;
                    bp = sp;
                    continue :main;
                },
                REOP.goto_ => {
                    val = get_u32(pc);
                    pc = pcRel(pc, @as(i32, @bitCast(val)) + 4);
                    if (lre_poll_timeout(s) != 0) return LRE_RET_TIMEOUT;
                    continue :main;
                },
                REOP.line_start, REOP.line_start_m => {
                    if (ptrEq(cptr, s.cbuf)) continue :main;
                    if (opcode == REOP.line_start) break :backtrack;
                    c = peekPrevChar(cptr, s.cbuf, cbuf_type);
                    if (!is_line_terminator(c)) break :backtrack;
                    continue :main;
                },
                REOP.line_end, REOP.line_end_m => {
                    if (ptrEq(cptr, cbuf_end)) continue :main;
                    if (opcode == REOP.line_end) break :backtrack;
                    c = peekChar(cptr, cbuf_end, cbuf_type);
                    if (!is_line_terminator(c)) break :backtrack;
                    continue :main;
                },
                REOP.dot => {
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (is_line_terminator(c)) break :backtrack;
                    continue :main;
                },
                REOP.any => {
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    _ = getChar(&cptr, cbuf_end, cbuf_type);
                    continue :main;
                },
                REOP.space => {
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (!lre_is_space(c)) break :backtrack;
                    continue :main;
                },
                REOP.not_space => {
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (lre_is_space(c)) break :backtrack;
                    continue :main;
                },
                REOP.save_start, REOP.save_end => {
                    val = pc[0];
                    pc += 1;
                    idx = 2 * val + (opcode - REOP.save_start);
                    if (!checkStackSpace(s, &sp, &bp, &stack_end, 2)) return LRE_RET_MEMORY_ERROR;
                    sp[0].val = idx;
                    sp[1].ptr = capture[idx];
                    sp += 2;
                    capture[idx] = @constCast(cptr);
                    continue :main;
                },
                REOP.save_reset => {
                    val = pc[0];
                    const val2: u32 = pc[1];
                    pc += 2;
                    if (!checkStackSpace(s, &sp, &bp, &stack_end, 2 * (val2 - val + 1))) return LRE_RET_MEMORY_ERROR;
                    while (val <= val2) : (val += 1) {
                        saveCapture(s, capture, &sp, &bp, &stack_end, 2 * val, null) catch return LRE_RET_MEMORY_ERROR;
                        saveCapture(s, capture, &sp, &bp, &stack_end, 2 * val + 1, null) catch return LRE_RET_MEMORY_ERROR;
                    }
                    continue :main;
                },
                REOP.set_i32 => {
                    idx = 2 * @as(u32, @intCast(s.capture_count)) + pc[0];
                    val = get_u32(pc + 1);
                    pc += 5;
                    saveCaptureCheck(s, capture, &sp, &bp, &stack_end, idx) catch return LRE_RET_MEMORY_ERROR;
                    capture[idx] = @ptrFromInt(val);
                    continue :main;
                },
                REOP.loop => {
                    idx = 2 * @as(u32, @intCast(s.capture_count)) + pc[0];
                    val = get_u32(pc + 1);
                    pc += 5;
                    const val2: usize = @intFromPtr(capture[idx]) -% 1;
                    saveCaptureCheck(s, capture, &sp, &bp, &stack_end, idx) catch return LRE_RET_MEMORY_ERROR;
                    capture[idx] = @ptrFromInt(val2);
                    if (val2 != 0) {
                        pc = pcRel(pc, @bitCast(val));
                        if (lre_poll_timeout(s) != 0) return LRE_RET_TIMEOUT;
                    }
                    continue :main;
                },
                REOP.loop_split_goto_first, REOP.loop_split_next_first, REOP.loop_check_adv_split_goto_first, REOP.loop_check_adv_split_next_first => {
                    idx = 2 * @as(u32, @intCast(s.capture_count)) + pc[0];
                    const limit = get_u32(pc + 1);
                    val = get_u32(pc + 5);
                    pc += 9;
                    const val2: usize = @intFromPtr(capture[idx]) -% 1;
                    saveCaptureCheck(s, capture, &sp, &bp, &stack_end, idx) catch return LRE_RET_MEMORY_ERROR;
                    capture[idx] = @ptrFromInt(val2);
                    if (val2 > limit) {
                        pc = pcRel(pc, @bitCast(val));
                        if (lre_poll_timeout(s) != 0) return LRE_RET_TIMEOUT;
                    } else {
                        if ((opcode == REOP.loop_check_adv_split_goto_first or opcode == REOP.loop_check_adv_split_next_first) and
                            ptrEq(capture[idx + 1], cptr) and val2 != limit)
                        {
                            break :backtrack;
                        }
                        if (val2 != 0) {
                            var pc1: [*c]const u8 = undefined;
                            if (opcode == REOP.loop_split_next_first or opcode == REOP.loop_check_adv_split_next_first) {
                                pc1 = pcRel(pc, @bitCast(val));
                            } else {
                                pc1 = pc;
                                pc = pcRel(pc, @bitCast(val));
                            }
                            if (!checkStackSpace(s, &sp, &bp, &stack_end, 3)) return LRE_RET_MEMORY_ERROR;
                            sp[0].ptr = @constCast(pc1);
                            sp[1].ptr = @constCast(cptr);
                            sp[2] = makeBp(stackOff(s, bp), RE_EXEC_STATE_SPLIT);
                            sp += 3;
                            bp = sp;
                        }
                    }
                    continue :main;
                },
                REOP.set_char_pos => {
                    idx = 2 * @as(u32, @intCast(s.capture_count)) + pc[0];
                    pc += 1;
                    saveCaptureCheck(s, capture, &sp, &bp, &stack_end, idx) catch return LRE_RET_MEMORY_ERROR;
                    capture[idx] = @constCast(cptr);
                    continue :main;
                },
                REOP.check_advance => {
                    idx = 2 * @as(u32, @intCast(s.capture_count)) + pc[0];
                    pc += 1;
                    if (ptrEq(capture[idx], cptr)) break :backtrack;
                    continue :main;
                },
                REOP.word_boundary, REOP.word_boundary_i, REOP.not_word_boundary, REOP.not_word_boundary_i => {
                    const ignore_case = (opcode == REOP.word_boundary_i or opcode == REOP.not_word_boundary_i);
                    const is_boundary = (opcode == REOP.word_boundary or opcode == REOP.word_boundary_i);
                    var v1: bool = undefined;
                    var v2: bool = undefined;
                    if (ptrEq(cptr, s.cbuf)) {
                        v1 = false;
                    } else {
                        c = peekPrevChar(cptr, s.cbuf, cbuf_type);
                        if (c < 256) v1 = lre_is_word_byte(@intCast(c)) else v1 = ignore_case and (c == 0x017f or c == 0x212a);
                    }
                    if (ptrGe(cptr, cbuf_end)) {
                        v2 = false;
                    } else {
                        c = peekChar(cptr, cbuf_end, cbuf_type);
                        if (c < 256) v2 = lre_is_word_byte(@intCast(c)) else v2 = ignore_case and (c == 0x017f or c == 0x212a);
                    }
                    if ((v1 != v2) != is_boundary) break :backtrack;
                    continue :main;
                },
                REOP.back_reference, REOP.back_reference_i, REOP.backward_back_reference, REOP.backward_back_reference_i => {
                    const n: u32 = pc[0];
                    pc += 1;
                    const pc1 = pc;
                    pc += n;
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        val = pc1[i];
                        if (val >= @as(u32, @intCast(s.capture_count))) break :backtrack;
                        const cptr1_start = capture[2 * val];
                        const cptr1_end = capture[2 * val + 1];
                        if (cptr1_start != null and cptr1_end != null) {
                            if (opcode == REOP.back_reference or opcode == REOP.back_reference_i) {
                                var cptr1: [*c]const u8 = cptr1_start;
                                while (ptrLt(cptr1, cptr1_end)) {
                                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                                    var c1 = getChar(&cptr1, cptr1_end, cbuf_type);
                                    var c2 = getChar(&cptr, cbuf_end, cbuf_type);
                                    if (opcode == REOP.back_reference_i) {
                                        c1 = @intCast(lre_canonicalize(c1, s.is_unicode));
                                        c2 = @intCast(lre_canonicalize(c2, s.is_unicode));
                                    }
                                    if (c1 != c2) break :backtrack;
                                }
                            } else {
                                var cptr1: [*c]const u8 = cptr1_end;
                                while (ptrGt(cptr1, cptr1_start)) {
                                    if (ptrEq(cptr, s.cbuf)) break :backtrack;
                                    var c1 = getPrevChar(&cptr1, cptr1_start, cbuf_type);
                                    var c2 = getPrevChar(&cptr, s.cbuf, cbuf_type);
                                    if (opcode == REOP.backward_back_reference_i) {
                                        c1 = @intCast(lre_canonicalize(c1, s.is_unicode));
                                        c2 = @intCast(lre_canonicalize(c2, s.is_unicode));
                                    }
                                    if (c1 != c2) break :backtrack;
                                }
                            }
                            break;
                        }
                    }
                    continue :main;
                },
                REOP.range, REOP.range_i => {
                    const n: u32 = get_u16(pc);
                    pc += 2;
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (opcode == REOP.range_i) c = @intCast(lre_canonicalize(c, s.is_unicode));
                    var idx_min: u32 = 0;
                    var low: u32 = get_u16(pc);
                    if (c < low) break :backtrack;
                    var idx_max: u32 = n - 1;
                    var high: u32 = get_u16(pc + idx_max * 4 + 2);
                    if (c >= 0xffff and high == 0xffff) {
                        pc += 4 * n;
                        continue :main;
                    }
                    if (c > high) break :backtrack;
                    while (idx_min <= idx_max) {
                        const m = (idx_min + idx_max) / 2;
                        low = get_u16(pc + m * 4);
                        high = get_u16(pc + m * 4 + 2);
                        if (c < low) {
                            idx_max = m - 1;
                        } else if (c > high) {
                            idx_min = m + 1;
                        } else {
                            pc += 4 * n;
                            continue :main;
                        }
                    }
                    break :backtrack;
                },
                REOP.range32, REOP.range32_i => {
                    const n: u32 = get_u16(pc);
                    pc += 2;
                    if (ptrGe(cptr, cbuf_end)) break :backtrack;
                    c = getChar(&cptr, cbuf_end, cbuf_type);
                    if (opcode == REOP.range32_i) c = @intCast(lre_canonicalize(c, s.is_unicode));
                    var idx_min: u32 = 0;
                    var low: u32 = get_u32(pc);
                    if (c < low) break :backtrack;
                    var idx_max: u32 = n - 1;
                    var high: u32 = get_u32(pc + idx_max * 8 + 4);
                    if (c > high) break :backtrack;
                    while (idx_min <= idx_max) {
                        const m = (idx_min + idx_max) / 2;
                        low = get_u32(pc + m * 8);
                        high = get_u32(pc + m * 8 + 4);
                        if (c < low) {
                            idx_max = m - 1;
                        } else if (c > high) {
                            idx_min = m + 1;
                        } else {
                            pc += 8 * n;
                            continue :main;
                        }
                    }
                    break :backtrack;
                },
                REOP.prev => {
                    if (ptrEq(cptr, s.cbuf)) break :backtrack;
                    prevChar(&cptr, s.cbuf, cbuf_type);
                    continue :main;
                },
                else => @panic("unknown regexp opcode"),
            }
        }
        // ===== no_match: backtrack =====
        while (true) {
            if (bp == s.stack_buf) return 0;
            while (ptrGt(sp, bp)) {
                capture[@intCast((sp - 2)[0].val)] = (sp - 1)[0].ptr;
                sp -= 2;
            }
            pc = @ptrCast((sp - 3)[0].ptr);
            cptr = @ptrCast((sp - 2)[0].ptr);
            const typ = bpType((sp - 1)[0]);
            bp = s.stack_buf + bpVal((sp - 1)[0]);
            sp -= 3;
            if (typ != RE_EXEC_STATE_LOOKAHEAD) break;
        }
        if (lre_poll_timeout(s) != 0) return LRE_RET_TIMEOUT;
    }
}

// SAVE_CAPTURE_CHECK: avoid saving the previous value if already saved.
inline fn saveCaptureCheck(s: *REExecContext, capture: [*c][*c]u8, sp: *[*c]StackElem, bp: *[*c]StackElem, stack_end: *[*c]StackElem, idx: u32) !void {
    var sp1 = sp.*;
    while (true) {
        if (ptrGt(sp1, bp.*)) {
            if ((sp1 - 2)[0].val == idx) break;
            sp1 -= 2;
        } else {
            if (!checkStackSpace(s, sp, bp, stack_end, 2)) return error.OutOfMemory;
            sp.*[0].val = idx;
            sp.*[1].ptr = capture[idx];
            sp.* += 2;
            break;
        }
    }
}

export fn lre_exec(capture: [*c][*c]u8, bc_buf: [*c]const u8, cbuf: [*c]const u8, cindex: c_int, clen: c_int, cbuf_type_in: c_int, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    // Drift guard: Zig opcode constants must match the C-exported values.
    std.debug.assert(REOP.match == @as(u32, @intCast(zig_REOP_match)) and
        REOP.set_i32 == @as(u32, @intCast(zig_REOP_set_i32)) and
        REOP.prev == @as(u32, @intCast(zig_REOP_prev)));

    var s_s: REExecContext = undefined;
    const s = &s_s;
    const cbuf_type = cbuf_type_in;
    const re_flags = lre_get_flags(bc_buf);
    s.is_unicode = @intFromBool((re_flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS)) != 0);
    s.capture_count = bc_buf[RE_HEADER_CAPTURE_COUNT];
    s.cbuf = cbuf;
    s.cbuf_end = cbuf + (@as(usize, @intCast(clen)) << @as(u6, @intCast(cbuf_type)));
    s.cbuf_type = cbuf_type;
    if (s.cbuf_type == 1 and s.is_unicode != 0) s.cbuf_type = 2;
    s.interrupt_counter = INTERRUPT_COUNTER_INIT;
    s.opaque_ptr = opaque_ptr;
    s.stack_buf = &s.static_stack_buf;
    s.stack_size = s.static_stack_buf.len;

    var i: c_int = 0;
    while (i < s.capture_count * 2) : (i += 1) capture[@intCast(i)] = null;

    var cptr: [*c]const u8 = cbuf + (@as(usize, @intCast(cindex)) << @as(u6, @intCast(cbuf_type)));
    if (0 < cindex and cindex < clen and s.cbuf_type == 2) {
        const p: [*c]const u16 = @ptrCast(@alignCast(cptr));
        if (is_lo_surrogate(p[0]) and is_hi_surrogate((p - 1)[0])) {
            cptr = @ptrCast(p - 1);
        }
    }

    const ret = lre_exec_backtrack(s, capture, bc_buf + RE_HEADER_LEN, cptr);

    if (!ptrEq(s.stack_buf, &s.static_stack_buf))
        _ = lre_realloc(s.opaque_ptr, @ptrCast(s.stack_buf), 0);
    return @intCast(ret);
}

extern const zig_REOP_match: c_int;
extern const zig_REOP_prev: c_int;
const std = @import("std");

// ===========================================================================
// Parser: bytecode emit helpers (operate on REParseState.byte_code).
// ===========================================================================

const DynBufReallocFunc = fn (opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
const DynBuf = extern struct {
    buf: [*c]u8,
    size: usize,
    allocated_size: usize,
    err: c_int,
    realloc_func: ?*const DynBufReallocFunc,
    opaque_ptr: ?*anyopaque,
};

const TMP_BUF_SIZE = 128;
const REParseState = extern struct {
    byte_code: DynBuf,
    buf_ptr: [*c]const u8,
    buf_end: [*c]const u8,
    buf_start: [*c]const u8,
    re_flags: c_int,
    is_unicode: c_int,
    unicode_sets: c_int,
    ignore_case: c_int,
    multi_line: c_int,
    dotall: c_int,
    group_name_scope: u8,
    capture_count: c_int,
    total_capture_count: c_int,
    has_named_captures: c_int,
    opaque_ptr: ?*anyopaque,
    group_names: DynBuf,
    u: extern union {
        error_msg: [TMP_BUF_SIZE]u8,
    },
};

extern fn __dbuf_putc(s: *DynBuf, c: u8) callconv(.c) c_int;
extern fn __dbuf_put_u16(s: *DynBuf, val: u16) callconv(.c) c_int;
extern fn __dbuf_put_u32(s: *DynBuf, val: u32) callconv(.c) c_int;

export fn re_emit_op(s: *REParseState, op: c_int) callconv(.c) void {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
}

// return the offset of the u32 value
export fn re_emit_op_u32(s: *REParseState, op: c_int, val: u32) callconv(.c) c_int {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    const pos: c_int = @intCast(s.byte_code.size);
    _ = __dbuf_put_u32(&s.byte_code, val);
    return pos;
}

export fn re_emit_goto(s: *REParseState, op: c_int, val: u32) callconv(.c) c_int {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    const pos: c_int = @intCast(s.byte_code.size);
    _ = __dbuf_put_u32(&s.byte_code, val -% (@as(u32, @intCast(pos)) + 4));
    return pos;
}

export fn re_emit_goto_u8(s: *REParseState, op: c_int, arg: u32, val: u32) callconv(.c) c_int {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    _ = __dbuf_putc(&s.byte_code, @truncate(arg));
    const pos: c_int = @intCast(s.byte_code.size);
    _ = __dbuf_put_u32(&s.byte_code, val -% (@as(u32, @intCast(pos)) + 4));
    return pos;
}

export fn re_emit_goto_u8_u32(s: *REParseState, op: c_int, arg0: u32, arg1: u32, val: u32) callconv(.c) c_int {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    _ = __dbuf_putc(&s.byte_code, @truncate(arg0));
    _ = __dbuf_put_u32(&s.byte_code, arg1);
    const pos: c_int = @intCast(s.byte_code.size);
    _ = __dbuf_put_u32(&s.byte_code, val -% (@as(u32, @intCast(pos)) + 4));
    return pos;
}

export fn re_emit_op_u8(s: *REParseState, op: c_int, val: u32) callconv(.c) void {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    _ = __dbuf_putc(&s.byte_code, @truncate(val));
}

export fn re_emit_op_u16(s: *REParseState, op: c_int, val: u32) callconv(.c) void {
    _ = __dbuf_putc(&s.byte_code, @intCast(op));
    _ = __dbuf_put_u16(&s.byte_code, @truncate(val));
}

// ===========================================================================
// Parser: small helpers (digits, expect, group-name lookups, modifiers).
// ===========================================================================

extern fn strlen(s: [*c]const u8) usize;
extern fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
// C-variadic; Zig can call (but not define) it.
extern fn re_parse_error(s: *REParseState, fmt: [*c]const u8, ...) callconv(.c) c_int;

const LRE_FLAG_IGNORECASE: c_int = 1 << 1;
const LRE_FLAG_MULTILINE: c_int = 1 << 2;
const LRE_FLAG_DOTALL: c_int = 1 << 3;
const LRE_GROUP_NAME_TRAILER_LEN: usize = 2;
const INT32_MAX_U: u64 = 0x7fffffff;

// If allow_overflow is false, return -1 on overflow; otherwise INT32_MAX.
export fn parse_digits(pp: [*c][*c]const u8, allow_overflow: c_int) callconv(.c) c_int {
    var p = pp[0];
    var v: u64 = 0;
    while (true) {
        const c = p[0];
        if (c < '0' or c > '9') break;
        v = v * 10 + c - '0';
        if (v >= INT32_MAX_U) {
            if (allow_overflow != 0) {
                v = INT32_MAX_U;
            } else {
                return -1;
            }
        }
        p += 1;
    }
    pp[0] = p;
    return @intCast(v);
}

export fn re_parse_expect(s: *REParseState, pp: [*c][*c]const u8, c: c_int) callconv(.c) c_int {
    var p = pp[0];
    if (p[0] != c) return re_parse_error(s, "expecting '%c'", c);
    p += 1;
    pp[0] = p;
    return 0;
}

export fn is_unicode_char(c: c_int) callconv(.c) c_int {
    return @intFromBool((c >= '0' and c <= '9') or
        (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c == '_'));
}

export fn find_group_name(s: *REParseState, name: [*c]const u8, emit_group_index: c_int) callconv(.c) c_int {
    var p: [*c]const u8 = s.group_names.buf;
    if (p == null) return 0;
    const buf_end = s.group_names.buf + s.group_names.size;
    const name_len = strlen(name);
    var capture_index: c_int = 1;
    var n: c_int = 0;
    while (ptrLt(p, buf_end)) {
        const len = strlen(p);
        if (len == name_len and memcmp(@ptrCast(name), @ptrCast(p), name_len) == 0) {
            if (emit_group_index != 0) _ = __dbuf_putc(&s.byte_code, @intCast(capture_index));
            n += 1;
        }
        p += len + LRE_GROUP_NAME_TRAILER_LEN;
        capture_index += 1;
    }
    return n;
}

export fn is_duplicate_group_name(s: *REParseState, name: [*c]const u8, scope: c_int) callconv(.c) c_int {
    var p: [*c]const u8 = s.group_names.buf;
    if (p == null) return 0;
    const buf_end = s.group_names.buf + s.group_names.size;
    const name_len = strlen(name);
    while (ptrLt(p, buf_end)) {
        const len = strlen(p);
        if (len == name_len and memcmp(@ptrCast(name), @ptrCast(p), name_len) == 0) {
            const scope1: c_int = p[len + 1];
            if (scope == scope1) return 1; // TRUE
        }
        p += len + LRE_GROUP_NAME_TRAILER_LEN;
    }
    return 0;
}

export fn re_parse_modifiers(s: *REParseState, pp: [*c][*c]const u8) callconv(.c) c_int {
    var p = pp[0];
    var mask: c_int = 0;
    while (true) {
        var val: c_int = undefined;
        if (p[0] == 'i') {
            val = LRE_FLAG_IGNORECASE;
        } else if (p[0] == 'm') {
            val = LRE_FLAG_MULTILINE;
        } else if (p[0] == 's') {
            val = LRE_FLAG_DOTALL;
        } else {
            break;
        }
        if ((mask & val) != 0) return re_parse_error(s, "duplicate modifier: '%c'", @as(c_int, p[0]));
        mask |= val;
        p += 1;
    }
    pp[0] = p;
    return mask;
}

export fn update_modifier(val: c_int, add_mask: c_int, remove_mask: c_int, mask: c_int) callconv(.c) c_int {
    var v = val;
    if ((add_mask & mask) != 0) v = 1; // TRUE
    if ((remove_mask & mask) != 0) v = 0; // FALSE
    return v;
}

// ===========================================================================
// Parser: named-capture machinery (group name parsing + capture counting).
// ===========================================================================

extern fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
extern fn unicode_to_utf8(buf: [*c]u8, c: c_uint) callconv(.c) c_int;
extern fn unicode_from_utf8(p: [*c]const u8, max_len: c_int, pp: [*c][*c]const u8) callconv(.c) c_int;
extern fn lre_is_id_start(c: u32) callconv(.c) c_int;
extern fn lre_is_id_continue(c: u32) callconv(.c) c_int;

const UNICODE_C_DOLLAR: u8 = 1 << 5;
const UTF8_CHAR_LEN_MAX: usize = 6;
const CAPTURE_COUNT_MAX: c_int = 255;

inline fn lre_is_id_start_byte(ch: u8) bool {
    return (lre_ctype_bits[ch] & (UNICODE_C_UPPER | UNICODE_C_LOWER | UNICODE_C_UNDER | UNICODE_C_DOLLAR)) != 0;
}
inline fn lre_is_id_continue_byte(ch: u8) bool {
    return (lre_ctype_bits[ch] & (UNICODE_C_UPPER | UNICODE_C_LOWER | UNICODE_C_UNDER | UNICODE_C_DOLLAR | UNICODE_C_DIGIT)) != 0;
}
inline fn lre_js_is_ident_first(c: u32) bool {
    if (c < 128) return lre_is_id_start_byte(@intCast(c));
    return lre_is_id_start(c) != 0;
}
inline fn lre_js_is_ident_next(c: u32) bool {
    if (c < 128) return lre_is_id_continue_byte(@intCast(c));
    if (c >= 0x200C and c <= 0x200D) return true; // ZWNJ/ZWJ
    return lre_is_id_continue(c) != 0;
}

// '*pp' is the first char after '<'.
export fn re_parse_group_name(buf: [*c]u8, buf_size: c_int, pp: [*c][*c]const u8) callconv(.c) c_int {
    var p = pp[0];
    var q: usize = 0;
    while (true) {
        var c: u32 = p[0];
        if (c == '\\') {
            p += 1;
            if (p[0] != 'u') return -1;
            c = @bitCast(lre_parse_escape(&p, 2)); // accept surrogate pairs
        } else if (c == '>') {
            break;
        } else if (c >= 128) {
            c = @bitCast(unicode_from_utf8(p, @intCast(UTF8_CHAR_LEN_MAX), &p));
            if (is_hi_surrogate(c)) {
                var p1: [*c]const u8 = undefined;
                const d: u32 = @bitCast(unicode_from_utf8(p, @intCast(UTF8_CHAR_LEN_MAX), &p1));
                if (is_lo_surrogate(d)) {
                    c = from_surrogate(c, d);
                    p = p1;
                }
            }
        } else {
            p += 1;
        }
        if (c > 0x10FFFF) return -1;
        if (q == 0) {
            if (!lre_js_is_ident_first(c)) return -1;
        } else {
            if (!lre_js_is_ident_next(c)) return -1;
        }
        if ((q + UTF8_CHAR_LEN_MAX + 1) > @as(usize, @intCast(buf_size))) return -1;
        if (c < 128) {
            buf[q] = @intCast(c);
            q += 1;
        } else {
            q += @intCast(unicode_to_utf8(buf + q, c));
        }
    }
    if (q == 0) return -1;
    buf[q] = 0;
    p += 1;
    pp[0] = p;
    return 0;
}

// if capture_name == NULL: return number of captures + 1; else number of
// matching capture groups.
export fn re_parse_captures(s: *REParseState, phas_named_captures: [*c]c_int, capture_name: [*c]const u8, emit_group_index: c_int) callconv(.c) c_int {
    var capture_index: c_int = 1;
    var n: c_int = 0;
    phas_named_captures[0] = 0;
    var name: [TMP_BUF_SIZE]u8 = undefined;
    var p = s.buf_start;
    done: {
        while (ptrLt(p, s.buf_end)) : (p += 1) {
            switch (p[0]) {
                '(' => {
                    if (p[1] == '?') {
                        if (p[2] == '<' and p[3] != '=' and p[3] != '!') {
                            phas_named_captures[0] = 1;
                            // potential named capture
                            if (capture_name != null) {
                                p += 3;
                                if (re_parse_group_name(&name, name.len, &p) == 0) {
                                    if (strcmp(@ptrCast(&name), capture_name) == 0) {
                                        if (emit_group_index != 0) _ = __dbuf_putc(&s.byte_code, @intCast(capture_index));
                                        n += 1;
                                    }
                                }
                            }
                            capture_index += 1;
                            if (capture_index >= CAPTURE_COUNT_MAX) break :done;
                        }
                    } else {
                        capture_index += 1;
                        if (capture_index >= CAPTURE_COUNT_MAX) break :done;
                    }
                },
                '\\' => p += 1,
                '[' => {
                    p += 1 + @as(usize, @intFromBool(p[0] == ']'));
                    while (ptrLt(p, s.buf_end) and p[0] != ']') : (p += 1) {
                        if (p[0] == '\\') p += 1;
                    }
                },
                else => {},
            }
        }
    }
    if (capture_name != null) return n;
    return capture_index;
}

export fn re_count_captures(s: *REParseState) callconv(.c) c_int {
    if (s.total_capture_count < 0) {
        s.total_capture_count = re_parse_captures(s, &s.has_named_captures, null, 0);
    }
    return s.total_capture_count;
}

export fn re_has_named_captures(s: *REParseState) callconv(.c) c_int {
    if (s.has_named_captures < 0) _ = re_count_captures(s);
    return s.has_named_captures;
}

// ===========================================================================
// Parser: char-class emit + REStringList utility helpers.
// ===========================================================================

extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern fn dbuf_claim(s: *DynBuf, len: usize) callconv(.c) c_int;

const CharRange = extern struct {
    len: c_int,
    size: c_int,
    points: [*c]u32,
    mem_opaque: ?*anyopaque,
    realloc_func: ?*const DynBufReallocFunc,
};

const REString = extern struct {
    next: [*c]REString,
    hash: u32,
    len: u32,
    // uint32_t buf[] flexible array follows
};

// insert 'len' bytes at position 'pos'. Return < 0 if error.
export fn dbuf_insert(s: *DynBuf, pos: c_int, len: c_int) callconv(.c) c_int {
    if (dbuf_claim(s, @intCast(len)) != 0) return -1;
    const upos: usize = @intCast(pos);
    const ulen: usize = @intCast(len);
    _ = memmove(@ptrCast(s.buf + upos + ulen), @ptrCast(s.buf + upos), s.size - upos);
    s.size += ulen;
    return 0;
}

export fn re_string_hash(len: c_int, buf: [*c]const u32) callconv(.c) u32 {
    var h: u32 = 1;
    var i: c_int = 0;
    while (i < len) : (i += 1) h = h *% 263 +% buf[@intCast(i)];
    return h *% 0x61C88647;
}

export fn re_emit_range(s: *REParseState, cr: *const CharRange) callconv(.c) c_int {
    const len: c_int = @intCast(@as(u32, @intCast(cr.len)) / 2);
    if (len >= 65535) return re_parse_error(s, "too many ranges");
    if (len == 0) {
        _ = re_emit_op_u32(s, @intCast(REOP.char32), 0xFFFFFFFF); // -1
    } else {
        var high = cr.points[@intCast(cr.len - 1)];
        if (high == 0xFFFFFFFF) high = cr.points[@intCast(cr.len - 2)];
        if (high <= 0xffff) {
            // 16-bit ranges with the convention that 0xffff = infinity
            re_emit_op_u16(s, @intCast(if (s.ignore_case != 0) REOP.range_i else REOP.range), @intCast(len));
            var i: c_int = 0;
            while (i < cr.len) : (i += 2) {
                _ = __dbuf_put_u16(&s.byte_code, @truncate(cr.points[@intCast(i)]));
                high = cr.points[@intCast(i + 1)] -% 1;
                if (high == 0xFFFFFFFF - 1) high = 0xffff;
                _ = __dbuf_put_u16(&s.byte_code, @truncate(high));
            }
        } else {
            re_emit_op_u16(s, @intCast(if (s.ignore_case != 0) REOP.range32_i else REOP.range32), @intCast(len));
            var i: c_int = 0;
            while (i < cr.len) : (i += 2) {
                _ = __dbuf_put_u32(&s.byte_code, cr.points[@intCast(i)]);
                _ = __dbuf_put_u32(&s.byte_code, cr.points[@intCast(i + 1)] -% 1);
            }
        }
    }
    return 0;
}

export fn re_string_cmp_len(a: ?*const anyopaque, b: ?*const anyopaque, arg: ?*anyopaque) callconv(.c) c_int {
    _ = arg;
    const p1: *const REString = @as(*const *const REString, @ptrCast(@alignCast(a))).*;
    const p2: *const REString = @as(*const *const REString, @ptrCast(@alignCast(b))).*;
    return @as(c_int, @intFromBool(p1.len < p2.len)) - @as(c_int, @intFromBool(p1.len > p2.len));
}

export fn re_emit_char(s: *REParseState, c: c_int) callconv(.c) void {
    if (c <= 0xffff) {
        re_emit_op_u16(s, @intCast(if (s.ignore_case != 0) REOP.char_i else REOP.char), @intCast(c));
    } else {
        _ = re_emit_op_u32(s, @intCast(if (s.ignore_case != 0) REOP.char32_i else REOP.char32), @intCast(c));
    }
}

// ===========================================================================
// Parser: REStringList hash-table core (string-set membership for v-mode).
// ===========================================================================

extern fn memset(dest: ?*anyopaque, c: c_int, n: usize) ?*anyopaque;
extern fn cr_init(cr: *CharRange, mem_opaque: ?*anyopaque, realloc_func: ?*const DynBufReallocFunc) callconv(.c) void;
extern fn cr_free(cr: *CharRange) callconv(.c) void;
extern fn cr_op1(cr: *CharRange, b_pt: [*c]const u32, b_len: c_int, op: c_int) callconv(.c) c_int;

const CR_OP_UNION: c_int = 0;

const REStringList = extern struct {
    cr: CharRange,
    n_strings: u32,
    hash_size: u32,
    hash_bits: c_int,
    hash_table: [*c][*c]REString,
};

// REString.buf is a uint32_t[] flexible array right after the header.
inline fn reStringBuf(p: [*c]REString) [*]u32 {
    return @ptrFromInt(@intFromPtr(p) + @sizeOf(REString));
}
inline fn max_int(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}
inline fn cr_union_interval(cr: *CharRange, c1: u32, c2: u32) c_int {
    var b_pt = [2]u32{ c1, c2 + 1 };
    return cr_op1(cr, &b_pt, 2, CR_OP_UNION);
}

export fn re_string_list_init(s1: *REParseState, s: *REStringList) callconv(.c) void {
    cr_init(&s.cr, s1.opaque_ptr, &lre_realloc);
    s.n_strings = 0;
    s.hash_size = 0;
    s.hash_bits = 0;
    s.hash_table = null;
}

export fn re_string_list_free(s: *REStringList) callconv(.c) void {
    var i: u32 = 0;
    while (i < s.hash_size) : (i += 1) {
        var p = s.hash_table[i];
        while (p != null) {
            const p_next = p.*.next;
            _ = lre_realloc(s.cr.mem_opaque, @ptrCast(p), 0);
            p = p_next;
        }
    }
    _ = lre_realloc(s.cr.mem_opaque, @ptrCast(s.hash_table), 0);
    cr_free(&s.cr);
}

export fn re_string_find2(s: *REStringList, len: c_int, buf: [*c]const u32, h0: u32, add_flag: c_int) callconv(.c) c_int {
    var h: u32 = 0;
    if (s.n_strings != 0) {
        h = h0 >> @intCast(32 - s.hash_bits);
        var p = s.hash_table[h];
        while (p != null) : (p = p.*.next) {
            if (p.*.hash == h0 and p.*.len == @as(u32, @intCast(len)) and
                memcmp(@ptrCast(reStringBuf(p)), @ptrCast(buf), @as(usize, @intCast(len)) * @sizeOf(u32)) == 0)
            {
                return 1;
            }
        }
    }
    if (add_flag == 0) return 0;
    // grow the hash table if needed
    if ((s.n_strings + 1) > s.hash_size) {
        const new_hash_bits = max_int(s.hash_bits + 1, 4);
        const new_hash_size: u32 = @as(u32, 1) << @intCast(new_hash_bits);
        const raw = lre_realloc(s.cr.mem_opaque, null, @sizeOf(usize) * new_hash_size);
        if (raw == null) return -1;
        const new_hash_table: [*c][*c]REString = @ptrCast(@alignCast(raw));
        _ = memset(raw, 0, @sizeOf(usize) * new_hash_size);
        var i: u32 = 0;
        while (i < s.hash_size) : (i += 1) {
            var p = s.hash_table[i];
            while (p != null) {
                const p_next = p.*.next;
                h = p.*.hash >> @intCast(32 - new_hash_bits);
                p.*.next = new_hash_table[h];
                new_hash_table[h] = p;
                p = p_next;
            }
        }
        _ = lre_realloc(s.cr.mem_opaque, @ptrCast(s.hash_table), 0);
        s.hash_bits = new_hash_bits;
        s.hash_size = new_hash_size;
        s.hash_table = new_hash_table;
        h = h0 >> @intCast(32 - s.hash_bits);
    }
    const raw = lre_realloc(s.cr.mem_opaque, null, @sizeOf(REString) + @as(usize, @intCast(len)) * @sizeOf(u32));
    if (raw == null) return -1;
    const p: [*c]REString = @ptrCast(@alignCast(raw));
    p.*.next = s.hash_table[h];
    s.hash_table[h] = p;
    s.n_strings += 1;
    p.*.hash = h0;
    p.*.len = @intCast(len);
    _ = memcpy(@ptrCast(reStringBuf(p)), @ptrCast(buf), @sizeOf(u32) * @as(usize, @intCast(len)));
    return 1;
}

export fn re_string_find(s: *REStringList, len: c_int, buf: [*c]const u32, add_flag: c_int) callconv(.c) c_int {
    const h0 = re_string_hash(len, buf);
    return re_string_find2(s, len, buf, h0, add_flag);
}

// return -1 if memory error, 0 if OK
export fn re_string_add(s: *REStringList, len: c_int, buf: [*c]const u32) callconv(.c) c_int {
    if (len == 1) return cr_union_interval(&s.cr, buf[0], buf[0]);
    if (re_string_find(s, len, buf, 1) < 0) return -1;
    return 0;
}

// ===========================================================================
// Parser: string-list set ops, canonicalization, emission; cr_init_char_range.
// ===========================================================================

extern fn abort() callconv(.c) noreturn;
const RqsortCmp = *const fn (a: ?*const anyopaque, b: ?*const anyopaque, arg: ?*anyopaque) callconv(.c) c_int;
extern fn rqsort(base: ?*anyopaque, nmemb: usize, size: usize, cmp: RqsortCmp, arg: ?*anyopaque) callconv(.c) void;
extern fn cr_realloc(cr: *CharRange, size: c_int) callconv(.c) c_int;
extern fn cr_invert(cr: *CharRange) callconv(.c) c_int;
extern fn cr_regexp_canonicalize(cr: *CharRange, is_unicode: c_int) callconv(.c) c_int;

const CR_OP_INTER: c_int = 1;
const CR_OP_SUB: c_int = 3;

inline fn put_u32(p: [*c]u8, val: u32) void {
    p[0] = @truncate(val);
    p[1] = @truncate(val >> 8);
    p[2] = @truncate(val >> 16);
    p[3] = @truncate(val >> 24);
}

inline fn cr_add_point(cr: *CharRange, v: u32) c_int {
    if (cr.len >= cr.size) {
        if (cr_realloc(cr, cr.len + 1) != 0) return -1;
    }
    cr.points[@intCast(cr.len)] = v;
    cr.len += 1;
    return 0;
}

const char_range_d = [_]u16{ 1, 0x0030, 0x0039 + 1 };
const char_range_s = [_]u16{
    10,
    0x0009, 0x000D + 1, 0x0020, 0x0020 + 1, 0x00A0, 0x00A0 + 1,
    0x1680, 0x1680 + 1, 0x2000, 0x200A + 1, 0x2028, 0x2029 + 1,
    0x202F, 0x202F + 1, 0x205F, 0x205F + 1, 0x3000, 0x3000 + 1,
    0xFEFF, 0xFEFF + 1,
};
const char_range_w = [_]u16{ 4, 0x0030, 0x0039 + 1, 0x0041, 0x005A + 1, 0x005F, 0x005F + 1, 0x0061, 0x007A + 1 };
const char_range_table = [_][*]const u16{ &char_range_d, &char_range_s, &char_range_w };

// a = a op b
export fn re_string_list_op(a: *REStringList, b: *REStringList, op: c_int) callconv(.c) c_int {
    if (cr_op1(&a.cr, b.cr.points, b.cr.len, op) != 0) return -1;
    if (op == CR_OP_UNION) {
        if (b.n_strings != 0) {
            var i: u32 = 0;
            while (i < b.hash_size) : (i += 1) {
                var p = b.hash_table[i];
                while (p != null) : (p = p.*.next) {
                    if (re_string_find2(a, @intCast(p.*.len), reStringBuf(p), p.*.hash, 1) < 0) return -1;
                }
            }
        }
    } else if (op == CR_OP_INTER or op == CR_OP_SUB) {
        var i: u32 = 0;
        while (i < a.hash_size) : (i += 1) {
            var pp: [*c][*c]REString = &a.hash_table[i];
            while (true) {
                const p = pp.*;
                if (p == null) break;
                var ret = re_string_find2(b, @intCast(p.*.len), reStringBuf(p), p.*.hash, 0);
                if (op == CR_OP_SUB) ret = @intFromBool(ret == 0);
                if (ret == 0) {
                    pp.* = p.*.next;
                    a.n_strings -= 1;
                    _ = lre_realloc(a.cr.mem_opaque, @ptrCast(p), 0);
                } else {
                    pp = &p.*.next;
                }
            }
        }
    } else {
        abort();
    }
    return 0;
}

export fn re_string_list_canonicalize(s1: *REParseState, s: *REStringList, is_unicode: c_int) callconv(.c) c_int {
    if (cr_regexp_canonicalize(&s.cr, is_unicode) != 0) return -1;
    if (s.n_strings != 0) {
        var a_s: REStringList = undefined;
        const a = &a_s;
        // XXX: simplify
        re_string_list_init(s1, a);
        a.n_strings = s.n_strings;
        a.hash_size = s.hash_size;
        a.hash_bits = s.hash_bits;
        a.hash_table = s.hash_table;
        s.n_strings = 0;
        s.hash_size = 0;
        s.hash_bits = 0;
        s.hash_table = null;
        var i: u32 = 0;
        while (i < a.hash_size) : (i += 1) {
            var p = a.hash_table[i];
            while (p != null) : (p = p.*.next) {
                const pbuf = reStringBuf(p);
                var j: u32 = 0;
                while (j < p.*.len) : (j += 1) pbuf[j] = @intCast(lre_canonicalize(pbuf[j], is_unicode));
                if (re_string_add(s, @intCast(p.*.len), pbuf) != 0) {
                    re_string_list_free(a);
                    return -1;
                }
            }
        }
        re_string_list_free(a);
    }
    return 0;
}

export fn cr_init_char_range(s: *REParseState, cr: *REStringList, c: u32) callconv(.c) c_int {
    const invert = c & 1;
    var c_pt = char_range_table[c >> 1];
    const len: c_int = c_pt[0];
    c_pt += 1;
    re_string_list_init(s, cr);
    var i: c_int = 0;
    while (i < len * 2) : (i += 1) {
        if (cr_add_point(&cr.cr, c_pt[@intCast(i)]) != 0) {
            re_string_list_free(cr);
            return -1;
        }
    }
    if (invert != 0) {
        if (cr_invert(&cr.cr) != 0) {
            re_string_list_free(cr);
            return -1;
        }
    }
    return 0;
}

export fn re_emit_string_list(s: *REParseState, sl: *const REStringList) callconv(.c) c_int {
    if (sl.n_strings == 0) {
        // simple case: only characters
        if (re_emit_range(s, &sl.cr) != 0) return -1;
    } else {
        // match the longest strings first
        const raw = lre_realloc(s.opaque_ptr, null, @sizeOf(usize) * sl.n_strings);
        if (raw == null) {
            _ = re_parse_error(s, "out of memory");
            return -1;
        }
        const tab: [*c][*c]REString = @ptrCast(@alignCast(raw));
        var has_empty_string = false;
        var n: c_int = 0;
        var i: u32 = 0;
        while (i < sl.hash_size) : (i += 1) {
            var p = sl.hash_table[i];
            while (p != null) : (p = p.*.next) {
                if (p.*.len == 0) {
                    has_empty_string = true;
                } else {
                    tab[@intCast(n)] = p;
                    n += 1;
                }
            }
        }
        rqsort(@ptrCast(tab), @intCast(n), @sizeOf(usize), &re_string_cmp_len, null);

        var last_match_pos: c_int = -1;
        var ii: c_int = 0;
        while (ii < n) : (ii += 1) {
            const p = tab[@intCast(ii)];
            const is_last = !has_empty_string and sl.cr.len == 0 and ii == (n - 1);
            var split_pos: c_int = 0;
            if (!is_last) split_pos = re_emit_op_u32(s, @intCast(REOP.split_next_first), 0);
            const pbuf = reStringBuf(p);
            var j: u32 = 0;
            while (j < p.*.len) : (j += 1) re_emit_char(s, @intCast(pbuf[j]));
            if (!is_last) {
                last_match_pos = re_emit_op_u32(s, @intCast(REOP.goto_), @bitCast(last_match_pos));
                put_u32(s.byte_code.buf + @as(usize, @intCast(split_pos)), @as(u32, @intCast(s.byte_code.size)) -% (@as(u32, @intCast(split_pos)) + 4));
            }
        }

        if (sl.cr.len != 0) {
            // char range
            const is_last = !has_empty_string;
            var split_pos: c_int = 0;
            if (!is_last) split_pos = re_emit_op_u32(s, @intCast(REOP.split_next_first), 0);
            if (re_emit_range(s, &sl.cr) != 0) {
                _ = lre_realloc(s.opaque_ptr, raw, 0);
                return -1;
            }
            if (!is_last) put_u32(s.byte_code.buf + @as(usize, @intCast(split_pos)), @as(u32, @intCast(s.byte_code.size)) -% (@as(u32, @intCast(split_pos)) + 4));
        }

        // patch the 'goto match' chain
        while (last_match_pos != -1) {
            const next_pos: c_int = @bitCast(get_u32(s.byte_code.buf + @as(usize, @intCast(last_match_pos))));
            put_u32(s.byte_code.buf + @as(usize, @intCast(last_match_pos)), @as(u32, @intCast(s.byte_code.size)) -% (@as(u32, @intCast(last_match_pos)) + 4));
            last_match_pos = next_pos;
        }
        _ = lre_realloc(s.opaque_ptr, raw, 0);
    }
    return 0;
}
