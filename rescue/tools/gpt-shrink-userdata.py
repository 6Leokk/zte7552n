#!/usr/bin/env python3
"""gpt-shrink-userdata.py — 7552N Phase 3: shrink userdata, free the tail for changxing60root.

Rewrites BOTH GPT copies (primary 34-LBA head dump, backup 34-LBA tail dump) of the
UFS LUN0 disk (/dev/block/sda). LBA size is 4096 (verified by parsing the dumps:
MyLBA=1 header at byte 4096, AltLBA=31240191, entries LBA 2..5 / 31240187..31240190).

Only the userdata entry (#75) end LBA changes; entries CRC and both header CRCs are
recomputed. Protective MBR, all other entries, FirstUsable/LastUsable stay untouched.

Usage:
  gpt-shrink-userdata.py gpt_main.bin gpt_backup.bin OUT_MAIN OUT_TAIL [NEW_GIB]

Then flash from Android root (see docs/changxing60/port-design.md S3.3):
  dd if=OUT_MAIN of=/dev/block/sda bs=4096 count=6  conv=notrunc   # MBR+hdr+entries
  dd if=OUT_TAIL of=/dev/block/sda bs=4096 seek=<tail_lba> conv=notrunc
(tail_lba = disk_LBAs - 34 = 31240158; OUT_TAIL keeps the full 34-LBA layout,
 only the last 5 LBAs differ from the original dump.)
"""
import struct
import sys
import zlib

LBA = 4096
USERDATA_IDX = 75          # verified by name match below anyway
DISK_LBAS = 31240192       # /sys/block/sda/size(512b)=249921536 -> /8
EXPECT_FIRST = 2230784
EXPECT_LAST = 31239679
NEW_GIB = float(sys.argv[5]) if len(sys.argv) > 5 else 64.0
NEW_SIZE_LBA = int(NEW_GIB * 2**30 // LBA)


def hdr_set_crc(h: bytearray) -> None:
    h[16:20] = b'\0' * 4
    struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:struct.unpack_from('<I', h, 8)[0]])))


def check_header(h: bytes, expect_my_lba: int) -> None:
    assert h[:8] == b'EFI PART', 'bad signature'
    hsize = struct.unpack_from('<I', h, 8)[0]
    x = bytearray(h[:hsize]); x[16:20] = b'\0' * 4
    assert zlib.crc32(bytes(x)) == struct.unpack_from('<I', h, 16)[0], 'header CRC invalid'
    assert struct.unpack_from('<Q', h, 24)[0] == expect_my_lba, 'unexpected MyLBA'


def find_userdata(arr: bytearray, n: int, sz: int):
    hits = []
    for i in range(n):
        o = i * sz
        if arr[o:o + 16] == b'\x00' * 16:
            continue
        name = arr[o + 56:o + 128].decode('utf-16-le', 'ignore').rstrip('\x00')
        if name == 'userdata':
            hits.append((i, o, name))
    assert len(hits) == 1, f'expected exactly one userdata entry, got {hits}'
    return hits[0]


def patch_copy(dump: bytearray, hdr_file_lba: int, ent_file_off: int, new_last: int):
    hoff = hdr_file_lba * LBA
    h = dump[hoff:hoff + 92]
    n, sz = struct.unpack_from('<II', h, 80)
    ent_crc_stored = struct.unpack_from('<I', h, 88)[0]
    arr = bytearray(dump[ent_file_off:ent_file_off + n * sz])
    assert zlib.crc32(bytes(arr)) == ent_crc_stored, 'entries CRC invalid in source dump'
    i, o, _ = find_userdata(arr, n, sz)
    first, last = struct.unpack_from('<QQ', arr, o + 32)
    assert (first, last) == (EXPECT_FIRST, EXPECT_LAST), f'unexpected userdata extent {first}..{last}'
    struct.pack_into('<Q', arr, o + 40, new_last)
    dump[ent_file_off:ent_file_off + len(arr)] = arr
    hh = bytearray(dump[hoff:hoff + 92])
    struct.pack_into('<I', hh, 88, zlib.crc32(bytes(arr)))
    hdr_set_crc(hh)
    dump[hoff:hoff + 92] = hh
    return i


def main():
    main_dump = bytearray(open(sys.argv[1], 'rb').read())
    tail_dump = bytearray(open(sys.argv[2], 'rb').read())
    assert len(main_dump) == 34 * LBA and len(tail_dump) == 34 * LBA, 'dumps must be 34 LBAs (bs=4096)'

    new_last = EXPECT_FIRST + NEW_SIZE_LBA - 1
    print(f'userdata: LBA {EXPECT_FIRST}..{EXPECT_LAST} -> {EXPECT_FIRST}..{new_last} '
          f'({NEW_SIZE_LBA * LBA / 2**30:.1f} GiB)')

    # primary: header at file LBA 1, entries at LBA 2 (verified: EntryLBA=2)
    check_header(bytes(main_dump[LBA:LBA + 92]), 1)
    ent_lba = struct.unpack_from('<Q', main_dump, LBA + 72)[0]
    assert ent_lba == 2
    i1 = patch_copy(main_dump, 1, ent_lba * LBA, new_last)

    # backup: header at file LBA 33 (MyLBA=31240191=disk end), entries at disk LBA 31240187
    # -> file LBA 33 - (31240191 - 31240187) = 29
    check_header(bytes(tail_dump[33 * LBA:33 * LBA + 92]), DISK_LBAS - 1)
    b_ent_lba = struct.unpack_from('<Q', tail_dump, 33 * LBA + 72)[0]
    assert b_ent_lba == DISK_LBAS - 5, f'unexpected backup EntryLBA {b_ent_lba}'
    file_ent_off = (33 - (DISK_LBAS - 1 - b_ent_lba)) * LBA
    i2 = patch_copy(tail_dump, 33, file_ent_off, new_last)
    assert i1 == i2 == USERDATA_IDX, f'userdata index mismatch: {i1}/{i2}'

    open(sys.argv[3], 'wb').write(bytes(main_dump))
    open(sys.argv[4], 'wb').write(bytes(tail_dump))

    # free-region summary for install env
    off_bytes = (new_last + 1 + 512) * LBA          # +2 MiB gap, matches design OFF
    # design S3.2: region ends at LBA 31239168 (byte 127955632128), keeping a >=4MiB
    # gap before the disk end / backup GPT; matches the OFF/SIZE used in install env.
    end_bytes = 31239168 * LBA
    print(f'OFF={off_bytes} SIZE={end_bytes - off_bytes} '
          f'(changxing60root region end LBA {(end_bytes // LBA) - 1}, LastUsable 31239679)')
    print('OK: wrote', sys.argv[3], sys.argv[4])


if __name__ == '__main__':
    main()
