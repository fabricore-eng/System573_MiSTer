// -----------------------------------------------------------------------------
// s573_nvram_saver.v - M48T58 byte-array image -> WIDE(1) ioctl UPLOAD packer
//
// The save-back inverse of s573_nvram_loader.v. emu.sv instantiates hps_io with
// .WIDE(1), so an ioctl image UPLOAD (Main_MiSTer arcade_nvm_save -> the .mra
// <nvram index="3"> tag -> config/nvram/<mra>.nvm) consumes a FULL 16-bit word
// per FIO_FILE_TX_DAT strobe: hps_io latches fp_dout <= ioctl_din AT the strobe
// (while ioctl_addr still points at the word being read) and THEN advances
// ioctl_addr by 2 (sys/hps_io.sv:686-699). So the core's contract is simply:
// continuously present ioctl_din = {byte[ioctl_addr+1], byte[ioctl_addr]} -- the
// exact WIDE pairing whose download-side neglect was the red-N odd-byte bug.
//
// There is NO back-pressure on upload (Main's spi_read never looks at
// ioctl_wait), so the word must be ready within one HPS SPI word period
// (>= ~10-20 clk cycles; realistically far more -- see
// docs/audits/2026-06-11-nvram-saveback-gate0.md fact 2.5).
//
// The m48t58 save read port shares the ram[] WRITE port's idle cycles and has
// 1-cycle latency; sav_rd_ok=1 in the data cycle iff the read wasn't displaced
// by a bus/loader write. This FSM therefore FREE-RUNS a 4-cycle fetch loop while
// save_en is high: read even byte, read odd byte, and commit {odd, even} into
// the presented word ONLY when both reads were clean AND the word base still
// matches ioctl_addr (a strobe advancing the address mid-fetch just discards
// the pair; the loop refetches the new base well inside the inter-strobe gap).
// The commit is atomic, so hps_io can sample ioctl_din on ANY cycle and never
// sees a torn half-old/half-new word.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_nvram_saver (
    input  wire        clk,
    input  wire        save_en,      // ioctl_upload && ioctl_index==3
    input  wire [12:0] ioctl_addr,   // upload byte address (steps by 2, WIDE)
    output wire [15:0] ioctl_din,    // word presented to hps_io: {odd, even}
    // m48t58 save read port (1-cycle registered read, write-priority shared)
    output reg  [12:0] sav_addr,
    input  wire [7:0]  sav_dout,
    input  wire        sav_rd_ok
);
    localparam [1:0] S_A0 = 2'd0,   // present even address
                     S_A1 = 2'd1,   // present odd address (even read in flight)
                     S_C0 = 2'd2,   // capture even byte   (odd read in flight)
                     S_C1 = 2'd3;   // capture odd byte + commit

    reg [1:0]  state = S_A0;
    reg [12:0] base_inflight;        // word base this fetch belongs to
    reg [7:0]  lo_tmp;
    reg        lo_ok;
    reg [15:0] word;                 // committed word (atomic update)

    wire [12:0] cur_base = {ioctl_addr[12:1], 1'b0};

    always @(posedge clk) begin
        if (!save_en) begin
            state <= S_A0;           // idle / between uploads; word holds last value
        end else begin
            case (state)
                S_A0: begin
                    sav_addr      <= cur_base;
                    base_inflight <= cur_base;
                    state         <= S_A1;
                end
                S_A1: begin
                    sav_addr <= {base_inflight[12:1], 1'b1};
                    state    <= S_C0;
                end
                S_C0: begin
                    lo_tmp <= sav_dout;      // even byte (read issued in S_A1 cycle)
                    lo_ok  <= sav_rd_ok;
                    state  <= S_C1;
                end
                S_C1: begin
                    // odd byte on sav_dout now; commit only a coherent, current pair
                    if (lo_ok && sav_rd_ok && (base_inflight == cur_base))
                        word <= {sav_dout, lo_tmp};
                    state <= S_A0;           // free-run: refetch continuously
                end
            endcase
        end
    end

    assign ioctl_din = word;
endmodule
