#!/usr/bin/env python3
# =============================================================================
# mister_press.py -- HEADLESS button press on a MiSTer board via /dev/uinput.
#
# Runs ON the MiSTer (Buildroot Linux armv7l, python3.9, stdlib only).
# Creates a virtual gamepad with the legacy uinput API (uinput_user_dev),
# waits for MiSTer Main to enumerate it, presses ONE button, releases,
# lingers, then destroys the device.
#
# Usage (on the board):
#   python3 /tmp/mister_press.py test            # press Test (BTN_TR)
#   python3 /tmp/mister_press.py service         # BTN_TL
#   python3 /tmp/mister_press.py coin            # BTN_SELECT
#   python3 /tmp/mister_press.py start           # BTN_START
#   python3 /tmp/mister_press.py b1|b2|b3|b4     # Y/B/A/X face buttons
#   python3 /tmp/mister_press.py 0x137           # raw BTN_ code
# Options:
#   --hold MS    press duration in ms        (default 150)
#   --pre  SEC   wait after create, before press -- MiSTer enumeration
#                time (default 6.0)
#   --post SEC   wait after release, before destroy (default 1.5)
#   --name NAME  uinput device name (default "MiSTer-573 VirtualPad")
#
# 573 MRA map: names="Button 1,Button 2,Button 3,Button 4,Coin,Start,
# Service,Test" default="Y,B,A,X,Select,Start,L,R"
#   => Test=R shoulder=BTN_TR(0x137), Service=L=BTN_TL(0x136),
#      Coin=Select=BTN_SELECT(0x13a), Start=BTN_START(0x13b).
# =============================================================================
import argparse, fcntl, os, struct, sys, time

# ---- uinput ioctls (armv7, 32-bit) ----
UI_SET_EVBIT   = 0x40045564
UI_SET_KEYBIT  = 0x40045565
UI_SET_ABSBIT  = 0x40045567
UI_DEV_CREATE  = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
ABS_X, ABS_Y = 0x00, 0x01

BTN = {
    "b1":      0x134,  # BTN_WEST  (Y)
    "b2":      0x131,  # BTN_EAST  (B)
    "b3":      0x130,  # BTN_SOUTH (A)
    "b4":      0x133,  # BTN_NORTH (X)
    "coin":    0x13a,  # BTN_SELECT
    "start":   0x13b,  # BTN_START
    "service": 0x136,  # BTN_TL  (L shoulder)
    "test":    0x137,  # BTN_TR  (R shoulder)
}

def emit(fd, etype, code, value):
    # struct input_event (armv7): timeval(2 x u32) + u16 type + u16 code + s32 value = 16B
    os.write(fd, struct.pack("<2IHHi", 0, 0, etype, code, value))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("button", help="test|service|coin|start|b1..b4 or raw code like 0x137")
    ap.add_argument("--hold", type=int, default=150, help="press duration ms")
    ap.add_argument("--pre",  type=float, default=6.0, help="enumeration wait s")
    ap.add_argument("--post", type=float, default=1.5, help="post-release wait s")
    ap.add_argument("--name", default="MiSTer-573 VirtualPad")
    args = ap.parse_args()

    key = args.button.lower()
    code = BTN.get(key, None)
    if code is None:
        code = int(args.button, 0)

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
        # full gamepad button range BTN_SOUTH..BTN_START (0x130-0x13b)
        for k in range(0x130, 0x13c):
            fcntl.ioctl(fd, UI_SET_KEYBIT, k)
        fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_X)
        fcntl.ioctl(fd, UI_SET_ABSBIT, ABS_Y)

        # legacy struct uinput_user_dev = name[80] + input_id(4 x u16) +
        # ff_effects_max(u32) + absmax/absmin/absfuzz/absflat[64] s32 = 1116B
        absmax  = [0] * 64
        absmin  = [0] * 64
        absfuzz = [0] * 64
        absflat = [0] * 64
        absmax[ABS_X] = 255; absmax[ABS_Y] = 255
        setup = struct.pack("<80s4HI", args.name.encode(), 0x03, 0x16c0, 0x05e1, 1, 0)
        setup += struct.pack("<64i", *absmax)
        setup += struct.pack("<64i", *absmin)
        setup += struct.pack("<64i", *absfuzz)
        setup += struct.pack("<64i", *absflat)
        assert len(setup) == 1116, len(setup)
        os.write(fd, setup)
        fcntl.ioctl(fd, UI_DEV_CREATE)
        print("created uinput pad '%s'; waiting %.1fs for MiSTer to enumerate..."
              % (args.name, args.pre))
        time.sleep(0.5)
        # initial centered axes so the pad looks alive
        emit(fd, EV_ABS, ABS_X, 128)
        emit(fd, EV_ABS, ABS_Y, 128)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(max(args.pre - 0.5, 0))

        print("press 0x%03x (%s) for %dms" % (code, key, args.hold))
        emit(fd, EV_KEY, code, 1)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(args.hold / 1000.0)
        emit(fd, EV_KEY, code, 0)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(args.post)
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        print("done")
    finally:
        os.close(fd)

if __name__ == "__main__":
    main()
