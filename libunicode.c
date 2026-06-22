/*
 * Unicode utilities
 *
 * Copyright (c) 2017-2018 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <assert.h>

#include "cutils.h"
#include "libunicode.h"
#include "libunicode-table.h"

enum {
    RUN_TYPE_U,
    RUN_TYPE_L,
    RUN_TYPE_UF,
    RUN_TYPE_LF,
    RUN_TYPE_UL,
    RUN_TYPE_LSU,
    RUN_TYPE_U2L_399_EXT2,
    RUN_TYPE_UF_D20,
    RUN_TYPE_UF_D1_EXT,
    RUN_TYPE_U_EXT,
    RUN_TYPE_LF_EXT,
    RUN_TYPE_UF_EXT2,
    RUN_TYPE_LF_EXT2,
    RUN_TYPE_UF_EXT3,
};

/* lre_canonicalize is ported to Zig (libunicode.zig). */


/*
 * NOTE: many libunicode functions have been ported to Zig (see libunicode.zig),
 * including the property booleans, case conversion, normalization and their
 * table helpers (get_le24, get_index_pos, lre_is_in_table, unicode_get_cc,
 * unicode_decomp_*, etc.). Those helpers now live only in Zig. The functions
 * remaining below (scripts, general category, properties, regexp
 * canonicalization) are not yet ported.
 */

/* character range */

static __maybe_unused void cr_dump(CharRange *cr)
{
    int i;
    for(i = 0; i < cr->len; i++)
        printf("%d: 0x%04x\n", i, cr->points[i]);
}

/*
 * NOTE: the CharRange set-algebra functions (cr_init, cr_free, cr_realloc,
 * cr_copy, cr_compress, cr_op, cr_op1, cr_invert) have been ported to Zig
 * (see libunicode.zig). The table-driven Unicode functions remain here.
 */

#define CASE_U (1 << 0)
#define CASE_L (1 << 1)
#define CASE_F (1 << 2)

/* use the case conversion table to generate range of characters.
   CASE_U: set char if modified by uppercasing,
   CASE_L: set char if modified by lowercasing,
   CASE_F: set char if modified by case folding,
 */
/* unicode_case1 and cr_regexp_canonicalize are ported to Zig (libunicode.zig);
   unicode_case1 is still called by the unicode_general_category/prop code below. */
int unicode_case1(CharRange *cr, int case_mask);

#ifdef CONFIG_ALL_UNICODE

/* lre_is_id_start and lre_is_id_continue are ported to Zig (libunicode.zig). */

#define UNICODE_DECOMP_LEN_MAX 18

typedef enum {
    DECOMP_TYPE_C1, /* 16 bit char */
    DECOMP_TYPE_L1, /* 16 bit char table */
    DECOMP_TYPE_L2,
    DECOMP_TYPE_L3,
    DECOMP_TYPE_L4,
    DECOMP_TYPE_L5, /* XXX: not used */
    DECOMP_TYPE_L6, /* XXX: could remove */
    DECOMP_TYPE_L7, /* XXX: could remove */
    DECOMP_TYPE_LL1, /* 18 bit char table */
    DECOMP_TYPE_LL2,
    DECOMP_TYPE_S1, /* 8 bit char table */
    DECOMP_TYPE_S2,
    DECOMP_TYPE_S3,
    DECOMP_TYPE_S4,
    DECOMP_TYPE_S5,
    DECOMP_TYPE_I1, /* increment 16 bit char value */
    DECOMP_TYPE_I2_0,
    DECOMP_TYPE_I2_1,
    DECOMP_TYPE_I3_1,
    DECOMP_TYPE_I3_2,
    DECOMP_TYPE_I4_1,
    DECOMP_TYPE_I4_2,
    DECOMP_TYPE_B1, /* 16 bit base + 8 bit offset */
    DECOMP_TYPE_B2,
    DECOMP_TYPE_B3,
    DECOMP_TYPE_B4,
    DECOMP_TYPE_B5,
    DECOMP_TYPE_B6,
    DECOMP_TYPE_B7,
    DECOMP_TYPE_B8,
    DECOMP_TYPE_B18,
    DECOMP_TYPE_LS2,
    DECOMP_TYPE_PAT3,
    DECOMP_TYPE_S2_UL,
    DECOMP_TYPE_LS2_UL,
} DecompTypeEnum;

/* char ranges for various unicode properties */

/* These table-walking workers are ported to Zig (libunicode.zig). */
int unicode_find_name(const char *name_table, const char *name);
int unicode_general_category1(CharRange *cr, uint32_t gc_mask);
int unicode_prop1(CharRange *cr, int prop_idx);

#define M(id) (1U << UNICODE_GC_ ## id)



typedef enum {
    POP_GC,
    POP_PROP,
    POP_CASE,
    POP_UNION,
    POP_INTER,
    POP_XOR,
    POP_INVERT,
    POP_END,
} PropOPEnum;

#define POP_STACK_LEN_MAX 4

static int unicode_prop_ops(CharRange *cr, ...)
{
    va_list ap;
    CharRange stack[POP_STACK_LEN_MAX];
    int stack_len, op, ret, i;
    uint32_t a;

    va_start(ap, cr);
    stack_len = 0;
    for(;;) {
        op = va_arg(ap, int);
        switch(op) {
        case POP_GC:
            assert(stack_len < POP_STACK_LEN_MAX);
            a = va_arg(ap, int);
            cr_init(&stack[stack_len++], cr->mem_opaque, cr->realloc_func);
            if (unicode_general_category1(&stack[stack_len - 1], a))
                goto fail;
            break;
        case POP_PROP:
            assert(stack_len < POP_STACK_LEN_MAX);
            a = va_arg(ap, int);
            cr_init(&stack[stack_len++], cr->mem_opaque, cr->realloc_func);
            if (unicode_prop1(&stack[stack_len - 1], a))
                goto fail;
            break;
        case POP_CASE:
            assert(stack_len < POP_STACK_LEN_MAX);
            a = va_arg(ap, int);
            cr_init(&stack[stack_len++], cr->mem_opaque, cr->realloc_func);
            if (unicode_case1(&stack[stack_len - 1], a))
                goto fail;
            break;
        case POP_UNION:
        case POP_INTER:
        case POP_XOR:
            {
                CharRange *cr1, *cr2, *cr3;
                assert(stack_len >= 2);
                assert(stack_len < POP_STACK_LEN_MAX);
                cr1 = &stack[stack_len - 2];
                cr2 = &stack[stack_len - 1];
                cr3 = &stack[stack_len++];
                cr_init(cr3, cr->mem_opaque, cr->realloc_func);
                /* CR_OP_XOR may be used here */
                if (cr_op(cr3, cr1->points, cr1->len,
                          cr2->points, cr2->len, op - POP_UNION + CR_OP_UNION))
                    goto fail;
                cr_free(cr1);
                cr_free(cr2);
                *cr1 = *cr3;
                stack_len -= 2;
            }
            break;
        case POP_INVERT:
            assert(stack_len >= 1);
            if (cr_invert(&stack[stack_len - 1]))
                goto fail;
            break;
        case POP_END:
            goto done;
        default:
            abort();
        }
    }
 done:
    assert(stack_len == 1);
    ret = cr_copy(cr, &stack[0]);
    cr_free(&stack[0]);
    return ret;
 fail:
    for(i = 0; i < stack_len; i++)
        cr_free(&stack[i]);
    return -1;
}

static const uint32_t unicode_gc_mask_table[] = {
    M(Lu) | M(Ll) | M(Lt), /* LC */
    M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo), /* L */
    M(Mn) | M(Mc) | M(Me), /* M */
    M(Nd) | M(Nl) | M(No), /* N */
    M(Sm) | M(Sc) | M(Sk) | M(So), /* S */
    M(Pc) | M(Pd) | M(Ps) | M(Pe) | M(Pi) | M(Pf) | M(Po), /* P */
    M(Zs) | M(Zl) | M(Zp), /* Z */
    M(Cc) | M(Cf) | M(Cs) | M(Co) | M(Cn), /* C */
};

/* 'cr' must be initialized and empty. Return 0 if OK, -1 if error, -2
   if not found */
int unicode_general_category(CharRange *cr, const char *gc_name)
{
    int gc_idx;
    uint32_t gc_mask;

    gc_idx = unicode_find_name(unicode_gc_name_table, gc_name);
    if (gc_idx < 0)
        return -2;
    if (gc_idx <= UNICODE_GC_Co) {
        gc_mask = (uint64_t)1 << gc_idx;
    } else {
        gc_mask = unicode_gc_mask_table[gc_idx - UNICODE_GC_LC];
    }
    return unicode_general_category1(cr, gc_mask);
}


/* 'cr' must be initialized and empty. Return 0 if OK, -1 if error, -2
   if not found */
int unicode_prop(CharRange *cr, const char *prop_name)
{
    int prop_idx, ret;

    prop_idx = unicode_find_name(unicode_prop_name_table, prop_name);
    if (prop_idx < 0)
        return -2;
    prop_idx += UNICODE_PROP_ASCII_Hex_Digit;

    ret = 0;
    switch(prop_idx) {
    case UNICODE_PROP_ASCII:
        if (cr_add_interval(cr, 0x00, 0x7f + 1))
            return -1;
        break;
    case UNICODE_PROP_Any:
        if (cr_add_interval(cr, 0x00000, 0x10ffff + 1))
            return -1;
        break;
    case UNICODE_PROP_Assigned:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Cn),
                               POP_INVERT,
                               POP_END);
        break;
    case UNICODE_PROP_Math:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Sm),
                               POP_PROP, UNICODE_PROP_Other_Math,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_Lowercase:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Ll),
                               POP_PROP, UNICODE_PROP_Other_Lowercase,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_Uppercase:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu),
                               POP_PROP, UNICODE_PROP_Other_Uppercase,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_Cased:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt),
                               POP_PROP, UNICODE_PROP_Other_Uppercase,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Other_Lowercase,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_Alphabetic:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo) | M(Nl),
                               POP_PROP, UNICODE_PROP_Other_Uppercase,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Other_Lowercase,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Other_Alphabetic,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_Grapheme_Base:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Cc) | M(Cf) | M(Cs) | M(Co) | M(Cn) | M(Zl) | M(Zp) | M(Me) | M(Mn),
                               POP_PROP, UNICODE_PROP_Other_Grapheme_Extend,
                               POP_UNION,
                               POP_INVERT,
                               POP_END);
        break;
    case UNICODE_PROP_Grapheme_Extend:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Me) | M(Mn),
                               POP_PROP, UNICODE_PROP_Other_Grapheme_Extend,
                               POP_UNION,
                               POP_END);
        break;
    case UNICODE_PROP_XID_Start:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo) | M(Nl),
                               POP_PROP, UNICODE_PROP_Other_ID_Start,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Pattern_Syntax,
                               POP_PROP, UNICODE_PROP_Pattern_White_Space,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_XID_Start1,
                               POP_UNION,
                               POP_INVERT,
                               POP_INTER,
                               POP_END);
        break;
    case UNICODE_PROP_XID_Continue:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo) | M(Nl) |
                               M(Mn) | M(Mc) | M(Nd) | M(Pc),
                               POP_PROP, UNICODE_PROP_Other_ID_Start,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Other_ID_Continue,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Pattern_Syntax,
                               POP_PROP, UNICODE_PROP_Pattern_White_Space,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_XID_Continue1,
                               POP_UNION,
                               POP_INVERT,
                               POP_INTER,
                               POP_END);
        break;
    case UNICODE_PROP_Changes_When_Uppercased:
        ret = unicode_case1(cr, CASE_U);
        break;
    case UNICODE_PROP_Changes_When_Lowercased:
        ret = unicode_case1(cr, CASE_L);
        break;
    case UNICODE_PROP_Changes_When_Casemapped:
        ret = unicode_case1(cr, CASE_U | CASE_L | CASE_F);
        break;
    case UNICODE_PROP_Changes_When_Titlecased:
        ret = unicode_prop_ops(cr,
                               POP_CASE, CASE_U,
                               POP_PROP, UNICODE_PROP_Changes_When_Titlecased1,
                               POP_XOR,
                               POP_END);
        break;
    case UNICODE_PROP_Changes_When_Casefolded:
        ret = unicode_prop_ops(cr,
                               POP_CASE, CASE_F,
                               POP_PROP, UNICODE_PROP_Changes_When_Casefolded1,
                               POP_XOR,
                               POP_END);
        break;
    case UNICODE_PROP_Changes_When_NFKC_Casefolded:
        ret = unicode_prop_ops(cr,
                               POP_CASE, CASE_F,
                               POP_PROP, UNICODE_PROP_Changes_When_NFKC_Casefolded1,
                               POP_XOR,
                               POP_END);
        break;
#if 0
    case UNICODE_PROP_ID_Start:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo) | M(Nl),
                               POP_PROP, UNICODE_PROP_Other_ID_Start,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Pattern_Syntax,
                               POP_PROP, UNICODE_PROP_Pattern_White_Space,
                               POP_UNION,
                               POP_INVERT,
                               POP_INTER,
                               POP_END);
        break;
    case UNICODE_PROP_ID_Continue:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Lu) | M(Ll) | M(Lt) | M(Lm) | M(Lo) | M(Nl) |
                               M(Mn) | M(Mc) | M(Nd) | M(Pc),
                               POP_PROP, UNICODE_PROP_Other_ID_Start,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Other_ID_Continue,
                               POP_UNION,
                               POP_PROP, UNICODE_PROP_Pattern_Syntax,
                               POP_PROP, UNICODE_PROP_Pattern_White_Space,
                               POP_UNION,
                               POP_INVERT,
                               POP_INTER,
                               POP_END);
        break;
    case UNICODE_PROP_Case_Ignorable:
        ret = unicode_prop_ops(cr,
                               POP_GC, M(Mn) | M(Cf) | M(Lm) | M(Sk),
                               POP_PROP, UNICODE_PROP_Case_Ignorable1,
                               POP_XOR,
                               POP_END);
        break;
#else
        /* we use the existing tables */
    case UNICODE_PROP_ID_Continue:
        ret = unicode_prop_ops(cr,
                               POP_PROP, UNICODE_PROP_ID_Start,
                               POP_PROP, UNICODE_PROP_ID_Continue1,
                               POP_XOR,
                               POP_END);
        break;
#endif
    default:
        if (prop_idx >= countof(unicode_prop_table))
            return -2;
        ret = unicode_prop1(cr, prop_idx);
        break;
    }
    return ret;
}

#endif /* CONFIG_ALL_UNICODE */

/*---- lre codepoint categorizing functions ----*/

#define S  UNICODE_C_SPACE
#define D  UNICODE_C_DIGIT
#define X  UNICODE_C_XDIGIT
#define U  UNICODE_C_UPPER
#define L  UNICODE_C_LOWER
#define _  UNICODE_C_UNDER
#define d  UNICODE_C_DOLLAR

uint8_t const lre_ctype_bits[256] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    0, S, S, S, S, S, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,

    S, 0, 0, 0, d, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    X|D, X|D, X|D, X|D, X|D, X|D, X|D, X|D,
    X|D, X|D, 0, 0, 0, 0, 0, 0,

    0, X|U, X|U, X|U, X|U, X|U, X|U, U,
    U, U, U, U, U, U, U, U,
    U, U, U, U, U, U, U, U,
    U, U, U, 0, 0, 0, 0, _,

    0, X|L, X|L, X|L, X|L, X|L, X|L, L,
    L, L, L, L, L, L, L, L,
    L, L, L, L, L, L, L, L,
    L, L, L, 0, 0, 0, 0, 0,

    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,

    S, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,

    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,

    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};

#undef S
#undef D
#undef X
#undef U
#undef L
#undef _
#undef d

/* lre_is_space_non_ascii (and its char_range_s table) are ported to Zig
   (libunicode.zig). */

/* unicode_sequence_prop and unicode_sequence_prop1 are ported to Zig
   (libunicode.zig). */

/*
 * Table pointers exported for the Zig port (libunicode.zig). Zig 0.16's
 * translate-c stops emitting declarations partway through libunicode-table.h
 * (at unicode_cc_table), so the ported normalization code cannot reach the
 * larger tables via @cImport. It accesses them through these external symbols
 * instead. No data is duplicated: the arrays live in this translation unit.
 */
const uint8_t  *const zig_unicode_cc_table          = unicode_cc_table;
const uint8_t  *const zig_unicode_cc_index          = unicode_cc_index;
const int             zig_unicode_cc_index_len       = (int)sizeof(unicode_cc_index);
const uint32_t *const zig_unicode_decomp_table1      = unicode_decomp_table1;
const int             zig_unicode_decomp_table1_len  = (int)(sizeof(unicode_decomp_table1) / sizeof(uint32_t));
const uint16_t *const zig_unicode_decomp_table2      = unicode_decomp_table2;
const uint8_t  *const zig_unicode_decomp_data        = unicode_decomp_data;
const uint16_t *const zig_unicode_comp_table         = unicode_comp_table;
const int             zig_unicode_comp_table_len     = (int)(sizeof(unicode_comp_table) / sizeof(uint16_t));

/* Additional table pointers for the Zig port (Zig 0.17 removed @cImport). */
const uint32_t *const zig_case_conv_table1      = case_conv_table1;
const int             zig_case_conv_table1_len  = (int)countof(case_conv_table1);
const uint8_t  *const zig_case_conv_table2      = case_conv_table2;
const uint16_t *const zig_case_conv_ext         = case_conv_ext;

const uint8_t  *const zig_prop_Cased1_table          = unicode_prop_Cased1_table;
const uint8_t  *const zig_prop_Cased1_index          = unicode_prop_Cased1_index;
const int             zig_prop_Cased1_index_len      = (int)sizeof(unicode_prop_Cased1_index);
const uint8_t  *const zig_prop_Case_Ignorable_table  = unicode_prop_Case_Ignorable_table;
const uint8_t  *const zig_prop_Case_Ignorable_index  = unicode_prop_Case_Ignorable_index;
const int             zig_prop_Case_Ignorable_index_len = (int)sizeof(unicode_prop_Case_Ignorable_index);
const uint8_t  *const zig_prop_ID_Start_table        = unicode_prop_ID_Start_table;
const uint8_t  *const zig_prop_ID_Start_index        = unicode_prop_ID_Start_index;
const int             zig_prop_ID_Start_index_len    = (int)sizeof(unicode_prop_ID_Start_index);
const uint8_t  *const zig_prop_ID_Continue1_table    = unicode_prop_ID_Continue1_table;
const uint8_t  *const zig_prop_ID_Continue1_index    = unicode_prop_ID_Continue1_index;
const int             zig_prop_ID_Continue1_index_len = (int)sizeof(unicode_prop_ID_Continue1_index);

/* Table/constant exports + worker prototypes for the Zig port. The
   table-walking workers (unicode_find_name, unicode_general_category1,
   unicode_prop1, unicode_script) are ported to libunicode.zig; the C
   dispatchers (unicode_general_category, unicode_prop) and the variadic
   unicode_prop_ops still call them. */
const uint8_t  *const zig_unicode_gc_table          = unicode_gc_table;
const int             zig_unicode_gc_table_len      = (int)countof(unicode_gc_table);
const uint8_t  *const *const zig_unicode_prop_table = unicode_prop_table;
const int             zig_unicode_prop_table_len    = (int)countof(unicode_prop_table);
const uint16_t *const zig_unicode_prop_len_table    = unicode_prop_len_table;
const uint8_t  *const zig_unicode_script_table      = unicode_script_table;
const int             zig_unicode_script_table_len  = (int)countof(unicode_script_table);
const uint8_t  *const zig_unicode_script_ext_table     = unicode_script_ext_table;
const int             zig_unicode_script_ext_table_len = (int)countof(unicode_script_ext_table);

const int zig_UNICODE_GC_Lu          = UNICODE_GC_Lu;
const int zig_UNICODE_GC_Ll          = UNICODE_GC_Ll;
const int zig_UNICODE_SCRIPT_Common   = UNICODE_SCRIPT_Common;
const int zig_UNICODE_SCRIPT_Inherited = UNICODE_SCRIPT_Inherited;
const int zig_UNICODE_SCRIPT_Unknown  = UNICODE_SCRIPT_Unknown;
const char  *const zig_unicode_script_name_table = unicode_script_name_table;

/* Exports for the ported unicode_sequence_prop (libunicode.zig). */
const uint8_t *const zig_unicode_rgi_emoji_zwj_sequence     = unicode_rgi_emoji_zwj_sequence;
const int            zig_unicode_rgi_emoji_zwj_sequence_len = (int)countof(unicode_rgi_emoji_zwj_sequence);
const uint8_t *const zig_unicode_rgi_emoji_tag_sequence     = unicode_rgi_emoji_tag_sequence;
const int            zig_unicode_rgi_emoji_tag_sequence_len = (int)countof(unicode_rgi_emoji_tag_sequence);
const char    *const zig_unicode_sequence_prop_name_table   = unicode_sequence_prop_name_table;

const int zig_SEQ_PROP_Basic_Emoji                 = UNICODE_SEQUENCE_PROP_Basic_Emoji;
const int zig_SEQ_PROP_RGI_Emoji_Modifier_Sequence = UNICODE_SEQUENCE_PROP_RGI_Emoji_Modifier_Sequence;
const int zig_SEQ_PROP_RGI_Emoji_Flag_Sequence     = UNICODE_SEQUENCE_PROP_RGI_Emoji_Flag_Sequence;
const int zig_SEQ_PROP_RGI_Emoji_ZWJ_Sequence      = UNICODE_SEQUENCE_PROP_RGI_Emoji_ZWJ_Sequence;
const int zig_SEQ_PROP_RGI_Emoji_Tag_Sequence      = UNICODE_SEQUENCE_PROP_RGI_Emoji_Tag_Sequence;
const int zig_SEQ_PROP_Emoji_Keycap_Sequence       = UNICODE_SEQUENCE_PROP_Emoji_Keycap_Sequence;
const int zig_SEQ_PROP_RGI_Emoji                    = UNICODE_SEQUENCE_PROP_RGI_Emoji;

const int zig_PROP_Basic_Emoji1        = UNICODE_PROP_Basic_Emoji1;
const int zig_PROP_Basic_Emoji2        = UNICODE_PROP_Basic_Emoji2;
const int zig_PROP_Emoji_Modifier_Base = UNICODE_PROP_Emoji_Modifier_Base;
const int zig_PROP_RGI_Emoji_Flag_Sequence = UNICODE_PROP_RGI_Emoji_Flag_Sequence;
const int zig_PROP_Emoji_Keycap_Sequence   = UNICODE_PROP_Emoji_Keycap_Sequence;
