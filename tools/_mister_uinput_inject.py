#!/usr/bin/env python3
# Runs ON the MiSTer (32-bit ARM). Injects a key chord via /dev/uinput so the
# MiSTer main treats it as a real keypress -- used to trigger a savestate
# (Alt+F1) headlessly. Args: keycodes to press together (decimal), e.g. 56 59.
# Linux input keycodes: KEY_LEFTALT=56, KEY_F1=59 .. KEY_F4=62.
import os, fcntl, struct, time, sys

UI_SET_EVBIT  = 0x40045564   # _IOW('U',100,int)
UI_SET_KEYBIT = 0x40045565   # _IOW('U',101,int)
UI_DEV_CREATE = 0x5501       # _IO('U',1)
UI_DEV_DESTROY= 0x5502       # _IO('U',2)
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0

keys = [int(a) for a in sys.argv[1:]] or [56, 59]   # default Alt+F1

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in keys:
    fcntl.ioctl(fd, UI_SET_KEYBIT, k)
# struct uinput_user_dev: char name[80]; input_id(4*u16); u32 ff_effects_max;
# s32 absmax/absmin/absfuzz/absflat[64] each  (= 256 ints). Native 32-bit layout.
dev = struct.pack('80sHHHHI256i', b'mister-ss-inject', 0x03, 0x1234, 0x5678, 1, 0, *([0] * 256))
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(0.8)   # let the MiSTer main hotplug-detect the new device

def ev(t, c, v):
    # input_event (32-bit): timeval(2*long=8) + type(u16)+code(u16)+value(s32)=16B
    os.write(fd, struct.pack('llHHi', 0, 0, t, c, v))

for k in keys:                       # press in order (modifier first)
    ev(EV_KEY, k, 1); ev(EV_SYN, SYN_REPORT, 0); time.sleep(0.04)
time.sleep(0.10)
for k in reversed(keys):             # release in reverse
    ev(EV_KEY, k, 0); ev(EV_SYN, SYN_REPORT, 0); time.sleep(0.02)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
print("injected keys: " + " ".join(str(k) for k in keys))
