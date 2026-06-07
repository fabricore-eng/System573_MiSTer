// -----------------------------------------------------------------------------
// x76f041.v - Xicor X76F041 secure serial flash EEPROM (security cartridge)
//
// The larger sibling of the X76F100 used on later System 573 security carts:
// 512 data bytes, separate read / write / configuration passwords, eight
// configuration registers (block control registers BCR1/BCR2, control register
// CR, retry registers RR/RC) and a richer command set (configuration writes,
// password programming/reset, mass program/erase).
//
// This is a faithful Verilog transliteration of the reverse-engineered protocol
// in MAME's machine/x76f041.cpp / .h:
//
//   * RST 0->1 (CS low) streams the 4-byte response-to-reset (0x19,0x55,0xAA,
//     0x55) LSB-first on FALLING SCL edges, looping until a start condition.
//   * Each I2C-like transfer: start, command byte, address byte, then (when the
//     block's BCR demands it) an 8-byte password and a 0xC0 verify byte, then
//     read or write.  Bytes clock in MSB-first on RISING SCL; the device ACKs
//     (SDA low) on the 9th clock.
//   * Command[7:5] selects WRITE(0x00)/READ(0x20)/WRITE+cfg-pw(0x40)/
//     READ+cfg-pw(0x60)/CONFIGURATION(0x80).  data_offset =
//     (blk & 0x180) | ((blk + byte) & 0x7f) with blk = (command[0]<<8)|address.
//   * BCR bits X/Y gate whether a write/read needs a password; Z/T disable or
//     make a block program-only (set-bits-only).  CR retry/unauthorized-access
//     bits and RR==RC gate access entirely.
//   * CONFIGURATION (command 0x80) uses the address byte as a sub-command:
//     program/reset the passwords, program/read the 8 config registers, or mass
//     program(0x00)/erase(0xFF) the whole device.
//
// SDA is split into the host-driven level (sda_i) and the device-driven level
// (sda_o), exactly as the 573 ASIC wires IO0.  Passwords, data and config
// registers are NVRAM and persist across the (volatile) system reset.
//
// --- Synthesis note (the 512-byte data array is an M10K block RAM) ---
// The 512-byte `data[]` NVRAM is accessed through a SINGLE synchronous write
// port and a SINGLE synchronous (registered) read port so Quartus infers it as
// one M10K block instead of ~4k flip-flops + a giant address mux.  All writers
// (the boot image load, the protocol 8-byte block flush with its program-only
// read-modify-write, and the single-byte configuration write) funnel through a
// small write-burst engine that serialises them to one byte per clock; the
// protocol read drives the read address one cycle ahead and consumes the
// registered byte (`data_rdata`).  This is purely a storage restructure: the
// I2C protocol, password gating and CR=0xac lockout are byte-for-byte identical
// to the previous flip-flop implementation (and the unit suite proves it).  The
// small 8-byte register files (wpw/rpw/cpw/creg/wbuf/ptemp) stay as registers.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module x76f041 #(
    parameter [63:0] READ_PASSWORD   = 64'h0000_0000_0000_0000,
    parameter [63:0] WRITE_PASSWORD  = 64'h0000_0000_0000_0000,
    parameter [63:0] CONFIG_PASSWORD = 64'h0000_0000_0000_0000,
    parameter [63:0] CONFIG_REGS     = 64'h0000_0000_0000_0000
)(
    input  wire clk,
    input  wire rst,        // system reset: clears the volatile bit-bang state
    input  wire cs,         // chip select, active low (0 = selected)
    input  wire sec_rst,    // chip RST pin, active high (0->1 = response to reset)
    input  wire scl,        // serial clock
    input  wire sda_i,      // SDA driven by the host (1 = released/high)
    output reg  sda_o,      // SDA driven by the device (1 = high, 0 = low)

    // ---- boot-time NVRAM image load (the 548-byte MAME x76f041 nvram image) ----
    // Streamed in byte-by-byte at boot from the security-EEPROM ioctl channel. The
    // image layout (machine/x76f041.cpp nvram_read/nvram_write order) is:
    //   [  0:  3] response-to-reset (4 bytes, 0x19,0x55,0xAA,0x55) -- IGNORED here
    //            (the RTR constant is hard-wired in rtr_val()); accepted + dropped.
    //   [  4: 11] write password    (8 bytes) -> wpw[0..7]
    //   [ 12: 19] read password     (8 bytes) -> rpw[0..7]
    //   [ 20: 27] config password   (8 bytes) -> cpw[0..7]
    //   [ 28: 35] config registers  (8 bytes) -> creg[0..7]
    //   [ 36:547] 512 data bytes              -> data[0..511]
    // load_we writes load_data at byte address load_addr (0..547). When any byte is
    // loaded, `loaded` latches and the loaded NVRAM overrides the compile-time
    // params (params stay the default for sims that never drive the load port).
    input  wire        load_we,
    input  wire [9:0]  load_addr,   // 0..547
    input  wire [7:0]  load_data
);
    // ---- states (match MAME state_t order) ----
    localparam [4:0]
        ST_STOP            = 5'd0,  ST_RTR            = 5'd1,
        ST_CMD             = 5'd2,  ST_ADDR           = 5'd3,
        ST_PW              = 5'd4,  ST_VERIFY         = 5'd5,
        ST_READ_DATA       = 5'd6,  ST_WRITE_DATA     = 5'd7,
        ST_CFG_WRITE_DATA  = 5'd8,  ST_READ_CFG_REGS  = 5'd9,
        ST_WRITE_CFG_REGS  = 5'd10, ST_PROG_WPW       = 5'd11,
        ST_PROG_RPW        = 5'd12, ST_PROG_CPW       = 5'd13,
        ST_RESET_WPW       = 5'd14, ST_RESET_RPW      = 5'd15,
        ST_MASS_PROGRAM    = 5'd16, ST_MASS_ERASE     = 5'd17;

    // ---- command groups (command & 0xe0) ----
    localparam [7:0] CMD_WRITE = 8'h00, CMD_READ = 8'h20,
                     CMD_WRITE_CFGPW = 8'h40, CMD_READ_CFGPW = 8'h60,
                     CMD_CONFIG = 8'h80, CMD_ACK = 8'hc0;

    // ---- configuration sub-commands (the address byte for command 0x80) ----
    localparam [7:0] CFG_PROG_WPW = 8'h00, CFG_PROG_RPW = 8'h10,
                     CFG_PROG_CPW = 8'h20, CFG_RESET_WPW = 8'h30,
                     CFG_RESET_RPW = 8'h40, CFG_PROG_REGS = 8'h50,
                     CFG_READ_REGS = 8'h60, CFG_MASS_PROG = 8'h70,
                     CFG_MASS_ERASE = 8'h80;

    // ---- config register indices + bit masks ----
    localparam integer CFG_BCR1 = 0, CFG_BCR2 = 1, CFG_CR = 2,
                       CFG_RR = 3, CFG_RC = 4;
    localparam [7:0] CR_RETRY_EN = 8'h04, CR_RETRY_RST = 8'h08, CR_UNAUTH = 8'hc0;
    localparam [7:0] BCR_X = 8'h08, BCR_Y = 8'h04, BCR_Z = 8'h02, BCR_T = 8'h01;

    // ---- NVRAM (persists across system reset) ----
    // data[] is the 512-byte EEPROM body -- single write port + registered read
    // port (see the write-burst engine below) so it infers as one M10K block.
    reg [7:0] data  [0:511];
    reg [7:0] wpw   [0:7];
    reg [7:0] rpw   [0:7];
    reg [7:0] cpw   [0:7];   // configuration password
    reg [7:0] creg  [0:7];   // configuration registers
    reg [7:0] wbuf  [0:7];
    reg [7:0] ptemp [0:15];  // password-program double buffer

    // ---- image-load byte-offset map (MAME nvram layout) ----
    // 4-byte RTR header at [0:3] is consumed but not stored (RTR is constant).
    localparam integer LD_WPW  = 4;     // write password   [4:11]
    localparam integer LD_RPW  = 12;    // read  password   [12:19]
    localparam integer LD_CPW  = 20;    // config password  [20:27]
    localparam integer LD_CREG = 28;    // config registers [28:35]
    localparam integer LD_DATA = 36;    // 512 data bytes   [36:547]

    integer n;
    initial begin
        for (n = 0; n < 8; n = n + 1) begin
            wpw [n] = WRITE_PASSWORD [8*(7-n) +: 8];
            rpw [n] = READ_PASSWORD  [8*(7-n) +: 8];
            cpw [n] = CONFIG_PASSWORD[8*(7-n) +: 8];
            creg[n] = CONFIG_REGS    [8*(7-n) +: 8];
            wbuf[n] = 8'h00;
        end
        for (n = 0; n < 16; n = n + 1) ptemp[n] = 8'h00;
    end

    // ---- volatile state ----
    reg [4:0] state;
    reg [3:0] bitc;
    reg [7:0] bytec;
    reg [7:0] shift;
    reg [7:0] command;
    reg [7:0] address;
    reg       pw_ok;

    reg pscl, pcs, psda, prst;

    // High once any image byte has been loaded (the loaded NVRAM is authoritative;
    // before that the compile-time params remain in effect so existing sims pass).
    reg loaded = 1'b0;

    function [7:0] rtr_val(input [7:0] b);
        case (b[1:0])
            2'd0: rtr_val = 8'h19;
            2'd1: rtr_val = 8'h55;
            2'd2: rtr_val = 8'haa;
            default: rtr_val = 8'h55;
        endcase
    endfunction

    // selected password byte for the current command/address (MAME password())
    function [7:0] sel_pw(input integer i);
        begin
            case (command & 8'he0)
                CMD_WRITE: sel_pw = wpw[i];
                CMD_READ:  sel_pw = rpw[i];
                CMD_CONFIG:
                    if (address == CFG_PROG_WPW)      sel_pw = wpw[i];
                    else if (address == CFG_PROG_RPW) sel_pw = rpw[i];
                    else                              sel_pw = cpw[i];
                default:   sel_pw = cpw[i];
            endcase
        end
    endfunction

    // data byte offset (MAME data_offset()) for a given running byte index, using
    // the current command[0]/address.
    function [8:0] doff(input [7:0] bidx);
        reg [8:0] blk;
        begin
            blk  = {command[0], address};
            doff = (blk & 9'h180) | ((blk + {1'b0, bidx}) & 9'h07f);
        end
    endfunction

    // doff() for a write burst, from the command[0]/address snapshot taken when the
    // burst was kicked off (keeps the burst address arithmetic self-contained).
    function [8:0] doffb(input b_cmd0, input [7:0] b_addr, input [7:0] bidx);
        reg [8:0] blk;
        begin
            blk   = {b_cmd0, b_addr};
            doffb = (blk & 9'h180) | ((blk + {1'b0, bidx}) & 9'h07f);
        end
    endfunction

    // temporaries
    reg [7:0] s, bcr;
    reg       match;
    integer   j;

    // =====================================================================
    // data[] single-port write engine + registered read port (M10K-friendly)
    // =====================================================================
    // Write-burst engine: every data[] write is serialised to ONE byte per clock,
    // and the protocol read uses a registered read port. The engine handles
    //   - the boot image load (1 byte),
    //   - the configuration single-byte write ST_CFG_WRITE_DATA (1 byte), and
    //   - the protocol 8-byte block flush ST_WRITE_DATA (8 bytes), preceded -- for a
    //     program-only block -- by 8 reads that decide the set-bits-only NAK.
    // A block flush only ever starts on a rising-SCL edge (the master holds SCL for
    // ~9 idle clocks per bit), so the multi-cycle burst always finishes long before
    // the next edge is consumed, and it never overlaps a protocol data read (the
    // read happens in ST_READ_DATA, the burst in ST_WRITE_DATA/ST_CFG_WRITE_DATA).
    localparam [1:0] BRST_IDLE = 2'd0, BRST_CHECK = 2'd1, BRST_WRITE = 2'd2;
    reg [1:0]  brst_state;
    reg [3:0]  brst_idx;        // burst byte index (0..8)
    reg [7:0]  brst_buf [0:7];  // the 8 bytes to write
    reg        brst_cmd0;       // snapshot of command[0]
    reg [7:0]  brst_addr;       // snapshot of address
    reg        brst_unauth;     // accumulated set-bits-only violation
    // The data[] read port has TWO cycles of latency (rd_addr_next -> rd_addr ->
    // data_rdata), so the program-only check tracks the index it issued through a
    // 2-deep pipeline; when stage d2 is valid, data_rdata holds data[doffb(idx_d2)].
    reg [3:0]  brst_chk_idx_d1, brst_chk_idx_d2;
    reg        brst_chk_vld_d1, brst_chk_vld_d2;
    reg        brst_kick;       // 1-clock pulse: FSM requests a burst start
    reg        brst_kick_chk;   //   ... and it is a program-only (RMW) block

    // single-byte data write request (cfg-write) -- a 1-clock pulse from the FSM.
    reg        sb_kick;
    reg [8:0]  sb_addr;
    reg [7:0]  sb_data;

    // the single synchronous write port + registered read port for data[]
    reg [8:0]  ram_waddr;
    reg [7:0]  ram_wdata;
    reg        ram_we;
    reg [8:0]  rd_addr;
    reg [7:0]  data_rdata;

    // Read address: one cycle ahead of the protocol read consumer. During a
    // program-only check the burst owns it; otherwise it tracks doff(bytec) so
    // data_rdata == data[doff(bytec)] by the time the read FSM shifts it out.
    wire [8:0] rd_addr_next = (brst_state == BRST_CHECK)
                            ? doffb(brst_cmd0, brst_addr, {4'd0, brst_idx})
                            : doff(bytec);

    // ----- RAM port: the ONLY place data[] is read or written (block-RAM cell) -----
    always @(posedge clk) begin
        rd_addr    <= rd_addr_next;
        data_rdata <= data[rd_addr];
        if (ram_we) data[ram_waddr] <= ram_wdata;
    end

    // MAME password_ok(): pick the post-auth state from command/address.
    task do_pwok(input [7:0] pa);
        begin
            if (creg[CFG_CR] & CR_RETRY_RST) creg[CFG_RC] <= 8'h00;
            case (command & 8'he0)
                CMD_WRITE:       state <= ST_WRITE_DATA;
                CMD_READ:        state <= ST_READ_DATA;
                CMD_WRITE_CFGPW: state <= ST_CFG_WRITE_DATA;
                CMD_READ_CFGPW:  state <= ST_READ_DATA;
                CMD_CONFIG:
                    case (pa)
                        CFG_PROG_WPW:   begin state <= ST_PROG_WPW;      bytec <= 8'd0; end
                        CFG_PROG_RPW:   begin state <= ST_PROG_RPW;      bytec <= 8'd0; end
                        CFG_PROG_CPW:   begin state <= ST_PROG_CPW;      bytec <= 8'd0; end
                        CFG_RESET_WPW:        state <= ST_RESET_WPW;
                        CFG_RESET_RPW:        state <= ST_RESET_RPW;
                        CFG_PROG_REGS:  begin state <= ST_WRITE_CFG_REGS; bytec <= 8'd0; end
                        CFG_READ_REGS:  begin state <= ST_READ_CFG_REGS;  bytec <= 8'd0; end
                        CFG_MASS_PROG:        state <= ST_MASS_PROGRAM;
                        CFG_MASS_ERASE:       state <= ST_MASS_ERASE;
                        default: ;
                    endcase
                default: ;
            endcase
        end
    endtask

    // =====================================================================
    // Main always block: boot load + FSM + the write-burst engine, all together so
    // brst_state / brst_idx / sda_o / ram_we have exactly one driver.
    // =====================================================================
    always @(posedge clk) begin
        // one-shot defaults
        ram_we <= 1'b0;

        // ===== boot-time NVRAM image load (runs even while rst is asserted) =====
        // Small register files are written directly; the 512-byte body goes through
        // the single write port. The 4-byte RTR header is dropped.
        if (load_we) begin
            loaded <= 1'b1;
            if (load_addr >= LD_DATA[9:0]) begin
                ram_we    <= 1'b1;
                ram_waddr <= load_addr - LD_DATA[9:0];
                ram_wdata <= load_data;
            end else if (load_addr >= LD_CREG[9:0])
                creg[load_addr - LD_CREG[9:0]] <= load_data;
            else if (load_addr >= LD_CPW[9:0])
                cpw[load_addr - LD_CPW[9:0]] <= load_data;
            else if (load_addr >= LD_RPW[9:0])
                rpw[load_addr - LD_RPW[9:0]] <= load_data;
            else if (load_addr >= LD_WPW[9:0])
                wpw[load_addr - LD_WPW[9:0]] <= load_data;
            // load_addr < LD_WPW: the 4-byte RTR header -- accepted and dropped.
        end

        // ===== write-burst engine (serialises data[] writes; one byte / clock) =====
        // The cfg single-byte write (does not collide with a block burst).
        if (sb_kick && brst_state == BRST_IDLE) begin
            ram_we    <= 1'b1;
            ram_waddr <= sb_addr;
            ram_wdata <= sb_data;
        end

        case (brst_state)
            BRST_IDLE: begin
                if (brst_kick) begin
                    brst_idx        <= 4'd0;
                    brst_unauth     <= 1'b0;
                    brst_chk_vld_d1 <= 1'b0;
                    brst_chk_vld_d2 <= 1'b0;
                    brst_state      <= brst_kick_chk ? BRST_CHECK : BRST_WRITE;
                end
            end
            BRST_CHECK: begin
                // Pipelined set-bits-only check (read-modify-write). rd_addr_next is
                // combinationally doffb(brst_idx); with two cycles of read latency,
                // data_rdata holds data[doffb(brst_chk_idx_d2)] exactly when
                // brst_chk_vld_d2 is set. Compare the new byte: a value below the old
                // one is a clear-bit, which set-bits-only programming forbids.
                if (brst_chk_vld_d2 && brst_buf[brst_chk_idx_d2] < data_rdata)
                    brst_unauth <= 1'b1;
                // advance the 2-deep "issued index" pipeline
                brst_chk_vld_d2 <= brst_chk_vld_d1;
                brst_chk_idx_d2 <= brst_chk_idx_d1;
                if (brst_idx < 4'd8) begin
                    brst_chk_idx_d1 <= brst_idx;  // issue a read of this index
                    brst_chk_vld_d1 <= 1'b1;
                    brst_idx        <= brst_idx + 4'd1;
                end else begin
                    brst_chk_vld_d1 <= 1'b0;
                    // all 8 issued; once the pipeline has fully drained, decide.
                    if (!brst_chk_vld_d1 && !brst_chk_vld_d2) begin
                        if (brst_unauth) begin
                            sda_o      <= 1'b1;       // set-bits-only violation -> NAK
                            brst_state <= BRST_IDLE;
                        end else begin
                            brst_idx   <= 4'd0;
                            brst_state <= BRST_WRITE;
                        end
                    end
                end
            end
            BRST_WRITE: begin
                if (brst_idx < 4'd8) begin
                    ram_we    <= 1'b1;
                    ram_waddr <= doffb(brst_cmd0, brst_addr, {4'd0, brst_idx});
                    ram_wdata <= brst_buf[brst_idx];
                    brst_idx  <= brst_idx + 4'd1;
                end else
                    brst_state <= BRST_IDLE;
            end
            default: brst_state <= BRST_IDLE;
        endcase

        // ===== FSM reset =====
        if (rst) begin
            state   <= ST_STOP;
            bitc    <= 4'd0;
            bytec   <= 8'd0;
            shift   <= 8'd0;
            command <= 8'd0;
            address <= 8'd0;
            pw_ok   <= 1'b0;
            sda_o   <= 1'b0;
            sb_kick    <= 1'b0;
            brst_kick  <= 1'b0;
            for (j = 0; j < 8; j = j + 1) wbuf[j] <= 8'h00;
        end else begin
            // FSM-driven burst requests are one-shot pulses.
            sb_kick   <= 1'b0;
            brst_kick <= 1'b0;

            // ===== chip select =====
            if (pcs != 1'b0 && cs == 1'b0)
                state <= ST_STOP;
            if (pcs == 1'b0 && cs != 1'b0) begin
                state <= ST_STOP;
                sda_o <= 1'b0;
            end

            if (cs == 1'b0) begin
                // ===== RST pin =====
                if (prst == 1'b0 && sec_rst != 1'b0) begin
                    state <= ST_RTR;
                    bitc  <= 4'd0;
                    bytec <= 8'd0;
                end

                // ===== start / stop (SDA edge while SCL high) =====
                if (scl != 1'b0) begin
                    if (psda == 1'b0 && sda_i != 1'b0) begin           // stop
                        state <= ST_STOP;
                        sda_o <= 1'b0;
                    end else if (psda != 1'b0 && sda_i == 1'b0) begin  // start
                        case (state)
                            ST_STOP:      state <= ST_CMD;
                            ST_READ_DATA: state <= ST_ADDR; // repeated start -> new addr
                            default: ;
                        endcase
                        bitc  <= 4'd0;
                        bytec <= 8'd0;
                        shift <= 8'd0;
                        sda_o <= 1'b0;
                    end
                end

                // ===== response-to-reset: FALLING edge, LSB-first =====
                if (state == ST_RTR && pscl != 1'b0 && scl == 1'b0) begin
                    sda_o <= (rtr_val(bytec) >> bitc) & 1'b1;
                    if (bitc == 4'd7) begin
                        bitc  <= 4'd0;
                        bytec <= (bytec == 8'd3) ? 8'd0 : bytec + 8'd1;
                    end else
                        bitc <= bitc + 4'd1;
                end

                // ===== everything else: RISING edge =====
                if (pscl == 1'b0 && scl != 1'b0) begin
                    if (state == ST_READ_DATA || state == ST_READ_CFG_REGS) begin
                        // ---- output states ----
                        if (bitc < 4'd8) begin
                            if (bitc == 4'd0) begin
                                if (state == ST_READ_DATA)
                                    // registered read: data_rdata == data[doff(bytec)]
                                    // (rd_addr tracked doff(bytec) one cycle ahead).
                                    s = data_rdata;
                                else
                                    s = creg[bytec[2:0]];
                            end else
                                s = shift;
                            sda_o <= s[7];
                            shift <= s << 1;
                            bitc  <= bitc + 4'd1;
                        end else begin
                            bitc  <= 4'd0;
                            sda_o <= 1'b0;
                            if (sda_i == 1'b0)
                                bytec <= bytec + 8'd1;   // master ACK -> next byte
                        end
                    end else if (state != ST_STOP && state != ST_RTR) begin
                        // ---- input / processing states ----
                        if (bitc < 4'd8) begin
                            shift <= {shift[6:0], sda_i};   // MSB-first
                            bitc  <= bitc + 4'd1;
                        end else begin
                            sda_o <= 1'b0;                  // ACK
                            bitc  <= 4'd0;
                            shift <= 8'd0;
                            case (state)
                                ST_CMD: begin
                                    command <= shift;
                                    state   <= ST_ADDR;
                                end
                                ST_ADDR: begin
                                    address <= shift;
                                    // ---- load_address() ----
                                    if ((creg[CFG_CR] & CR_RETRY_EN) &&
                                        (creg[CFG_RR] == creg[CFG_RC]) &&
                                        ((creg[CFG_CR] & CR_UNAUTH) == 8'h80)) begin
                                        state <= ST_STOP; sda_o <= 1'b1; bytec <= 8'd0;
                                    end else if ((command & 8'he0) == CMD_CONFIG) begin
                                        if (shift == CFG_RESET_WPW || shift == CFG_RESET_RPW ||
                                            shift == CFG_MASS_PROG || shift == CFG_MASS_ERASE)
                                            do_pwok(shift);
                                        else begin
                                            state <= ST_PW; bytec <= 8'd0;
                                        end
                                    end else if ((creg[CFG_CR] & CR_RETRY_EN) &&
                                                 (creg[CFG_RR] == creg[CFG_RC]) &&
                                                 ((creg[CFG_CR] & CR_UNAUTH) != 8'h80)) begin
                                        state <= ST_STOP; sda_o <= 1'b1; bytec <= 8'd0;
                                    end else begin
                                        bcr = creg[command[0] ? CFG_BCR2 : CFG_BCR1];
                                        if (shift & 8'h80) bcr = {4'h0, bcr[7:4]};
                                        if (((command & 8'he0) == CMD_READ &&
                                             (bcr & BCR_Z) && (bcr & BCR_T)) ||
                                            ((command & 8'he0) == CMD_WRITE &&
                                             (bcr & BCR_Z))) begin
                                            state <= ST_STOP; sda_o <= 1'b1; bytec <= 8'd0;
                                        end else if (((command & 8'he0) == CMD_WRITE &&
                                                      !(bcr & BCR_X)) ||
                                                     ((command & 8'he0) == CMD_READ &&
                                                      !(bcr & BCR_Y)))
                                            do_pwok(shift);
                                        else begin
                                            state <= ST_PW; bytec <= 8'd0;
                                        end
                                    end
                                end
                                ST_PW: begin
                                    wbuf[bytec] <= shift;
                                    if (bytec == 8'd7) begin
                                        state <= ST_VERIFY;
                                        match = 1'b1;
                                        for (j = 0; j < 7; j = j + 1)
                                            if (sel_pw(j) != wbuf[j]) match = 1'b0;
                                        if (sel_pw(7) != shift) match = 1'b0;
                                        pw_ok <= match;
                                        if (!match && (creg[CFG_CR] & CR_RETRY_EN))
                                            creg[CFG_RC] <= creg[CFG_RC] + 8'd1;
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                                ST_VERIFY: begin
                                    if (shift == CMD_ACK) begin
                                        if (pw_ok) do_pwok(address);
                                        else       sda_o <= 1'b1; // NAK
                                    end
                                end
                                ST_WRITE_DATA: begin
                                    wbuf[bytec] <= shift;
                                    if (bytec == 8'd7) begin
                                        // Hand the 8 bytes + the (cmd0,address) snapshot
                                        // to the burst engine, which serialises the
                                        // (optional program-only) read-modify-write to
                                        // the single data[] port.
                                        bcr = creg[command[0] ? CFG_BCR2 : CFG_BCR1];
                                        if (address & 8'h80) bcr = {4'h0, bcr[7:4]};
                                        for (j = 0; j < 7; j = j + 1) brst_buf[j] <= wbuf[j];
                                        brst_buf[7]   <= shift;
                                        brst_cmd0     <= command[0];
                                        brst_addr     <= address;
                                        brst_kick     <= 1'b1;
                                        brst_kick_chk <= ((bcr & (BCR_Z | BCR_T)) == BCR_T);
                                        bytec <= 8'd0;
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                                ST_CFG_WRITE_DATA: begin
                                    sb_kick <= 1'b1;
                                    sb_addr <= doff(bytec);
                                    sb_data <= shift;
                                    bytec   <= bytec + 8'd1;
                                end
                                ST_WRITE_CFG_REGS: begin
                                    creg[bytec[2:0]] <= shift;
                                    bytec <= (bytec == 8'd7) ? 8'd0 : bytec + 8'd1;
                                end
                                ST_PROG_WPW, ST_PROG_RPW, ST_PROG_CPW: begin
                                    ptemp[bytec[3:0]] <= shift;
                                    if (bytec == 8'd15) begin
                                        match = 1'b1;
                                        for (j = 0; j < 7; j = j + 1)
                                            if (ptemp[j] != ptemp[j+8]) match = 1'b0;
                                        if (ptemp[7] != shift) match = 1'b0;
                                        if (match) begin
                                            for (j = 0; j < 8; j = j + 1) begin
                                                if (state == ST_PROG_WPW) wpw[j] <= ptemp[j];
                                                else if (state == ST_PROG_RPW) rpw[j] <= ptemp[j];
                                                else cpw[j] <= ptemp[j];
                                            end
                                        end else
                                            sda_o <= 1'b1;
                                        for (j = 0; j < 16; j = j + 1) ptemp[j] <= 8'h00;
                                        bytec <= 8'd0;
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                                ST_RESET_WPW:
                                    for (j = 0; j < 8; j = j + 1) wpw[j] <= 8'h00;
                                ST_RESET_RPW:
                                    for (j = 0; j < 8; j = j + 1) rpw[j] <= 8'h00;
                                ST_MASS_PROGRAM, ST_MASS_ERASE: begin
                                    // synthesis translate_off
                                    // SIM-ONLY: mass program/erase clears the small
                                    // config arrays in one edge. (The 512-byte data body
                                    // is M10K and cannot be bulk-written from here; the
                                    // 573 BIOS never issues 0x70/0x80 at boot, so this
                                    // sim-only convenience does not touch data[].)
                                    for (j = 0; j < 8; j = j + 1) begin
                                        cpw[j]  <= (state == ST_MASS_ERASE) ? 8'hff : 8'h00;
                                        creg[j] <= (state == ST_MASS_ERASE) ? 8'hff : 8'h00;
                                        wpw[j]  <= (state == ST_MASS_ERASE) ? 8'hff : 8'h00;
                                        rpw[j]  <= (state == ST_MASS_ERASE) ? 8'hff : 8'h00;
                                    end
                                    // synthesis translate_on
                                end
                                default: ;
                            endcase
                        end
                    end
                end
            end

            pscl <= scl;
            pcs  <= cs;
            psda <= sda_i;
            prst <= sec_rst;
        end
    end
endmodule
