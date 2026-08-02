// -----------------------------------------------------------------------------
// k573dio.v - Konami System 573 BEMANI "Digital I/O" board register block
//             (GX894, mapped at 0x1f640000)
//
// The Digital I/O board adds, around a XILINX XCS40XL Spartan-XL FPGA (208-pin
// PQFP; NOT an Altera part -- corrected 2026-07-29 against a board photo and
// MAME's own board notes, which give another lot of the same device: "XCS40XL -
// XILINX XCS40XL PQ208AKP9929 A2033251A 4C". The only Altera in this repo is the
// MiSTer Cyclone V we TARGET, under psx/sys/): lamp/light outputs, an
// MP3 streaming path (MAS3507D decoder fed from board DRAM, with a three-word
// descrambler key), the board's own DS2401 serial number, and a small network
// link.
//
// The FPGA has NO configuration PROM: it boots in Xilinx slave-serial mode and the
// GAME uploads a 41337-byte bitstream at runtime, one bit per write to 0xf8, with
// /PROGRAM, /INIT, DONE and CCLK handled by a separate XILINX XC9536 CPLD behind
// 0xf0-0xff (which is why that range is live with no bitstream loaded). Seven
// distinct Konami bitstreams are known, and they differ CHIEFLY IN THE MP3
// DESCRAMBLING ALGORITHM -- i.e. the crypto is per-title reconfigurable logic, not
// fixed silicon. That is the hardware reason two schemes exist in k573_mp3dec.v
// (decrypt_default vs the DDR Solo Bass Mix variant), and the reason more could.
// Refs: psx-spx "Konami System 573" (Digital I/O register map + CPLD pin mapping),
// MAME src/mame/konami/k573dio.cpp + k573fpga.cpp.
//
// This module implements the *deterministic register glue* of that board
// and instantiates the board DS2401 and the MAS3507D I2C control port (the
// boot-check gate; see rtl/mas3507d_i2c.v); the FPGA-internal MP3 audio
// decode and the network engine are left as clearly-marked stubs for now.
//
// Register map (16-bit, byte offsets within the 0x1f640000 window), from MAME's
// src/mame/konami/k573dio.cpp:
//
//   0x00 r =0x0000  0x02 r =0x0001  0x04/06/0a r =0x0000   0x80 r =0x1234 (id)
//   0xa0..a7 r/w  MP3 start/end address (32-bit, hi/lo)
//   0xa8 w  crypto key1     r = decoded MP3 frame counter (get_mp3_frame_count)
//   0xaa r  mpeg_status (bit12 DEMAND, 13 IDLE, 14 PLAYING; 15 ENABLED unused)
//   0xac r/w MAS3507D I2C: w bit13=SCL bit12=SDA (open-drain, reset high),
//            r bit13 = SCL host latch (slave never stretches), bit12 =
//            SDA host latch AND slave pull (wired-AND) -- MAME k573fpga.cpp
//   0xae r/w FPGA control latch
//   0xb0/b2 w  DRAM write address hi/lo     0xb4 r/w DRAM data (auto-increment)
//   0xb6/b8 w  DRAM read  address hi/lo
//   0xc0..c5 network (stub)   0xca/cc r MP3 sample counter (hi/lo latch)  0xcc w reset  0xce r diff
//   0xe0/e2/e4/e6/fa/fc/fe w  lamp outputs (registers 1,0,3,7,4,5,2)
//   0xea w crypto key2   0xec w crypto key3
//   0xee r/w  board DS2401 (1-wire on bit 12)
//   0xf6 r =0xB000 FPGA status    0xf8 w FPGA firmware (stub)
//   0x90 w network id    0x10 w unknown
//
// Each lamp register takes bits [15:12] as a 4-bit value and fans it out to four
// lamp lines with the fixed bit remap {0,2,3,1} (see output() in MAME).
//
// ---- board DRAM backing (parameter BACKING_EXTERNAL) ----
//
// The real board carries 3x HY51V65164A = 24 MiB of sample DRAM; MAME models one
// flat 32 MiB share masked 0x1ffffff, and ddrsbm's POST "MEMORY CHECK" sweeps a
// 16-bit counter pattern over the full 3x 8 MB (22H @0x000000, 22J @0x800000,
// 22G @0x1000000) through the auto-increment port -- one mismatch = BAD.
//
//   BACKING_EXTERNAL=0 (default, iverilog): the RAM_WORDS-word inline array
//     below -- small, aliasing, register-model tests only.
//
//   BACKING_EXTERNAL=1 (Quartus/HW): the 32 MiB window lives in DDR3 behind the
//     mem_rd_*/mem_wr_* channels (s573_ddram_arb in emu.sv; s573_flash SDRAM
//     line-buffer precedent). CPU b4 READS serve from a 2-line (64-bit beat)
//     cache with next-beat prefetch -- the sweep is sequential, so steady-state
//     reads are all hits; a miss stalls the CPU through dio_wait (the patch-0006
//     EXP1 read wait, which HOLDS the read strobe until the line fills -- the
//     auto-increment below is therefore qualified by the hit, firing exactly
//     once, in the completion cycle). CPU b4 WRITES can never stall: they post
//     into a 1024-deep FIFO drained one beat-write at a time (16-bit lane byte
//     enables, no read-modify-write). Overflow is a FAULT: sticky dbg_wfifo_ovf
//     + $fatal in sim -- never silently dropped (no-mask-fault rule).
//     Coherency is drain-before-read: any push invalidates all cached lines
//     (and poisons an in-flight fill), and no read is issued until the FIFO is
//     empty -- so a valid line can never be stale.
//   The MP3 streamer reads through its own single beat-hold line on the same
//   scheduler (lowest priority; its FSM waits on rd_ready).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module k573dio #(
    parameter integer RAM_WORDS  = 4096,                 // sim-sized DRAM window
    parameter [47:0]  DS_SERIAL  = 48'h0000_0000_0001,   // board DS2401 serial
    parameter integer DS_CLK_HZ  = 1_000_000,
    parameter integer BACKING_EXTERNAL = 0,              // 1 = DDR3-backed 32 MiB
    // Byte offset within the DIO window at or above which a game write would
    // land in the P4b HPS PCM ring (window offset 0x1F10000, 256 KiB).
    //
    // must-fix #2 asked whether the ring collides with the game's own sample RAM.
    // It cannot on real hardware: the GX894 carries 3x HY51V65164A = 24 MiB
    // (22H @0x000000, 22J @0x800000, 22G @0x1000000) and the ring sits at
    // 31.06 MiB -- 7.06 MiB above the last byte the board has memory for. But
    // OUR window is a flat 32 MiB, so a stray write would reach it, and "the game
    // stays inside 24 MiB" is an assumption about SOFTWARE. This flag observes it
    // instead of trusting it; expected to read 0 forever.
    //
    // A RANGE, not a threshold: only the ring itself is harmful, and the rest of
    // the 24-32 MiB space above real DRAM is legitimately exercised -- this bench
    // writes at both 0x1800000 and the very top of the window (0x1FFFFC2), and an
    // ">= base" guard false-fired on the latter.
    parameter [24:0]  RING_GUARD_BASE  = 25'h1F10000,
    parameter [24:0]  RING_GUARD_SIZE  = 25'h0040000   // 256 KiB PCM ring
)(
    input  wire        clk,
    input  wire        rst,

    // bus side (offset within the 0x1f640000 window, as decoded by s573_bus)
    input  wire        sel,
    input  wire [7:0]  off,
    input  wire        we,
    input  wire        re,
    input  wire [15:0] din,
    output reg  [15:0] dout,

    // b4 READ stall (BACKING_EXTERNAL only): high while a b4 read misses the
    // line cache; OR'd into the psx EXP1 read wait (patch 0006) by emu.sv.
    // Never asserts for any other offset, and never for writes.
    output wire        dio_wait,

    // MP3 descramble scheme select (MAME set_ddrsbm_fpga: 1 = DDR Solo Bass Mix).
    // Was a parameter; now plumbed so P4 can drive it per-game. emu.sv ties it 0
    // until the MP3 path is wired for real.
    input  wire        cfg_ddrsbm,

    // external DIO-RAM backing (BACKING_EXTERNAL=1; both idle otherwise).
    // 4-phase level handshakes into s573_ddram_arb's DIO client (clk_2x side).
    output reg         mem_rd_req,
    output reg  [21:0] mem_rd_addr,    // 64-bit beat index within the 32 MiB window
    input  wire [63:0] mem_rd_q,
    input  wire        mem_rd_ack,
    output reg         mem_wr_req,
    output reg  [23:0] mem_wr_addr,    // 16-bit word index within the window
    output reg  [15:0] mem_wr_data,
    input  wire        mem_wr_ack,

    // sticky posted-write FIFO overflow (a fault, never silent; sim $fatal)
    output wire        dbg_wfifo_ovf,

    // Sticky: the game wrote at/above RING_GUARD_BASE, i.e. into address space
    // the real board has no DRAM for -- and where P4b parks the PCM ring. This
    // is a DETECTOR, not a filter: the write still happens, so a silicon-proven
    // path keeps its exact behaviour. It exists so that if the "24 MiB is all a
    // game can touch" assumption is ever wrong, we find out from a flag instead
    // of from corrupted audio. Expected to read 0 forever.
    output wire        dbg_dio_hi_write,

    // board outputs
    output reg  [31:0] lamp,         // 32 lamp/light lines
    output reg  [15:0] crypto_key1,  // MP3 descrambler keys (to the FPGA path)
    output reg  [15:0] crypto_key2,
    output reg  [15:0] crypto_key3,
    output reg  [31:0] mp3_start,    // MP3 data window in board DRAM
    output reg  [31:0] mp3_end,
    output reg  [15:0] fpga_ctrl,
    output reg  [15:0] network_id,

    // ---- P4b option-(c): what the HPS descrambler needs to see ----
    // The config registers above (mp3_start/end, crypto_key1..3, fpga_ctrl) are
    // the payload; these two are the metadata that makes them usable.
    output reg  [15:0] cfg_epoch,    // ++ per re-arm; HPS re-reads CMD_573_MP3CFG
    // MAS3507D output gain matrix, decoded off the I2C bus (mas3507d_i2c.v).
    // The game's own output level; zero = mute. Ignoring it is why we clip.
    output wire [19:0] gain_ll,
    output wire [19:0] gain_rr,
    output wire        gain_stb,
    output wire [24:0] mp3_cur_pos,  // streamer position echo (desync check)

    // MP3 sink back-pressure (MAS3507D DEMAND model): high = the downstream sink
    // can accept a byte this cycle. P4b drives this from the HPS byte-FIFO
    // not-full; emu.sv holds it low until then, so the descrambled stream is
    // honestly back-pressured to a halt (the bytes dangle unconsumed anyway)
    // rather than flooding the DIO-RAM read port.
    input  wire        mp3_out_ready,

    // descrambled MP3 byte stream out to the MAS3507D decoder
    output wire [7:0]  mp3_out_byte,
    output wire        mp3_out_valid,

    // ---- MP3 decode COUNTER drivers (P4b HPS minimp3 + PCM-drain transport) ----
    // The gameplay clock the game reads to advance the chart (0xa8 frame count,
    // 0xca/cc sample position) is a DECODE counter -- driven by the HPS decoder,
    // NEVER a bytes-sent proxy (see docs/2026-07-03-p4-mp3-pacing-model.md). These
    // three inputs carry that decode progress into the register block. emu.sv ties
    // them 0 until the HPS decode service exists, so every counter reads a truthful
    // zero (exactly like mas3507d_i2c's frame_count) rather than a fabricated clock.
    input  wire        dec_frame_sync,  // 1-cyc: HPS decoded one MPEG frame (MAME mpeg_frame_sync(1))
    input  wire        dec_frame_idle,  // 1-cyc: an HPS decode produced no frame (MAME mpeg_frame_sync(0))
    input  wire        pcm_sample_tick  // 1-cyc per PCM sample DRAINED @44100Hz -> sample counter++
);
    // `make DIO_RAM_STUB=1 k573dio_ram` red/green switch: force the pre-fix
    // aliasing inline array even when the TB asks for the external backing --
    // tb_k573dio_ram is RED under it (the 3x 8 MB regions alias mod 8 KB, the
    // MEMORY CHECK pattern collides) and GREEN by default.
`ifdef DIO_RAM_STUB
    localparam integer EXT_BACKING = 0;
`else
    localparam integer EXT_BACKING = BACKING_EXTERNAL;
`endif

    // ----- MP3 decode counter state (0xa8 / 0xaa / 0xca / 0xcc / 0xce) -----
    // Declared here so the mas3507d_i2c frame-count read can source the real
    // counter; driven by the always block after the MP3 streamer (see there for
    // the full MAME-faithful semantics).
    reg [31:0] mp3_frame_counter;   // decoded MPEG frames (get_mp3_frame_count)
    reg [31:0] mp3_sample_counter;  // PCM sample position (get_counter / 44100)
    reg        mp3_synced;          // counter armed (first frame sync seen since reset)
    reg [31:0] fpga_counter_lat;    // 0xca/cc 32-bit latch (k573dio fpga_counter)
    reg [31:0] mp3_diff_ref;        // 0xce reference (counter at last 0xcc/0xce read)
    reg        mpeg_playing;        // mpeg_status bit14
    reg        mpeg_idle;           // mpeg_status bit13

    // ----- board DS2401 (1-wire), driven through register 0xee bit 12 -----
    reg         ow_master_low;
    wire        ow_pd;
    wire        ow_line = ~(ow_master_low | ow_pd);  // wired-AND, pulled up
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) board_id (
        .clk(clk), .rst(rst), .dq_in(ow_line), .dq_pd(ow_pd),
        // The DIO board's DS2401 keeps its compile-time SERIAL param (no image load).
        .load_we(1'b0), .load_addr(3'd0), .load_data(8'd0)
    );

    // ----- MAS3507D I2C control port, bit-banged through register 0xac -----
    reg  mas_scl, mas_sda;       // host line latches, reset HIGH (bus idle)
    wire mas_sda_pd;             // slave pull-down (wired-AND onto SDA)
    mas3507d_i2c mas_i2c (
        .clk(clk), .rst(rst),
        .scl(mas_scl), .sda(mas_sda), .sda_pd(mas_sda_pd),
        // the real decoded-frame count (== get_mp3_frame_count); 0 until P4b's HPS
        // decode drives dec_frame_sync -- a truthful zero, not a stub lie.
        .frame_count(mp3_frame_counter),
        .gain_ll(gain_ll), .gain_rr(gain_rr), .gain_stb(gain_stb)
    );

    // ----- DRAM pointers (common to both backings) -----
    reg [24:0] ram_adr;        // write pointer
    reg [24:0] ram_read_adr;   // read pointer

    // per-backing b4 data plumbing (assigned inside the generate blocks)
    wire [15:0] b4_rdata;      // read data for a b4 read THIS cycle
    wire        b4_rd_adv;     // this b4 read completes this cycle -> advance ptr
    wire        b4_wr_adv = sel && we && (off == 8'hb4);   // writes never stall

    // ----- MP3 streaming: read DRAM, descramble, emit bytes to the MAS3507D -----
    // The DRAM read port is a req/ready handshake (registered data, held until
    // the next request) so an external backing can insert real latency.
    wire [24:0] s_rd_addr;
    wire        s_rd_req;
    wire [15:0] s_rd_data;
    wire        s_rd_ready;
    wire [15:0] fpga_ctrl_rb;

    // MP3 stream re-arm (MAME update_mp3_decode_state): any write to the MP3 setup
    // registers -- start hi/lo (a0/a2), end hi/lo (a4/a6), key1/2/3 (a8/ea/ec) --
    // re-inits the stream (cur<-start, re-seed keys). One-cycle pulse (bus write is
    // one cycle). Fixes the pre-fix one-shot that ignored an mp3_end extension.
    wire mp3_reload = sel && we &&
        (off == 8'ha0 || off == 8'ha2 || off == 8'ha4 || off == 8'ha6 ||
         off == 8'ha8 || off == 8'hea || off == 8'hec);

    // ... but the STREAMER's copy of the pulse must arrive ONE CYCLE LATE. mp3_reload
    // is combinational on the bus write, while the register that write updates lands
    // non-blocking on the SAME posedge -- and k573_mp3stream does `cur <= mp3_start`
    // on that same edge, so it would sample the PRE-write mp3_start and re-arm to the
    // previous song's address. MAME cannot have this: k573dio.cpp stores the register
    // FIRST and only then calls update_mp3_decode_state(). Delaying by one cycle makes
    // the streamer sample post-write values, which is the same ordering.
    // Self-healed by any FURTHER setup write (each one re-pulses), so it only bit when
    // a0/a2 closed the burst -- see sim/tb_dio_mp3_reload.v.
    // The pulse COUNT is preserved (one per write, even back-to-back), so the mp3_end
    // extension re-arm is unaffected. The decode-counter resets below deliberately stay
    // on the undelayed pulse: they only zero counters, sample no register value, and a
    // counter cannot advance in the one cycle of skew.
`ifdef MP3_RELOAD_RACE
    wire mp3_reload_s = mp3_reload;      // pre-fix: same-edge pulse -> stale mp3_start
`else
    reg  mp3_reload_q = 1'b0;
    always @(posedge clk) mp3_reload_q <= rst ? 1'b0 : mp3_reload;
    wire mp3_reload_s = mp3_reload_q;
`endif

    k573_mp3stream u_stream (
        .clk(clk), .rst(rst),
        .fpga_ctrl(fpga_ctrl), .ddrsbm(cfg_ddrsbm),
        .mp3_start(mp3_start[24:0]), .mp3_end(mp3_end[24:0]),
        .key1(crypto_key1), .key2(crypto_key2), .key3(crypto_key3),
        .reload(mp3_reload_s),
        .rd_addr(s_rd_addr), .rd_req(s_rd_req),
        .rd_data(s_rd_data), .rd_ready(s_rd_ready),
        .out_ready(mp3_out_ready),
        .out_byte(mp3_out_byte), .out_valid(mp3_out_valid),
        .byte_counter(), .fpga_ctrl_rb(fpga_ctrl_rb),
        .cur_pos(mp3_cur_pos)
    );

    // ---- P4b option-(c) config epoch --------------------------------------
    // Bumped on the SAME (registered) pulse that re-arms the streamer, so the
    // epoch can never advertise a config the streamer has not adopted yet.
    // The HPS watches this one word every poll and re-reads CMD_573_MP3CFG only
    // when it moves; a monotonic COUNTER, never a sticky bit, because two song
    // changes between polls must not look like one (transport-design must-fix
    // #1). Free-running wrap at 2^16 is fine: the HPS compares for INEQUALITY,
    // it never orders epochs.
    // INVARIANT: cfg_epoch moves whenever ANYTHING the HPS mirrors changes -- not
    // just on a song re-arm. Three sources, and the last two are easy to miss:
    //
    //  * mp3_reload_s   -- new song (start/end/keys rewritten).
    //  * cfg_ddrsbm     -- an OSD bit (emu.sv O[101]); moves with NO game activity
    //                      at all. Miss it and the HPS keeps the previous key
    //                      schedule: noise, with every decode counter still GREEN.
    //  * fpga_ctrl[14:13] -- MP3_ENABLE / STREAMING_ENABLE, i.e. the game pressing
    //                      play or stop. MAME's set_fpga_ctrl deliberately does NOT
    //                      re-arm the stream (k573_mp3stream's header), so these
    //                      bits move with no reload pulse. The HPS drives the PCM
    //                      drain from them, so without this it would never learn
    //                      that playback started and the drain would stay off --
    //                      silence, with nothing anywhere reporting an error.
    reg       cfg_ddrsbm_q = 1'b0;
    reg [1:0] fpga_en_q    = 2'b00;
    always @(posedge clk) begin
        if (rst) begin
            cfg_epoch     <= 16'd0;
            cfg_ddrsbm_q  <= cfg_ddrsbm;
            fpga_en_q     <= fpga_ctrl[14:13];
        end else begin
            cfg_ddrsbm_q <= cfg_ddrsbm;
            fpga_en_q    <= fpga_ctrl[14:13];
            if (mp3_reload_s || (cfg_ddrsbm != cfg_ddrsbm_q)
                             || (fpga_ctrl[14:13] != fpga_en_q))
                cfg_epoch <= cfg_epoch + 16'd1;
        end
    end

    // =========================================================================
    // MP3 decode counters + mpeg_status (0xa8 / 0xaa / 0xca / 0xcc / 0xce)
    //
    // Faithful to MAME 0.285 k573fpga.cpp / k573dio.cpp. These are the registers
    // the game polls to advance the chart clock; the ddrsbm stage-"ready" loop
    // waits on the sample counter. Driven by the HPS decode / PCM-drain inputs
    // (dec_frame_sync / dec_frame_idle / pcm_sample_tick), all idle until P4b.
    //
    //  * 0xa8 get_mp3_frame_count = mp3_frame_counter & 0xffff. Increments once per
    //    decoded MPEG frame while FPGA_FRAME_COUNTER_ENABLE (fpga_ctrl bit15) is
    //    set; clearing bit15 resets it (MAME set_fpga_ctrl); a decode-state change
    //    (mp3_reload) also resets it (update_mp3_decode_state).
    //  * 0xcc mp3_counter_low_r = get_counter() & 0xffff, get_counter =
    //    counter_value*44100 = the PCM SAMPLE POSITION (elapsed 44100Hz samples
    //    since the first frame sync). Reading 0xcc LATCHES the full 32-bit counter;
    //    0xca returns that latch's high word -- the game reads 0xcc then 0xca and
    //    gets a coherent 32-bit value. reset_counter (0xcc write, or mp3_reload)
    //    zeroes + disarms it; the first frame sync re-arms + zeroes it.
    //    DRIVEN OFF PCM DRAIN (pcm_sample_tick), never bytes-sent: bytes != samples
    //    under VBR, so a bytes proxy would drift the arrow sync (the P4 plan's
    //    single biggest correctness risk).
    //  * 0xaa get_mpeg_ctrl = mpeg_status: bit12 DEMAND (= sink back-pressure
    //    mp3_out_ready), bit13 IDLE, bit14 PLAYING (toggled by the frame-sync
    //    pulses), bit15 ENABLED (defined but never set in MAME 0.285 -> 0).
    //  * 0xce mp3_counter_diff_r = samples since the last counter read. MAME notes
    //    it has no active game usages; modeled as a best-effort delta.
    //
    // NOTE (ddrsbm): MAME's ddrsbm counter free-runs on wall-clock even when no
    // audio plays; we source it from real PCM drain per the P4 plan (no-mask: never
    // invent a clock the decoder did not produce). For continuous playback the two
    // match; the audio-stopped divergence is a P4c silicon-verify item.
    // =========================================================================
    reg        re_prev;
    reg  [7:0] off_prev;
    wire rd_active = sel && re;
    wire rd_end    = re_prev && !rd_active;            // a register read just ended
    wire rd_cc     = rd_active && (off == 8'hcc);      // get_counter: latch on read
    wire cc_end    = rd_end && (off_prev == 8'hcc);    // advance the 0xce diff ref
    wire ce_end    = rd_end && (off_prev == 8'hce);
    wire cnt_rst_w = sel && we && (off == 8'hcc);      // mp3_counter_low_w -> reset_counter
    // FPGA_FRAME_COUNTER_ENABLE (fpga_ctrl bit15) 1->0 resets the frame counter
    // (MAME set_fpga_ctrl checks the new data vs the old fpga_status).
    wire fce_clr   = sel && we && (off == 8'hae) && ~din[15] && fpga_ctrl[15];

    // 0xaa: {ENABLED=0, PLAYING, IDLE, DEMAND, 12'b0}
    wire [15:0] mpeg_status = {1'b0, mpeg_playing, mpeg_idle, mp3_out_ready, 12'b0};

    always @(posedge clk) begin
        if (rst) begin
            mp3_frame_counter  <= 32'd0;
            mp3_sample_counter <= 32'd0;
            mp3_synced         <= 1'b0;
            fpga_counter_lat   <= 32'd0;
            mp3_diff_ref       <= 32'd0;
            mpeg_playing       <= 1'b0;
            mpeg_idle          <= 1'b0;
            re_prev            <= 1'b0;
            off_prev           <= 8'd0;
        end else begin
            re_prev  <= rd_active;
            off_prev <= off;

            // ---- 0xa8 decoded-frame counter ----
            if (mp3_reload || fce_clr)
                mp3_frame_counter <= 32'd0;
            else if (dec_frame_sync && fpga_ctrl[15])
                mp3_frame_counter <= mp3_frame_counter + 32'd1;

            // ---- sample counter (get_counter = PCM sample position, 44100/s) ----
            if (mp3_reload || cnt_rst_w) begin
                mp3_sample_counter <= 32'd0;
                mp3_synced         <= 1'b0;             // disarm until the next frame sync
            end else if (dec_frame_sync && !mp3_synced) begin
                mp3_sample_counter <= 32'd0;            // first sync since reset: t=0
                mp3_synced         <= 1'b1;
            end else if (mp3_synced && pcm_sample_tick) begin
                mp3_sample_counter <= mp3_sample_counter + 32'd1;
            end

            // ---- 0xca/cc latch: reading 0xcc captures the full 32-bit counter.
            // The registered latch here and the live low word returned by the read
            // mux both sample mp3_sample_counter on the same posedge, and the EXP1
            // slave captures dout after re drops -- so the 0xcc low word and the
            // later 0xca high word are coherent to the same instant.
            if (rd_cc) fpga_counter_lat <= mp3_sample_counter;

            // ---- 0xce diff reference: reset re-references it to "now" (MAME
            // reset_counter sets counter_current=now -> 0xce reads ~0), else advance
            // after a 0xcc / 0xce read completes. Reset takes precedence.
            if (mp3_reload || cnt_rst_w) mp3_diff_ref <= 32'd0;
            else if (cc_end || ce_end)   mp3_diff_ref <= mp3_sample_counter;

            // ---- mpeg_status PLAYING / IDLE (MAME mpeg_frame_sync 1 / 0) ----
            if (dec_frame_sync)      begin mpeg_playing <= 1'b1; mpeg_idle <= 1'b0; end
            else if (dec_frame_idle) begin mpeg_playing <= 1'b0; mpeg_idle <= 1'b1; end
        end
    end

    // =========================================================================
    // backing: inline sim array (default) or DDR3 line cache + posted-write FIFO
    // =========================================================================
    generate if (EXT_BACKING == 0) begin : g_int

        reg [15:0] ram [0:RAM_WORDS-1];
        wire [24:0] widx = (ram_adr      >> 1) & (RAM_WORDS-1);
        wire [24:0] ridx = (ram_read_adr >> 1) & (RAM_WORDS-1);

        always @(posedge clk)
            if (b4_wr_adv) ram[widx] <= din;

        assign b4_rdata  = ram[ridx];
        assign b4_rd_adv = sel && re && (off == 8'hb4);
        assign dio_wait  = 1'b0;
        assign dbg_wfifo_ovf = 1'b0;
        assign dbg_dio_hi_write = 1'b0;

        // MP3 read port: registered one-cycle serve
        reg [15:0] s_dat_r;
        reg        s_rdy_r;
        always @(posedge clk) begin
            if (rst) begin
                s_rdy_r <= 1'b0;
            end else begin
                s_rdy_r <= 1'b0;
                if (s_rd_req && !s_rdy_r) begin
                    s_dat_r <= ram[(s_rd_addr >> 1) & (RAM_WORDS-1)];
                    s_rdy_r <= 1'b1;
                end
            end
        end
        assign s_rd_data  = s_dat_r;
        assign s_rd_ready = s_rdy_r;

        // external channels idle
        always @(*) begin
            mem_rd_req  = 1'b0; mem_rd_addr = 22'd0;
            mem_wr_req  = 1'b0; mem_wr_addr = 24'd0; mem_wr_data = 16'd0;
        end

    end else begin : g_ext

        // ---- 2-line beat cache (CPU) + 1-line (MP3) ----
        reg         lineA_v, lineB_v, lineM_v;
        reg [21:0]  lineA_t, lineB_t, lineM_t;
        reg [63:0]  lineA_d, lineB_d, lineM_d;
        reg [21:0]  last_beat;         // most recently served CPU beat
        reg         last_v;            // ... valid -> prefetch last_beat+1

        // ---- posted-write FIFO (1024 x {word index, data}) ----
        reg [39:0]  wfifo [0:1023];
        reg [9:0]   wf_wp, wf_rp;
        reg [10:0]  wf_cnt;
        reg         ovf;

        // ---- scheduler ----
        localparam [2:0] E_IDLE   = 3'd0,
                         E_WR     = 3'd1,  // write req held until ack
                         E_WR_END = 3'd2,  // wait ack low
                         E_RD     = 3'd3,  // read req held until ack
                         E_RD_END = 3'd4;  // wait ack low
        localparam [1:0] W_CPU = 2'd0, W_PF = 2'd1, W_MP3 = 2'd2;
        reg [2:0]  est;
        reg [1:0]  rd_who;
        reg        poison;             // a push landed while a fill was in flight

        // posted-write push ACCEPT (shared by the push branch and the pop's
        // same-cycle compensation): a full-FIFO push is DROPPED, so the pop
        // must not re-add it -- else wf_cnt runs one ahead of true occupancy
        // forever and every later drain pops a lap-stale slot.
        wire        push_ok  = (sel && we && (off == 8'hb4)) && (wf_cnt != 11'd1024);

        // ---- CPU b4 read serve (combinational) ----
        wire        b4r      = sel && re && (off == 8'hb4);
        wire [21:0] cpu_beat = ram_read_adr[24:3];
        wire        hitA     = lineA_v && (lineA_t == cpu_beat);
        wire        hitB     = lineB_v && (lineB_t == cpu_beat);
        wire [63:0] cpu_line = hitA ? lineA_d : lineB_d;
        wire [63:0] cpu_shft = cpu_line >> {ram_read_adr[2:1], 4'b0000};
        wire        cpu_ok   = hitA | hitB;

        assign b4_rdata  = cpu_shft[15:0];
        assign b4_rd_adv = b4r && cpu_ok;   // completion cycle only (see header)
        assign dio_wait  = b4r && !cpu_ok;
        assign dbg_wfifo_ovf = ovf;
        reg hiwr = 1'b0;
        assign dbg_dio_hi_write = hiwr;

        // ---- MP3 serve: own line, registered pulse ----
        wire [21:0] mp3_beat = s_rd_addr[24:3];
        wire        hitM     = lineM_v && (lineM_t == mp3_beat);
        wire [63:0] mp3_shft = lineM_d >> {s_rd_addr[2:1], 4'b0000};
        reg  [15:0] s_dat_r;
        reg         s_rdy_r;
        assign s_rd_data  = s_dat_r;
        assign s_rd_ready = s_rdy_r;

        // prefetch target: the beat after the last served one, if absent
        wire [21:0] pf_beat = last_beat + 22'd1;
        wire        pf_cached = (lineA_v && (lineA_t == pf_beat)) ||
                                (lineB_v && (lineB_t == pf_beat));
        // fill placement: keep the line holding the in-use (last served) beat
        wire        fill_into_B = lineA_v && (lineA_t == last_beat);

        always @(posedge clk) begin
            if (rst) begin
                lineA_v <= 1'b0; lineB_v <= 1'b0; lineM_v <= 1'b0;
                lineA_t <= 22'd0; lineB_t <= 22'd0; lineM_t <= 22'd0;
                lineA_d <= 64'd0; lineB_d <= 64'd0; lineM_d <= 64'd0;
                last_beat <= 22'd0; last_v <= 1'b0;
                wf_wp <= 10'd0; wf_rp <= 10'd0; wf_cnt <= 11'd0; ovf <= 1'b0;
                est <= E_IDLE; rd_who <= W_CPU; poison <= 1'b0;
                mem_rd_req <= 1'b0; mem_rd_addr <= 22'd0;
                mem_wr_req <= 1'b0; mem_wr_addr <= 24'd0; mem_wr_data <= 16'd0;
                s_rdy_r <= 1'b0; s_dat_r <= 16'd0;
            end else begin
                s_rdy_r <= 1'b0;

                // -- CPU serve bookkeeping --
                if (b4_rd_adv) begin
                    last_beat <= cpu_beat;
                    last_v    <= 1'b1;
                end

                // -- MP3 serve (from its own line) --
                if (s_rd_req && hitM && !s_rdy_r) begin
                    s_dat_r <= mp3_shft[15:0];
                    s_rdy_r <= 1'b1;
                end

                // -- posted write: push (never stalls) --
                if (b4_wr_adv) begin
                    if (wf_cnt == 11'd1024) begin
                        ovf <= 1'b1;   // fail LOUD, never silent
                        // synthesis translate_off
                        $fatal(1, "k573dio: posted-write FIFO overflow");
                        // synthesis translate_on
                    end else begin
                        if (ram_adr[24:1] >= RING_GUARD_BASE[24:1] &&
                            ram_adr[24:1] <  (RING_GUARD_BASE[24:1] + RING_GUARD_SIZE[24:1]))
                            hiwr <= 1'b1;
                        wfifo[wf_wp] <= {ram_adr[24:1], din};
                        wf_wp  <= wf_wp + 10'd1;
                        wf_cnt <= wf_cnt + 11'd1;
                    end
                    // coherency: writes invalidate every cached line; an
                    // in-flight fill is poisoned (its data may predate this write)
                    lineA_v <= 1'b0; lineB_v <= 1'b0; lineM_v <= 1'b0;
                    last_v  <= 1'b0;
                    if (est == E_RD || est == E_RD_END) poison <= 1'b1;
                end

                // -- scheduler --
                case (est)
                    E_IDLE: begin
                        poison <= 1'b0;
                        if (wf_cnt != 11'd0) begin
                            // drain-before-read keeps the lines coherent
                            {mem_wr_addr, mem_wr_data} <= wfifo[wf_rp];
                            wf_rp  <= wf_rp + 10'd1;
                            // a same-cycle ACCEPTED push already added its +1;
                            // a dropped (overflow) push must not be re-added
                            wf_cnt <= wf_cnt - 11'd1 + (push_ok ? 11'd1 : 11'd0);
                            est    <= E_WR;
                        end else if (b4r && !cpu_ok && !b4_wr_adv) begin
                            mem_rd_addr <= cpu_beat;
                            rd_who      <= W_CPU;
                            est         <= E_RD;
                        end else if (s_rd_req && !hitM && !b4_wr_adv) begin
                            mem_rd_addr <= mp3_beat;
                            rd_who      <= W_MP3;
                            est         <= E_RD;
                        end else if (last_v && !pf_cached && !b4_wr_adv) begin
                            mem_rd_addr <= pf_beat;
                            rd_who      <= W_PF;
                            est         <= E_RD;
                        end
                    end
                    E_WR: begin
                        mem_wr_req <= 1'b1;
                        if (mem_wr_req && mem_wr_ack) begin
                            mem_wr_req <= 1'b0;
                            est        <= E_WR_END;
                        end
                    end
                    E_WR_END: if (!mem_wr_ack) est <= E_IDLE;
                    E_RD: begin
                        mem_rd_req <= 1'b1;
                        if (mem_rd_req && mem_rd_ack) begin
                            mem_rd_req <= 1'b0;
                            // validate the fill unless a write poisoned it
                            // (b4_wr_adv covers a push in this very cycle)
                            if (!poison && !b4_wr_adv) begin
                                if (rd_who == W_MP3) begin
                                    lineM_d <= mem_rd_q;
                                    lineM_t <= mem_rd_addr;
                                    lineM_v <= 1'b1;
                                end else if (fill_into_B) begin
                                    lineB_d <= mem_rd_q;
                                    lineB_t <= mem_rd_addr;
                                    lineB_v <= 1'b1;
                                end else begin
                                    lineA_d <= mem_rd_q;
                                    lineA_t <= mem_rd_addr;
                                    lineA_v <= 1'b1;
                                end
                            end
                            est <= E_RD_END;
                        end
                    end
                    E_RD_END: if (!mem_rd_ack) est <= E_IDLE;
                    default: est <= E_IDLE;
                endcase
            end
        end

    end endgenerate

    // fan a lamp register's high nibble out to four lamp lines (remap {0,2,3,1})
    task set_lamp(input [2:0] offs, input [15:0] d);
        begin
            lamp[{offs,2'd0}]        <= d[12];          // 4*offs + 0  <- bit 0
            lamp[{offs,2'd0} + 3'd1] <= d[14];          // 4*offs + 1  <- bit 2
            lamp[{offs,2'd0} + 3'd2] <= d[15];          // 4*offs + 2  <- bit 3
            lamp[{offs,2'd0} + 3'd3] <= d[13];          // 4*offs + 3  <- bit 1
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            lamp <= 32'd0; crypto_key1 <= 16'd0; crypto_key2 <= 16'd0;
            crypto_key3 <= 16'd0; mp3_start <= 32'd0; mp3_end <= 32'd0;
            fpga_ctrl <= 16'd0; network_id <= 16'd0;
            ram_adr <= 25'd0; ram_read_adr <= 25'd0; ow_master_low <= 1'b0;
            mas_scl <= 1'b1; mas_sda <= 1'b1;
        end else begin
            if (sel && we) begin
                case (off)
                    8'h90: network_id      <= din;
                    8'ha0: mp3_start[31:16] <= din;
                    8'ha2: mp3_start[15:0]  <= din;
                    8'ha4: mp3_end[31:16]   <= din;
                    8'ha6: mp3_end[15:0]    <= din;
                    8'ha8: crypto_key1      <= din;
`ifndef DIO_I2C_STUB
                    8'hac: begin mas_scl <= din[13]; mas_sda <= din[12]; end
`endif
                    8'hae: fpga_ctrl        <= din;
                    8'hb0: ram_adr          <= {din[8:0], ram_adr[15:0]};
                    8'hb2: ram_adr          <= {ram_adr[24:16], din};
                    8'hb6: ram_read_adr     <= {din[8:0], ram_read_adr[15:0]};
                    8'hb8: ram_read_adr     <= {ram_read_adr[24:16], din};
                    8'he0: set_lamp(3'd1, din);
                    8'he2: set_lamp(3'd0, din);
                    8'he4: set_lamp(3'd3, din);
                    8'he6: set_lamp(3'd7, din);
                    8'hea: crypto_key2      <= din;
                    8'hec: crypto_key3      <= din;
                    8'hee: ow_master_low    <= din[12];
                    8'hfa: set_lamp(3'd4, din);
                    8'hfc: set_lamp(3'd5, din);
                    8'hfe: set_lamp(3'd2, din);
                    default: ; // 0x10, 0xcc, 0xf8, network: stub/unhandled
                endcase
            end
            // b4 data movement lives in the backing generate blocks; the
            // pointers advance here (write: always; read: on completion --
            // patch 0006 holds the read strobe through a stall, so the
            // external backing qualifies the advance with its hit)
            if (b4_wr_adv) ram_adr      <= ram_adr      + 25'd2;
            if (b4_rd_adv) ram_read_adr <= ram_read_adr + 25'd2;
        end
    end

    // read mux (combinational)
    always @(*) begin
        case (off)
            8'h02:   dout = 16'h0001;
            8'h80:   dout = 16'h1234;        // board id
            8'ha0:   dout = mp3_start[31:16];
            8'ha2:   dout = mp3_start[15:0];
            8'ha4:   dout = mp3_end[31:16];
            8'ha6:   dout = mp3_end[15:0];
`ifndef MP3_COUNTER_STUB
            8'ha8:   dout = mp3_frame_counter[15:0];   // get_mp3_frame_count
            8'haa:   dout = mpeg_status;               // get_mpeg_ctrl
`endif
`ifndef DIO_I2C_STUB
            8'hac:   dout = {2'b00, mas_scl, mas_sda & ~mas_sda_pd, 12'b0};
`endif
            8'hae:   dout = fpga_ctrl_rb;    // get_fpga_ctrl: streaming status (bit 12)
            8'hb4:   dout = b4_rdata;
`ifndef MP3_COUNTER_STUB
            8'hca:   dout = fpga_counter_lat[31:16];    // mp3_counter_high_r (latched)
            8'hcc:   dout = mp3_sample_counter[15:0];   // mp3_counter_low_r (latches on read)
            8'hce:   dout = mp3_sample_counter[15:0] - mp3_diff_ref[15:0]; // mp3_counter_diff_r
`endif
            8'hee:   dout = {3'b000, ow_line, 12'b0};
            8'hf6:   dout = 16'hB000;        // FPGA status (0x8000|0x2000|0x1000)
            default: dout = 16'h0000;        // 0x00/04/06/0a + FPGA/MAS/net stubs
        endcase
    end
endmodule
