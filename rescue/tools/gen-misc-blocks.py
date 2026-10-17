#!/usr/bin/env python3
"""gen-misc-blocks.py — 7552N Phase 2: derive the two 32-byte bootloader_control blocks.

Input: a full 1MiB misc partition dump (rescue/dumps/misc.bin, pulled via adb pull).
Live 7552N state (verified): suffix=_a, slot A=0xff (prio15 tries7 succ1), B=0x0f
(prio15 tries0 succ0). NOTE: these differ from the F50 values (0x9f/0x1e) hardcoded
in boot/build-boot-image.py — never copy the author's bytes.

Outputs (written next to this script's cwd or given dir):
  misc-bc-slot-a.bin       restore block = live misc verbatim (CRC already valid)
  misc-bc-slot-b-trial.bin one-shot trial: suffix=_b, A prio 15->14 (0xff->0xfe),
                           B = prio15 tries2 succ0 (0x2f); LK decrements tries to 1
                           and boots b; a failed boot rolls back to a.

Slot info byte layout (confirmed from rootfs overlay changxing60-next-boot):
  bit0-3 priority | bit4-6 tries_remaining | bit7 successful_boot
"""
import struct
import sys
import zlib

MISC = sys.argv[1] if len(sys.argv) > 1 else 'misc.bin'
OUTDIR = sys.argv[2] if len(sys.argv) > 2 else '.'

bc = bytearray(open(MISC, 'rb').read()[0x800:0x820])
assert len(bc) == 32
assert bc[4:8] == b'BCAB', 'no bootloader_control magic at 0x800'
assert zlib.crc32(bytes(bc[:28])) == struct.unpack('<I', bc[28:])[0], 'live CRC invalid'
assert bc[0:2] == b'_a' and bc[12] == 0xff and bc[14] == 0x0f, (
    f'unexpected live state: suffix={bc[0:2]!r} A={bc[12]:#x} B={bc[14]:#x} — '
    're-dump misc and re-derive before trusting these blocks')

slot_a = bytes(bc)  # restore block = live verbatim

t = bytearray(bc)
t[0:4] = b'_b\0\0'
t[12] = (bc[12] & 0xf0) | ((bc[12] & 0x0f) - 1)   # A: prio 15 -> 14, tries/succ kept => 0xfe
t[14] = 0x2f                                      # B: prio15 tries2 succ0
assert t[12] == 0xfe and t[14] == 0x2f
t[28:32] = struct.pack('<I', zlib.crc32(bytes(t[:28])))

open(f'{OUTDIR}/misc-bc-slot-a.bin', 'wb').write(slot_a)
open(f'{OUTDIR}/misc-bc-slot-b-trial.bin', 'wb').write(bytes(t))
print('slot_a (restore) :', slot_a.hex())
print('slot_b (trial)   :', bytes(t).hex())
print(f'wrote {OUTDIR}/misc-bc-slot-a.bin, {OUTDIR}/misc-bc-slot-b-trial.bin')
