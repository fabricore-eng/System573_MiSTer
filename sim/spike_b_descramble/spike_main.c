/* -----------------------------------------------------------------------------
 * spike_main.c - offline driver for the s573 descrambler C reference.
 *
 * Two jobs, neither of them shippable code (s573_descramble.c is the deliverable):
 *
 *   emit mode   read a DRAM image, run s573_desc_pull() over a window, write the
 *               emitted byte stream to a file so it can be diffed against the RTL.
 *               --chunk forces the pull() to be re-entered every N bytes, so the
 *               buffered-low-byte state is exercised across call boundaries.
 *               --cut/--end2 model a mid-stream reload (MAME
 *               update_mp3_decode_state): emit exactly --cut bytes, optionally move
 *               mp3_end, reload, then emit the restarted stream to completion.
 *
 *   bench mode  --bench: descramble a large buffer and report MB/s.
 *
 * C99. Build: cc -O2 -std=c99 -o spike_c spike_main.c s573_descramble.c
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "s573_descramble.h"

static uint32_t parse_u32(const char *s)
{
    return (uint32_t)strtoul(s, NULL, 0);   /* accepts 0x... and decimal */
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* xorshift32 -- fixed seed, so the bench buffer is reproducible */
static uint32_t xs32(uint32_t x)
{
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return x;
}

static int do_bench(size_t mib, int ddrsbm, int passes)
{
    const size_t   nbytes = mib * 1024u * 1024u;
    uint8_t       *dram   = (uint8_t *)malloc(nbytes + 8);
    uint8_t       *sink   = (uint8_t *)malloc(65536);
    uint32_t       r      = 0x13572468u;
    size_t         i;
    double         t0, t1, best = 1e30;
    int            p;
    uint64_t       total_out = 0;
    uint64_t       checksum  = 0;

    if (!dram || !sink) { fprintf(stderr, "bench: OOM\n"); return 2; }
    for (i = 0; i < nbytes + 8; i++) { r = xs32(r); dram[i] = (uint8_t)(r >> 11); }

    for (p = 0; p < passes; p++) {
        s573_desc_t st;
        uint64_t    out = 0;
        uint64_t    ck  = 0;
        size_t      n;

        s573_desc_init(&st, 0, (uint32_t)nbytes, 0x1357, 0x2468, 0x9BDF, ddrsbm);
        t0 = now_s();
        for (;;) {
            n = s573_desc_pull(&st, dram, sink, 65536);
            if (n == 0) break;
            out += n;
            ck  += sink[0] + sink[n - 1];   /* keep the optimiser honest */
        }
        t1 = now_s();
        if (t1 - t0 < best) best = t1 - t0;
        total_out = out;
        checksum  = ck;
    }

    printf("bench: scheme=%s  in=%.1f MiB  out=%llu bytes  best=%.4f s  "
           "throughput=%.1f MB/s  (chk=%llu)\n",
           ddrsbm ? "ddrsbm" : "default", (double)nbytes / 1048576.0,
           (unsigned long long)total_out, best,
           ((double)total_out / 1e6) / best, (unsigned long long)checksum);

    free(dram); free(sink);
    return 0;
}

int main(int argc, char **argv)
{
    const char *binpath = NULL, *outpath = NULL;
    uint32_t start = 0, end = 0, end2 = 0, cut = 0, chunk = 0;
    uint16_t k1 = 0, k2 = 0, k3 = 0;
    int      ddrsbm = 0, bench = 0, benchmib = 16, benchpass = 5;
    int      i;

    uint8_t *dram = NULL, *outbuf = NULL;
    size_t   dramlen = 0, produced = 0, cap;
    FILE    *f;
    s573_desc_t st;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT() (++i < argc ? argv[i] : "0")
        if      (!strcmp(a, "--bin"))    binpath = NEXT();
        else if (!strcmp(a, "--out"))    outpath = NEXT();
        else if (!strcmp(a, "--start"))  start  = parse_u32(NEXT());
        else if (!strcmp(a, "--end"))    end    = parse_u32(NEXT());
        else if (!strcmp(a, "--end2"))   end2   = parse_u32(NEXT());
        else if (!strcmp(a, "--cut"))    cut    = parse_u32(NEXT());
        else if (!strcmp(a, "--chunk"))  chunk  = parse_u32(NEXT());
        else if (!strcmp(a, "--key1"))   k1     = (uint16_t)parse_u32(NEXT());
        else if (!strcmp(a, "--key2"))   k2     = (uint16_t)parse_u32(NEXT());
        else if (!strcmp(a, "--key3"))   k3     = (uint16_t)parse_u32(NEXT());
        else if (!strcmp(a, "--ddrsbm")) ddrsbm = (int)parse_u32(NEXT());
        else if (!strcmp(a, "--bench"))  bench  = 1;
        else if (!strcmp(a, "--mib"))    benchmib  = (int)parse_u32(NEXT());
        else if (!strcmp(a, "--passes")) benchpass = (int)parse_u32(NEXT());
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
        #undef NEXT
    }

    if (bench) return do_bench((size_t)benchmib, ddrsbm, benchpass);

    if (!binpath || !outpath) { fprintf(stderr, "need --bin and --out\n"); return 2; }
    if (chunk == 0) chunk = 4096;

    f = fopen(binpath, "rb");
    if (!f) { perror(binpath); return 2; }
    fseek(f, 0, SEEK_END); dramlen = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    dram = (uint8_t *)malloc(dramlen + 8);
    if (!dram || fread(dram, 1, dramlen, f) != dramlen) { fprintf(stderr, "read fail\n"); return 2; }
    fclose(f);
    memset(dram + dramlen, 0, 8);

    /* worst case: the pre-cut prefix plus a full restarted stream */
    cap = (size_t)s573_desc_stream_len(start, end) +
          (size_t)s573_desc_stream_len(start, end2 ? end2 : end) + 64;
    outbuf = (uint8_t *)malloc(cap);
    if (!outbuf) { fprintf(stderr, "OOM\n"); return 2; }

    s573_desc_init(&st, start, end, k1, k2, k3, ddrsbm);

    /* phase 1: up to `cut` bytes (or the whole stream when cut == 0) */
    {
        size_t limit = cut ? (size_t)cut : cap;
        while (produced < limit) {
            size_t want = limit - produced;
            size_t n;
            if (want > chunk) want = chunk;
            n = s573_desc_pull(&st, dram, outbuf + produced, want);
            if (n == 0) break;
            produced += n;
        }
    }

    /* phase 2: the mid-stream reload (a setup-register write) */
    if (cut) {
        if (end2) s573_desc_set_window(&st, start, end2);
        s573_desc_reload(&st);
        for (;;) {
            size_t want = cap - produced;
            size_t n;
            if (want > chunk) want = chunk;
            if (want == 0) break;
            n = s573_desc_pull(&st, dram, outbuf + produced, want);
            if (n == 0) break;
            produced += n;
        }
    }

    f = fopen(outpath, "wb");
    if (!f) { perror(outpath); return 2; }
    if (produced && fwrite(outbuf, 1, produced, f) != produced) { fprintf(stderr, "write fail\n"); return 2; }
    fclose(f);

    printf("c: bytes=%zu byte_counter=%u cur=0x%x streaming=%d\n",
           produced, st.byte_counter, st.cur, s573_desc_streaming(&st));
    free(dram); free(outbuf);
    return 0;
}
