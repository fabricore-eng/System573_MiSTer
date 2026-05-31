`timescale 1ns/1ps
// Testbench for s573_bus.v - exercises the EXP1 address decoder.
module tb_s573_bus;
    reg  [23:0] addr;
    reg         access = 1;
    wire sel_flash, sel_asic, sel_ide0, sel_ide1, sel_bankctl, sel_jvsclr;
    wire sel_idereset, sel_wdog, sel_digout, sel_rtc, sel_digio;
    wire sel_jvsdata, sel_seclatch;
    wire [3:0]  asic_off;
    wire [13:0] rtc_off;
    integer errors = 0;

    s573_bus dut (
        .addr(addr), .access(access),
        .sel_flash(sel_flash), .sel_asic(sel_asic), .sel_ide0(sel_ide0),
        .sel_ide1(sel_ide1), .sel_bankctl(sel_bankctl), .sel_jvsclr(sel_jvsclr),
        .sel_idereset(sel_idereset), .sel_wdog(sel_wdog), .sel_digout(sel_digout),
        .sel_rtc(sel_rtc), .sel_digio(sel_digio), .sel_jvsdata(sel_jvsdata),
        .sel_seclatch(sel_seclatch), .asic_off(asic_off), .rtc_off(rtc_off)
    );

    // One-hot bus of all selects for easy comparison.
    wire [12:0] sel = {sel_seclatch, sel_jvsdata, sel_digio, sel_rtc, sel_digout,
                       sel_wdog, sel_idereset, sel_jvsclr, sel_bankctl,
                       sel_ide1, sel_ide0, sel_asic, sel_flash};

    task chk(input [23:0] a, input [12:0] onehot, input [127:0] name);
        begin
            addr = a; #1;
            if (sel !== onehot) begin
                $display("FAIL: %0s addr=%06h sel=%013b expected=%013b",
                         name, a, sel, onehot);
                errors = errors + 1;
            end
        end
    endtask

    // bit positions in `sel`
    localparam FLASH=13'b0000000000001, ASIC=13'b0000000000010,
               IDE0 =13'b0000000000100, IDE1=13'b0000000001000,
               BANK =13'b0000000010000, JCLR=13'b0000000100000,
               IRST =13'b0000001000000, WDOG=13'b0000010000000,
               DOUT =13'b0000100000000, RTC =13'b0001000000000,
               DIGIO=13'b0010000000000, JDAT=13'b0100000000000,
               SECL =13'b1000000000000;

    initial begin
        chk(24'h000000, FLASH, "flash lo");
        chk(24'h3fffff, FLASH, "flash hi");
        chk(24'h400004, ASIC,  "asic");
        chk(24'h480000, IDE0,  "ide0");
        chk(24'h4c0000, IDE1,  "ide1");
        chk(24'h500000, BANK,  "bankctl");
        chk(24'h520000, JCLR,  "jvsclr");
        chk(24'h560000, IRST,  "idereset");
        chk(24'h5c0000, WDOG,  "wdog");
        chk(24'h600000, DOUT,  "digout");
        chk(24'h623ff0, RTC,   "rtc");
        chk(24'h640080, DIGIO, "digio");
        chk(24'h680000, JDAT,  "jvsdata");
        chk(24'h6a0000, SECL,  "seclatch");

        // sub-offsets
        addr = 24'h400006; #1;
        if (asic_off !== 4'h6) begin
            $display("FAIL: asic_off=%h expected 6", asic_off); errors = errors + 1;
        end
        addr = 24'h623ff0; #1;             // 0x3ff0 >> 1 = 0x1ff8 = 8184
        if (rtc_off !== 14'd8184) begin
            $display("FAIL: rtc_off=%0d expected 8184", rtc_off); errors = errors + 1;
        end

        // access low => no selects
        access = 0; addr = 24'h400004; #1;
        if (sel !== 13'd0) begin
            $display("FAIL: selects active with access=0"); errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (s573_bus)");
        else             $display("RESULT: FAIL (s573_bus, %0d errors)", errors);
        $finish;
    end
endmodule
