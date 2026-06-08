#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ss_to_mame.py -- extract the pieces of a 573 savestate needed to re-render its
# EXACT frame inside MAME (the trusted oracle): main RAM, VRAM, and the CPU
# architectural registers. Outputs are fed to mame_inject.lua, which writes them
# into a running MAME hyperbbc and steps a few frames so MAME's correct GPU
# re-renders our captured frame -- a direct, image-match-free comparison.
#
# Savestate layout (verified vs psx/rtl: cpu.vhd, savestates.vhd):
#   savetype 0  (CPU,  DWORD 1024): idx0=PC, 1=hi, 2=lo, 3=BPC,4=BDA,5=JUMPDEST,
#       6=DCIC,7=BADVADDR,8=BDAM,9=BPCM,10=SR,11=CAUSE,12=EPC,13=PRID,
#       idx 96..127 = GPR r0..r31  (cpu.vhd:2803 ss_regs_addr = SS_Adr-96)
#   savetype 15 (VRAM, DWORD 262144 = byte 0x100000): 1 MiB, 1024x512 RGB555 LE
#   savetype 16 (RAM,  DWORD 524288 = byte 0x200000): 2 MiB PSX main RAM
#
# Usage:  ss_to_mame.py STATE.ss OUTPREFIX
#   writes OUTPREFIX_ram.bin (2 MiB), OUTPREFIX_vram.bin (1 MiB),
#          OUTPREFIX_regs.lua (a lua table the injector dofile()s)
# ---------------------------------------------------------------------------
import struct, sys, os

VRAM_OFF, VRAM_LEN = 0x100000, 0x100000
RAM_OFF,  RAM_LEN  = 0x200000, 0x200000
CPU_DW = 1024   # savetype 0 base (DWORD)

# MAME maincpu GPR state names in MIPS r0..r31 order (from the live device).
GPR = ["zero","at","v0","v1","a0","a1","a2","a3","t0","t1","t2","t3","t4","t5",
       "t6","t7","s0","s1","s2","s3","s4","s5","s6","s7","t8","t9","k0","k1",
       "gp","sp","fp","ra"]

def dw(buf, i):
    return struct.unpack_from("<I", buf, i * 4)[0]

def main(argv):
    if len(argv) != 2:
        print("usage: ss_to_mame.py STATE.ss OUTPREFIX", file=sys.stderr); return 2
    path, pfx = argv
    with open(path, "rb") as f:
        ss = f.read()
    if len(ss) < 0x400000:
        print("error: .ss too small", file=sys.stderr); return 1

    with open(pfx + "_ram.bin", "wb") as f:
        f.write(ss[RAM_OFF:RAM_OFF + RAM_LEN])
    with open(pfx + "_vram.bin", "wb") as f:
        f.write(ss[VRAM_OFF:VRAM_OFF + VRAM_LEN])

    pc = dw(ss, CPU_DW + 0); hi = dw(ss, CPU_DW + 1); lo = dw(ss, CPU_DW + 2)
    cop0 = dict(BPC=dw(ss,CPU_DW+3), BDA=dw(ss,CPU_DW+4), DCIC=dw(ss,CPU_DW+6),
                BadA=dw(ss,CPU_DW+7), BDAM=dw(ss,CPU_DW+8), BPCM=dw(ss,CPU_DW+9),
                SR=dw(ss,CPU_DW+10), Cause=dw(ss,CPU_DW+11), EPC=dw(ss,CPU_DW+12),
                PRId=dw(ss,CPU_DW+13))
    gprs = [dw(ss, CPU_DW + 96 + i) for i in range(32)]

    # binary regs (avoid lua dofile/sandbox issues): 45 LE u32 in a FIXED order
    #   [0]pc [1]hi [2]lo [3]SR [4]Cause [5]EPC [6]BPC [7]BDA [8]DCIC [9]BadA
    #   [10]BDAM [11]BPCM [12]PRId [13..44]=GPR r0..r31
    order = [pc, hi, lo, cop0["SR"], cop0["Cause"], cop0["EPC"], cop0["BPC"],
             cop0["BDA"], cop0["DCIC"], cop0["BadA"], cop0["BDAM"], cop0["BPCM"],
             cop0["PRId"]] + gprs
    with open(pfx + "_regs.bin", "wb") as f:
        f.write(struct.pack("<%dI" % len(order), *order))

    print(f"PC=0x{pc:08x}  SR=0x{cop0['SR']:08x}  sp=0x{gprs[29]:08x}  ra=0x{gprs[31]:08x}")
    print(f"wrote {pfx}_ram.bin (2MiB), {pfx}_vram.bin (1MiB), {pfx}_regs.lua")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
