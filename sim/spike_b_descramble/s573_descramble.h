/* -----------------------------------------------------------------------------
 * s573_descramble.h - Konami System 573 Digital I/O MP3 stream descrambler
 *                     (HPS-side C reference; candidate for
 *                      Main_MiSTer/support/s573/)
 *
 * Reproduces, byte for byte, the stream the DIO-board FPGA emits toward the
 * MAS3507D: the fabric pair rtl/k573_mp3stream.v + rtl/k573_mp3dec.v, which are
 * themselves faithful to MAME src/mame/konami/k573fpga.cpp.
 *
 * The producer reads 16-bit words out of the board DRAM window (in this core: the
 * 32 MiB DIO sample-RAM aperture in DDR3, which the HPS can mmap), descrambles each
 * word with the running key schedule, and emits the descrambled word HIGH byte
 * first, LOW byte second. The final in-window word's LOW byte is dropped, so an
 * N-word window yields 2N-1 bytes -- the key schedule still advances for that last
 * word.
 *
 * Usage (the MD+-style poll loop shape):
 *
 *     s573_desc_t st;
 *     s573_desc_init(&st, mp3_start, mp3_end, key1, key2, key3, ddrsbm);
 *     ...
 *     n = s573_desc_pull(&st, dram_base, buf, sizeof buf);   // top up the FIFO
 *     ...on any MP3 setup-register write (start/end/key1/2/3):
 *     s573_desc_set_window(&st, new_start, new_end);
 *     s573_desc_set_keys(&st, k1, k2, k3);
 *     s573_desc_reload(&st);        // == MAME update_mp3_decode_state()
 *
 * C99, freestanding-friendly: no allocation, no libc calls, no globals, no I/O.
 * The caller owns both buffers. Little-endian host assumed for nothing -- the
 * DRAM word assembly is explicit.
 *
 * Released under the GNU GPL v2 (same terms as the RTL it mirrors).
 * ---------------------------------------------------------------------------- */
#ifndef S573_DESCRAMBLE_H
#define S573_DESCRAMBLE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /* seeds latched by the game at DIO 0xa8 / 0xea / 0xec */
    uint16_t key1_seed, key2_seed, key3_seed;
    /* live key schedule (advances one step per word consumed) */
    uint16_t key1, key2, key3;

    uint32_t mp3_start;      /* byte offset of the window inside the DRAM buffer */
    uint32_t mp3_end;        /* exclusive */
    uint32_t cur;            /* next word's byte offset */

    uint32_t byte_counter;   /* bytes emitted since the last reload (== the RTL's) */

    uint8_t  ddrsbm;         /* 0 = decrypt_default, 1 = DDR Solo Bass Mix */
    uint8_t  hold_valid;     /* a low byte is buffered and not yet handed out */
    uint8_t  hold;           /* that low byte */
    uint8_t  _pad;
} s573_desc_t;

/* Seed the descrambler and arm the window. Implies a reload. */
void s573_desc_init(s573_desc_t *s, uint32_t mp3_start, uint32_t mp3_end,
                    uint16_t key1, uint16_t key2, uint16_t key3, int ddrsbm);

/* Update the latched setup registers WITHOUT re-arming (the game writes them one
 * 16-bit half at a time; every such write pulses a reload in the fabric, so call
 * s573_desc_reload() after the last one). */
void s573_desc_set_window(s573_desc_t *s, uint32_t mp3_start, uint32_t mp3_end);
void s573_desc_set_keys(s573_desc_t *s, uint16_t key1, uint16_t key2, uint16_t key3);
void s573_desc_set_ddrsbm(s573_desc_t *s, int ddrsbm);

/* MAME update_mp3_decode_state(): cur <- mp3_start, re-seed the key schedule,
 * zero the position proxy, drop any buffered low byte. */
void s573_desc_reload(s573_desc_t *s);

/* Emit up to `max` stream bytes into `dst`. `dram` points at the byte-addressable
 * DRAM window that mp3_start/mp3_end index. Returns the number of bytes written;
 * a short return (including 0) means the window is exhausted -- the stream has
 * parked exactly as the fabric does. Resumable: state lives in *s, so any chunking
 * of the same stream yields the same byte sequence.
 *
 * Addressing note: every fetch is a 16-bit word read at (addr & ~1), matching the
 * fabric backing (k573dio muxes on rd_addr[2:1] and ignores bit 0). A window whose
 * length is odd therefore touches dram[mp3_end] on its final fetch -- size the
 * mapping to the window rounded up to a 2-byte boundary. */
size_t s573_desc_pull(s573_desc_t *s, const uint8_t *dram, uint8_t *dst, size_t max);

/* get_fpga_ctrl() bit 12 proxy: nonzero while the window still has data. */
int s573_desc_streaming(const s573_desc_t *s);

/* Total bytes an N-byte window will produce: 2N-1 for an N-word window. */
uint32_t s573_desc_stream_len(uint32_t mp3_start, uint32_t mp3_end);

#ifdef __cplusplus
}
#endif
#endif /* S573_DESCRAMBLE_H */
