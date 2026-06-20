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
