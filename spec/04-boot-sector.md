# 04 — Floppy boot sector and kernel-file requirements

Describes what the Human68k v3.02 2HD floppy boot sector does, so that (a) the
reimplemented kernel file is loadable by the existing boot sector, and (b) a new
boot sector can be written later.

## 1. Environment [public]
- The X68000 IPL ROM reads the first sector (1024 bytes) of the boot floppy to
  `$002000` and jumps to `$002000` in supervisor mode. IOCS (trap #15) is ready.
- Byte 0 of the sector is a `bra` over the BPB. The BPB at offset 0x0B is the
  standard little-endian MS-DOS layout (see 20-filesystem.md); the 2HD disk
  uses 1024-byte sectors, 8 sectors/track, 2 heads, 77 cylinders, 1232 sectors,
  1 reserved sector, 2 FATs of 2 sectors, 192 root entries, media byte `$FE`.

## 2. Behaviour [verified]
1. Sets SSP to `$002000` (stack grows down below the boot sector).
2. Prints nothing on success. Determines the boot drive with IOCS `_BOOTINF`
   ($8E) and forms the floppy unit/mode word `$70uu`.
3. Reads **one sector** (1024 bytes) of the root directory using IOCS
   `_B_READ` ($46) into a buffer just past the boot sector, at a fixed
   physical position (track/side/sector value encoded in the sector's
   parameter block: for the standard 2HD layout this is the first root
   directory sector, logical sector 5).
4. Scans the **first 32 directory entries** of that sector for the 11-byte
   name `HUMAN   SYS`. Comparison is case-insensitive for letters (the entry's
   bytes are OR'ed with `$20` before comparing against the lower-case pattern),
   so the extra name bytes at entry +$0C are ignored.
5. Takes the start cluster from the entry (little-endian word at +$1A), adds
   the number of the first data sector minus 2 clusters' worth, and converts
   the logical sector to cylinder/head/sector for the 8-sector, 2-head geometry.
6. Reads the first sector of the file to the buffer and checks:
   - bytes 0–1 = `HU` (X-file magic), else error message 3;
   - long at offset 4 (base address) = `$00006800`, else error message 4.
7. Reads **`$40 + text + data` bytes in a single contiguous `_B_READ`**
   starting at the file's first sector, to address `$0067C0`. The 64-byte
   header therefore lands at `$67C0–$67FF` and the image at `$6800`.
   **The file must be stored in consecutive sectors** (no fragmentation);
   the FAT is never consulted.
8. Clears `bss` bytes immediately after text+data.
9. Jumps to the entry address from header offset 8. No relocation table is
   processed: the kernel must be linked absolutely for `$6800`.

On any failure it prints one of four Shift-JIS messages at the bottom of the
screen (no HUMAN.SYS / read error / not an X-file / wrong base), then ejects the
disk (IOCS `_B_EJECT` $4F) and returns to the ROM (IOCS $FE path), which retries
booting.

## 3. Requirements on a replacement kernel file
| Requirement | Value |
|---|---|
| File name | `HUMAN.SYS`, within the first 32 entries of the root directory |
| Placement | Contiguous clusters |
| Format | X-file header (64 bytes), magic `HU`, base `$00006800` |
| Linking | Absolute at `$6800`; relocation table ignored (may be empty) |
| Entry | Any address, from header offset 8 |
| BSS | Zeroed by the boot sector (size from header offset `$14`) |
| Size | header+text+data must fit below the top of the region the ROM leaves free; the original is ~58 KB |

## 4. Hard-disk boot [public]
SASI/SCSI hard-disk boot uses a different loader (partition IPL) not covered
here; the same kernel-file requirements are assumed. See QUESTIONS.md.
