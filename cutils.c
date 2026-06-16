/*
 * C utilities
 *
 * Copyright (c) 2017 Fabrice Bellard
 * Copyright (c) 2018 Charlie Gordon
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

#include "cutils.h"

/*
 * NOTE: pstrcpy, pstrcat, strstart, has_suffix, the DynBuf functions
 * (except dbuf_printf), and the UTF-8 helpers have been ported to Zig
 * (see cutils.zig). dbuf_printf stays here because it is a C-varargs
 * function and Zig 0.16's @cVaStart is disabled. rqsort (below) is also
 * still in C, to be ported in a later increment.
 */

int __attribute__((format(printf, 2, 3))) dbuf_printf(DynBuf *s,
                                                      const char *fmt, ...)
{
    va_list ap;
    char buf[128];
    int len;

    va_start(ap, fmt);
    len = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (len < 0)
        return -1;
    if (len < sizeof(buf)) {
        /* fast case */
        return dbuf_put(s, (uint8_t *)buf, len);
    } else {
        if (dbuf_claim(s, len + 1))
            return -1;
        va_start(ap, fmt);
        vsnprintf((char *)(s->buf + s->size), s->allocated_size - s->size,
                  fmt, ap);
        va_end(ap);
        s->size += len;
    }
    return 0;
}

/* rqsort below is still in C; everything else has moved to cutils.zig. */

#if 0

#if defined(__EMSCRIPTEN__) || defined(__ANDROID__)

static void *rqsort_arg;
static int (*rqsort_cmp)(const void *, const void *, void *);

static int rqsort_cmp2(const void *p1, const void *p2)
{
    return rqsort_cmp(p1, p2, rqsort_arg);
}

/* not reentrant, but not needed with emscripten */
void rqsort(void *base, size_t nmemb, size_t size,
            int (*cmp)(const void *, const void *, void *),
            void *arg)
{
    rqsort_arg = arg;
    rqsort_cmp = cmp;
    qsort(base, nmemb, size, rqsort_cmp2);
}

#endif

#else

typedef void (*exchange_f)(void *a, void *b, size_t size);
typedef int (*cmp_f)(const void *, const void *, void *opaque);

static void exchange_bytes(void *a, void *b, size_t size) {
    uint8_t *ap = (uint8_t *)a;
    uint8_t *bp = (uint8_t *)b;

    while (size-- != 0) {
        uint8_t t = *ap;
        *ap++ = *bp;
        *bp++ = t;
    }
}

static void exchange_one_byte(void *a, void *b, size_t size) {
    uint8_t *ap = (uint8_t *)a;
    uint8_t *bp = (uint8_t *)b;
    uint8_t t = *ap;
    *ap = *bp;
    *bp = t;
}

static void exchange_int16s(void *a, void *b, size_t size) {
    uint16_t *ap = (uint16_t *)a;
    uint16_t *bp = (uint16_t *)b;

    for (size /= sizeof(uint16_t); size-- != 0;) {
        uint16_t t = *ap;
        *ap++ = *bp;
        *bp++ = t;
    }
}

static void exchange_one_int16(void *a, void *b, size_t size) {
    uint16_t *ap = (uint16_t *)a;
    uint16_t *bp = (uint16_t *)b;
    uint16_t t = *ap;
    *ap = *bp;
    *bp = t;
}

static void exchange_int32s(void *a, void *b, size_t size) {
    uint32_t *ap = (uint32_t *)a;
    uint32_t *bp = (uint32_t *)b;

    for (size /= sizeof(uint32_t); size-- != 0;) {
        uint32_t t = *ap;
        *ap++ = *bp;
        *bp++ = t;
    }
}

static void exchange_one_int32(void *a, void *b, size_t size) {
    uint32_t *ap = (uint32_t *)a;
    uint32_t *bp = (uint32_t *)b;
    uint32_t t = *ap;
    *ap = *bp;
    *bp = t;
}

static void exchange_int64s(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a;
    uint64_t *bp = (uint64_t *)b;

    for (size /= sizeof(uint64_t); size-- != 0;) {
        uint64_t t = *ap;
        *ap++ = *bp;
        *bp++ = t;
    }
}

static void exchange_one_int64(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a;
    uint64_t *bp = (uint64_t *)b;
    uint64_t t = *ap;
    *ap = *bp;
    *bp = t;
}

static void exchange_int128s(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a;
    uint64_t *bp = (uint64_t *)b;

    for (size /= sizeof(uint64_t) * 2; size-- != 0; ap += 2, bp += 2) {
        uint64_t t = ap[0];
        uint64_t u = ap[1];
        ap[0] = bp[0];
        ap[1] = bp[1];
        bp[0] = t;
        bp[1] = u;
    }
}

static void exchange_one_int128(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a;
    uint64_t *bp = (uint64_t *)b;
    uint64_t t = ap[0];
    uint64_t u = ap[1];
    ap[0] = bp[0];
    ap[1] = bp[1];
    bp[0] = t;
    bp[1] = u;
}

static inline exchange_f exchange_func(const void *base, size_t size) {
    switch (((uintptr_t)base | (uintptr_t)size) & 15) {
    case 0:
        if (size == sizeof(uint64_t) * 2)
            return exchange_one_int128;
        else
            return exchange_int128s;
    case 8:
        if (size == sizeof(uint64_t))
            return exchange_one_int64;
        else
            return exchange_int64s;
    case 4:
    case 12:
        if (size == sizeof(uint32_t))
            return exchange_one_int32;
        else
            return exchange_int32s;
    case 2:
    case 6:
    case 10:
    case 14:
        if (size == sizeof(uint16_t))
            return exchange_one_int16;
        else
            return exchange_int16s;
    default:
        if (size == 1)
            return exchange_one_byte;
        else
            return exchange_bytes;
    }
}

static void heapsortx(void *base, size_t nmemb, size_t size, cmp_f cmp, void *opaque)
{
    uint8_t *basep = (uint8_t *)base;
    size_t i, n, c, r;
    exchange_f swap = exchange_func(base, size);

    if (nmemb > 1) {
        i = (nmemb / 2) * size;
        n = nmemb * size;

        while (i > 0) {
            i -= size;
            for (r = i; (c = r * 2 + size) < n; r = c) {
                if (c < n - size && cmp(basep + c, basep + c + size, opaque) <= 0)
                    c += size;
                if (cmp(basep + r, basep + c, opaque) > 0)
                    break;
                swap(basep + r, basep + c, size);
            }
        }
        for (i = n - size; i > 0; i -= size) {
            swap(basep, basep + i, size);

            for (r = 0; (c = r * 2 + size) < i; r = c) {
                if (c < i - size && cmp(basep + c, basep + c + size, opaque) <= 0)
                    c += size;
                if (cmp(basep + r, basep + c, opaque) > 0)
                    break;
                swap(basep + r, basep + c, size);
            }
        }
    }
}

static inline void *med3(void *a, void *b, void *c, cmp_f cmp, void *opaque)
{
    return cmp(a, b, opaque) < 0 ?
        (cmp(b, c, opaque) < 0 ? b : (cmp(a, c, opaque) < 0 ? c : a )) :
        (cmp(b, c, opaque) > 0 ? b : (cmp(a, c, opaque) < 0 ? a : c ));
}

/* pointer based version with local stack and insertion sort threshhold */
void rqsort(void *base, size_t nmemb, size_t size, cmp_f cmp, void *opaque)
{
    struct { uint8_t *base; size_t count; int depth; } stack[50], *sp = stack;
    uint8_t *ptr, *pi, *pj, *plt, *pgt, *top, *m;
    size_t m4, i, lt, gt, span, span2;
    int c, depth;
    exchange_f swap = exchange_func(base, size);
    exchange_f swap_block = exchange_func(base, size | 128);

    if (nmemb < 2 || size <= 0)
        return;

    sp->base = (uint8_t *)base;
    sp->count = nmemb;
    sp->depth = 0;
    sp++;

    while (sp > stack) {
        sp--;
        ptr = sp->base;
        nmemb = sp->count;
        depth = sp->depth;

        while (nmemb > 6) {
            if (++depth > 50) {
                /* depth check to ensure worst case logarithmic time */
                heapsortx(ptr, nmemb, size, cmp, opaque);
                nmemb = 0;
                break;
            }
            /* select median of 3 from 1/4, 1/2, 3/4 positions */
            /* should use median of 5 or 9? */
            m4 = (nmemb >> 2) * size;
            m = med3(ptr + m4, ptr + 2 * m4, ptr + 3 * m4, cmp, opaque);
            swap(ptr, m, size);  /* move the pivot to the start or the array */
            i = lt = 1;
            pi = plt = ptr + size;
            gt = nmemb;
            pj = pgt = top = ptr + nmemb * size;
            for (;;) {
                while (pi < pj && (c = cmp(ptr, pi, opaque)) >= 0) {
                    if (c == 0) {
                        swap(plt, pi, size);
                        lt++;
                        plt += size;
                    }
                    i++;
                    pi += size;
                }
                while (pi < (pj -= size) && (c = cmp(ptr, pj, opaque)) <= 0) {
                    if (c == 0) {
                        gt--;
                        pgt -= size;
                        swap(pgt, pj, size);
                    }
                }
                if (pi >= pj)
                    break;
                swap(pi, pj, size);
                i++;
                pi += size;
            }
            /* array has 4 parts:
             * from 0 to lt excluded: elements identical to pivot
             * from lt to pi excluded: elements smaller than pivot
             * from pi to gt excluded: elements greater than pivot
             * from gt to n excluded: elements identical to pivot
             */
            /* move elements identical to pivot in the middle of the array: */
            /* swap values in ranges [0..lt[ and [i-lt..i[
               swapping the smallest span between lt and i-lt is sufficient
             */
            span = plt - ptr;
            span2 = pi - plt;
            lt = i - lt;
            if (span > span2)
                span = span2;
            swap_block(ptr, pi - span, span);
            /* swap values in ranges [gt..top[ and [i..top-(top-gt)[
               swapping the smallest span between top-gt and gt-i is sufficient
             */
            span = top - pgt;
            span2 = pgt - pi;
            pgt = top - span2;
            gt = nmemb - (gt - i);
            if (span > span2)
                span = span2;
            swap_block(pi, top - span, span);

            /* now array has 3 parts:
             * from 0 to lt excluded: elements smaller than pivot
             * from lt to gt excluded: elements identical to pivot
             * from gt to n excluded: elements greater than pivot
             */
            /* stack the larger segment and keep processing the smaller one
               to minimize stack use for pathological distributions */
            if (lt > nmemb - gt) {
                sp->base = ptr;
                sp->count = lt;
                sp->depth = depth;
                sp++;
                ptr = pgt;
                nmemb -= gt;
            } else {
                sp->base = pgt;
                sp->count = nmemb - gt;
                sp->depth = depth;
                sp++;
                nmemb = lt;
            }
        }
        /* Use insertion sort for small fragments */
        for (pi = ptr + size, top = ptr + nmemb * size; pi < top; pi += size) {
            for (pj = pi; pj > ptr && cmp(pj - size, pj, opaque) > 0; pj -= size)
                swap(pj, pj - size, size);
        }
    }
}

#endif
