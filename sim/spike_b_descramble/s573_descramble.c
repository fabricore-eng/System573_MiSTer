/* -----------------------------------------------------------------------------
 * s573_descramble.c - Konami System 573 Digital I/O MP3 stream descrambler
 *                     (HPS-side C reference; see s573_descramble.h)
 *
 * Mirrors rtl/k573_mp3dec.v (the per-word transform + key schedule) and
 * rtl/k573_mp3stream.v (fetch order, byte order, the 2N-1 last-word rule), which
 * mirror MAME src/mame/konami/k573fpga.cpp.
 *
 * NEGATIVE-CONTROL HOOKS. Three deliberate mutations live behind -D defines, all
 * OFF in every normal build (same red/green discipline the RTL suite uses for
 * MP3_UNPACED / DIO_RAM_STUB / ...). They exist so the differential harness can be
 * PROVEN able to fail:
 *
 *   -DS573_MUT_NO_KEY3_INC   drop the key3 increment in decrypt_default
 *   -DS573_MUT_LOW_FIRST     emit the low byte before the high byte
 *   -DS573_MUT_NO_2N1        emit the final word's low byte too (2N, not 2N-1)
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include "s573_descramble.h"

/* ---- k573_mp3dec.v: the per-word primitives -------------------------------- */

/* dec_common: within each adjacent bit pair (2i, 2i+1), swap the two bits iff key
 * bit (2i+1) is set; then XOR the even bits with the key. Branchless equivalent of
 * the RTL's 8-iteration loop:
 *   swapped = the whole word with every pair exchanged
 *   pair    = both bits of a pair set wherever the odd key bit selects a swap    */
static inline uint16_t s573_dec_common(uint16_t data, uint16_t key)
{
    const uint16_t swapped = (uint16_t)(((data & 0x5555u) << 1) | ((data >> 1) & 0x5555u));
    const uint16_t odd     = (uint16_t)(key & 0xAAAAu);
    const uint16_t pair    = (uint16_t)(odd | (odd >> 1));
    return (uint16_t)((((swapped & pair) | (data & (uint16_t)~pair)) ^ (key & 0x5555u)));
}

/* derive_key: bitswap of (key1 ^ key2) -- exchange pairs (13,14), (7,8), (1,2). */
static inline uint16_t s573_derive_key(uint16_t s)
{
    uint16_t r = (uint16_t)(s & 0x9E79u);          /* everything but 14,13,8,7,2,1 */
    r |= (uint16_t)((s & 0x2000u) << 1);           /* 13 -> 14 */
    r |= (uint16_t)((s & 0x4000u) >> 1);           /* 14 -> 13 */
    r |= (uint16_t)((s & 0x0080u) << 1);           /*  7 ->  8 */
    r |= (uint16_t)((s & 0x0100u) >> 1);           /*  8 ->  7 */
    r |= (uint16_t)((s & 0x0002u) << 1);           /*  1 ->  2 */
    r |= (uint16_t)((s & 0x0004u) >> 1);           /*  2 ->  1 */
    return r;
}

/* key3_spread: 8 -> 16 fan-out of key3's low byte (the decrypt_default XOR mask).
 * The high half is a fixed permutation of the byte; the low half is its mirror. */
static inline uint16_t s573_key3_spread(uint16_t k)
{
    uint16_t r = 0;
    r |= (uint16_t)(((k >> 7) & 1u) << 15) | (uint16_t)(((k >> 7) & 1u) <<  0);
    r |= (uint16_t)(((k >> 0) & 1u) << 14) | (uint16_t)(((k >> 0) & 1u) <<  1);
    r |= (uint16_t)(((k >> 6) & 1u) << 13) | (uint16_t)(((k >> 6) & 1u) <<  2);
    r |= (uint16_t)(((k >> 1) & 1u) << 12) | (uint16_t)(((k >> 1) & 1u) <<  3);
    r |= (uint16_t)(((k >> 5) & 1u) << 11) | (uint16_t)(((k >> 5) & 1u) <<  4);
    r |= (uint16_t)(((k >> 2) & 1u) << 10) | (uint16_t)(((k >> 2) & 1u) <<  5);
    r |= (uint16_t)(((k >> 4) & 1u) <<  9) | (uint16_t)(((k >> 4) & 1u) <<  6);
    r |= (uint16_t)(((k >> 3) & 1u) <<  8) | (uint16_t)(((k >> 3) & 1u) <<  7);
    return r;
}

/* One scrambled word in, one descrambled word out; the key schedule advances. */
static inline uint16_t s573_desc_step(s573_desc_t *s, uint16_t src)
{
    if (s->ddrsbm) {
        const uint16_t v = s573_dec_common(src, s->key1);
        s->key1 = (uint16_t)((s->key1 << 1) | (s->key1 >> 15));      /* rotl 1 */
        return v;
    } else {
        const uint16_t dk = s573_derive_key((uint16_t)(s->key1 ^ s->key2));
        const uint16_t v  = (uint16_t)(s573_dec_common(src, dk) ^ s573_key3_spread(s->key3));
        if (((s->key1 >> 14) ^ (s->key1 >> 15)) & 1u)
            s->key2 = (uint16_t)((s->key2 << 1) | (s->key2 >> 15));  /* cond rotl 1 */
        /* key1: rotate [14:0] left by one, bit 15 pinned */
        s->key1 = (uint16_t)((s->key1 & 0x8000u) |
                             ((s->key1 & 0x3FFFu) << 1) |
                             ((s->key1 >> 14) & 1u));
#ifndef S573_MUT_NO_KEY3_INC
        s->key3 = (uint16_t)(s->key3 + 1u);
#endif
        return v;
    }
}

/* ---- k573_mp3stream.v: the stream ------------------------------------------ */

void s573_desc_set_window(s573_desc_t *s, uint32_t mp3_start, uint32_t mp3_end)
{
    s->mp3_start = mp3_start;
    s->mp3_end   = mp3_end;
}

void s573_desc_set_keys(s573_desc_t *s, uint16_t key1, uint16_t key2, uint16_t key3)
{
    s->key1_seed = key1;
    s->key2_seed = key2;
    s->key3_seed = key3;
}

void s573_desc_set_ddrsbm(s573_desc_t *s, int ddrsbm)
{
    s->ddrsbm = (uint8_t)(ddrsbm ? 1 : 0);
}

void s573_desc_reload(s573_desc_t *s)
{
    s->key1         = s->key1_seed;
    s->key2         = s->key2_seed;
    s->key3         = s->key3_seed;
    s->cur          = s->mp3_start;
    s->byte_counter = 0;
    s->hold_valid   = 0;
    s->hold         = 0;
}

void s573_desc_init(s573_desc_t *s, uint32_t mp3_start, uint32_t mp3_end,
                    uint16_t key1, uint16_t key2, uint16_t key3, int ddrsbm)
{
    s->_pad = 0;
    s573_desc_set_window(s, mp3_start, mp3_end);
    s573_desc_set_keys(s, key1, key2, key3);
    s573_desc_set_ddrsbm(s, ddrsbm);
    s573_desc_reload(s);
}

int s573_desc_streaming(const s573_desc_t *s)
{
    return (s->cur < s->mp3_end) || s->hold_valid;
}

uint32_t s573_desc_stream_len(uint32_t mp3_start, uint32_t mp3_end)
{
    uint32_t span, words;
    if (mp3_end <= mp3_start) return 0;
    span  = mp3_end - mp3_start;
    words = (span + 1u) >> 1;               /* the last word may be a half word */
    return words * 2u - 1u;                 /* MAME drops the final low byte */
}

size_t s573_desc_pull(s573_desc_t *s, const uint8_t *dram, uint8_t *dst, size_t max)
{
    size_t n = 0;

    while (n < max) {
        uint32_t a;
        uint16_t src, v;
        int last;

        /* hand out the low byte buffered by the previous word first */
        if (s->hold_valid) {
            dst[n++]      = s->hold;
            s->hold_valid = 0;
            s->byte_counter++;
            continue;
        }

        if (s->cur >= s->mp3_end) break;    /* window exhausted -- park */

        a    = s->cur & ~1u;                /* the backing ignores address bit 0 */
        src  = (uint16_t)((uint16_t)dram[a] | ((uint16_t)dram[a + 1] << 8));
        v    = s573_desc_step(s, src);      /* advances the key schedule */

#ifdef S573_MUT_NO_2N1
        last = 0;
#else
        last = ((s->cur + 2u) >= s->mp3_end);
#endif

#ifdef S573_MUT_LOW_FIRST
        dst[n++] = (uint8_t)(v & 0xFFu);
        s->byte_counter++;
        if (!last) { s->hold = (uint8_t)(v >> 8); s->hold_valid = 1; }
#else
        dst[n++] = (uint8_t)(v >> 8);
        s->byte_counter++;
        if (!last) { s->hold = (uint8_t)(v & 0xFFu); s->hold_valid = 1; }
#endif
        s->cur += 2u;
    }
    return n;
}
