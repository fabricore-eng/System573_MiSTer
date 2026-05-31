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
    output reg  sda_o       // SDA driven by the device (1 = high, 0 = low)
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
    reg [7:0] data  [0:511];
    reg [7:0] wpw   [0:7];
    reg [7:0] rpw   [0:7];
    reg [7:0] cpw   [0:7];   // configuration password
    reg [7:0] creg  [0:7];   // configuration registers
    reg [7:0] wbuf  [0:7];
    reg [7:0] ptemp [0:15];  // password-program double buffer

    integer n;
    initial begin
        for (n = 0; n < 8; n = n + 1) begin
            wpw [n] = WRITE_PASSWORD [8*(7-n) +: 8];
            rpw [n] = READ_PASSWORD  [8*(7-n) +: 8];
            cpw [n] = CONFIG_PASSWORD[8*(7-n) +: 8];
            creg[n] = CONFIG_REGS    [8*(7-n) +: 8];
            wbuf[n] = 8'h00;
        end
        for (n = 0; n < 16;  n = n + 1) ptemp[n] = 8'h00;
        for (n = 0; n < 512; n = n + 1) data[n] = n[7:0];
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

    // data byte offset (MAME data_offset()) for a given running byte index
    function [8:0] doff(input [7:0] bidx);
        reg [8:0] blk;
        begin
            blk  = {command[0], address};
            doff = (blk & 9'h180) | ((blk + {1'b0, bidx}) & 9'h07f);
        end
    endfunction

    // temporaries
    reg [7:0] s, bcr, nb;
    reg [8:0] o;
    reg       match, unauth;
    integer   j;

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

    always @(posedge clk) begin
        if (rst) begin
            state   <= ST_STOP;
            bitc    <= 4'd0;
            bytec   <= 8'd0;
            shift   <= 8'd0;
            command <= 8'd0;
            address <= 8'd0;
            pw_ok   <= 1'b0;
            sda_o   <= 1'b0;
            for (j = 0; j < 8; j = j + 1) wbuf[j] <= 8'h00;
        end else begin
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
                                if (state == ST_READ_DATA) begin
                                    o = doff(bytec);
                                    s = data[o];
                                end else
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
                                        bcr = creg[command[0] ? CFG_BCR2 : CFG_BCR1];
                                        if (address & 8'h80) bcr = {4'h0, bcr[7:4]};
                                        if ((bcr & (BCR_Z | BCR_T)) == BCR_T) begin
                                            // program-only: bits may be set, not cleared
                                            unauth = 1'b0;
                                            for (j = 0; j < 8; j = j + 1) begin
                                                nb = (j == 7) ? shift : wbuf[j];
                                                if (nb < data[doff(j[7:0])]) unauth = 1'b1;
                                            end
                                            if (unauth) sda_o <= 1'b1;
                                            else for (j = 0; j < 8; j = j + 1)
                                                data[doff(j[7:0])] <= (j == 7) ? shift : wbuf[j];
                                        end else
                                            for (j = 0; j < 8; j = j + 1)
                                                data[doff(j[7:0])] <= (j == 7) ? shift : wbuf[j];
                                        bytec <= 8'd0;
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                                ST_CFG_WRITE_DATA: begin
                                    data[doff(bytec)] <= shift;
                                    bytec <= bytec + 8'd1;
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
                                    nb = (state == ST_MASS_ERASE) ? 8'hff : 8'h00;
                                    for (j = 0; j < 512; j = j + 1) data[j] <= nb;
                                    for (j = 0; j < 8;   j = j + 1) begin
                                        cpw[j]  <= nb; creg[j] <= nb;
                                        wpw[j]  <= nb; rpw[j]  <= nb;
                                    end
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
