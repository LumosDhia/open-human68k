# 20 — File system: drives, DPB, FAT, buffers, directories, path parsing

Scope: everything between a DOS call that names a file/directory and the
block-device driver. Handles, FCBs, sharing and the per-file calls are in
`21-file-io.md`. Driver header / request-packet layout in general is in
`03-device-drivers.md`; this file only lists which requests the file system
issues and how it interprets the replies. Error-code numbers are the usual
Human68k negative codes (see `01-dos-dispatch.md`); the ones used here are
repeated in §15.

Conventions: all DOS-call arguments are on the caller's stack as for every
Human68k DOS call (first argument at the lowest address); results come back
in `d0.l`. "Drive number" in an argument means 0 = current, 1 = A:, 2 = B: …
unless stated otherwise; "internal drive" means 0 = A:.

---

## 1. Architecture overview

The file system is layered:

| Layer | Role |
|-------|------|
| Path parser | turns a user string into a 88-byte "NAMESTS" record (§9). |
| Drive / current-directory layer | logical→physical drive mapping, current directory per drive, virtual drives and directories (§3, §4, §10). |
| Directory layer | walks paths, searches directory sectors, allocates entries (§8). |
| FAT layer | cluster chains, allocation, free count (§6). |
| Buffer cache | sector buffers with write-back (§7). |
| Device layer | builds request packets for block drivers; "remote" drives get whole-call requests instead (§12, §13). |

[verified] The FAT layer, the buffer cache, an (empty by default) directory
cache and the file-name syntax layer are each reached through a replaceable
table of entry points. `OS_PATCH` ($FFAB) swaps these tables (selector 1 =
buffer cache, 2 = FAT layer, 3 = directory cache, 4 = file-name syntax). Third
party add-ons (e.g. long-file-name patches) rely on this. The exact slot
layout of these tables is not specified here (see QUESTIONS.md); a compatible
kernel that does not support OS_PATCH module replacement must at least make
`OS_PATCH` return an error rather than crash.

---

## 2. System work-area variables (low memory)

These live in the DOS work area and some third-party tools read them
directly. Sizes in bytes. [verified] unless noted.

| Address | Size | Meaning |
|---------|------|---------|
| `$1C0C` | 2 | Retry count for critical errors (default 3; set by IOCTRL 11). |
| `$1C0E` | 2 | Retry wait (default 100; set by IOCTRL 11). |
| `$1C10` | 2 | VERIFY flag (0 = off). Non-zero → block writes use the "write with verify" command (§12). Default from the HUMAN.SYS header byte (0). |
| `$1C12` | 1 | BREAK mode (default 2). When it equals 1, file READ/WRITE poll for Ctrl-C after the transfer (see 30-char-io). |
| `$1C15` | 1 | Current drive, logical, 0 = A:. |
| `$1C2C` | 4 | Pointer to the handle-table extension (handles 6…FILES), or 0. |
| `$1C30` | 4 | Pointer to the FCB-table extension (FCBs 6…FILES), or 0. |
| `$1C38` | 4 | Pointer to the current-directory table (§4). |
| `$1C3C` | 4 | Pointer to the first internal DPB (chain, §5). |
| `$1C40` | 4 | Pointer to the sharing table, 0 if SHARE not configured (21-file-io §6). |
| `$1C6E` | 2 | FILES value (highest handle number). 5 before CONFIG is processed. |
| `$1C70` | 2 | Largest sector size accepted = size of one buffer's data area (default $400). |
| `$1C72` | 1 | Number of disk buffers (BUFFERS; 3 before CONFIG). |
| `$1C73` | 1 | Highest valid drive index (LASTDRIVE − 'A'). |
| `$1C74` | 1 | Configured LASTDRIVE index (default 25 = Z:). |
| `$1C75` | 1 | Number of physical block units − 1. |
| `$1C76` | 2 | Sharing: number of file entries. |
| `$1C78` | 2 | Sharing: lock slots per file entry. |
| `$1C7A` | 4 | Sharing: size of one file entry. |
| `$1C7E` | 26 | Drive translation table: byte *i* = physical drive used for logical drive *i* (initially identity). DRVXCHG swaps entries. |
| `$1CBA` | 1 | FFLUSH mode (default 1 = on). |

Other flags (directory-search hint "DIRSCH", default on; NEWFAT, default
from the HUMAN.SYS header) are kernel-internal (not at fixed low-memory
addresses). They are set by CONFIG.SYS (`02-config-sys.md`).

---

## 3. Drive numbering and translation

* Logical drive *L* (what users type) is converted to a physical drive
  *P* = table`[$1C7E + L]`. Every path, every drive argument and every DPB
  lookup goes through this. [verified]
* Reverse mapping (physical → logical) is a linear search of the same table
  for the first byte equal to *P* (returns −1 if absent). It is used whenever
  the kernel reports a drive back to the user (NAMESTS, NAMECK, FATCHK,
  GETDPB, ASSIGN get). [verified]
* A drive index greater than `$1C73` is never translated and is invalid.
* **DRVXCHG ($FF34)** — args: `w drive1, w drive2` (0 = current, 1 = A:).
  Swaps the two table bytes; returns 0, or −15 if either is out of range.
  Special case: if the first argument *long* is −1 (`$FFFFFFFF`), the table is
  reset to identity and the call returns the physical drive that the current
  drive was mapped to before the reset. [verified]

A logical drive is *usable* when its current-directory entry (§4) has type
`$40` or `$50`. Type 0 (no device) and `$60` (drive mounted into a
directory) are rejected with −15 by all calls that take a drive. Validating
a drive also performs a media check on its DPB (§11). [verified]

---

## 4. Current-directory table

`$1C38` points at an array of `LASTDRIVE+1` entries, one per **physical**
drive index, 78 (`$4E`) bytes each. [verified]

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 69 | Path string. Bytes 0–1 = drive letter and `:`. Then the absolute path using byte `$09` (TAB) as separator, NUL-terminated, no trailing separator except for the root (e.g. `A:` `$09` `DIR` `$09` `SUB` `$00`; root = `A:` `$09` `$00`). |
| `$45` | 1 | Type: `$00` no drive; `$40` normal drive; `$50` virtual drive (alias of a directory, "SUBST"); `$60` drive mounted on a directory of another drive ("JOIN"). |
| `$46` | 4 | Pointer to the internal DPB serving this entry (−1 if none). |
| `$4A` | 2 | First cluster of the current directory (0 = root). `$FFFF` = unknown, must be resolved by walking the path again. |
| `$4C` | 2 | Offset of the "root" of this drive inside the path string. 2 for a normal drive (points at the leading separator). For a `$50` entry it is the length of the host-directory prefix: the current directory path of the virtual drive starts there. |

Initialisation [verified]: every entry is `"X:" $09 $00` followed by zeros,
type 0, DPB pointer from the DPB chain in order, cluster `$FFFF`, offset 2;
entries for existing units then get type `$40`.

CURDIR returns the text starting one byte after offset `$4C`.

---

## 5. Drive Parameter Blocks

### 5.1 Internal DPB

One per block-device unit, linked in a chain starting at `$1C3C`. Built at
boot from the driver's BPB and rebuilt after a media change. [verified]
for every field listed; size is at least `$38` bytes.

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | Physical drive index (0 = A:). |
| `$01` | 1 | Unit number within the driver. |
| `$02` | 4 | Device-driver header pointer. |
| `$06` | 4 | Next DPB (−1 = end). |
| `$0A` | 2 | Bytes per sector. **0 marks a remote drive** (§13). |
| `$0C` | 1 | Sectors per cluster − 1 (mask). |
| `$0D` | 1 | bits 0–6: log2(sectors per cluster). bit 7: FAT16 byte order flag (§6.2). |
| `$0E` | 2 | First FAT sector (= reserved sectors). |
| `$10` | 1 | Number of FATs. |
| `$11` | 1 | Sectors per FAT. |
| `$12` | 2 | Root directory entries. |
| `$14` | 2 | First data sector (sector of cluster 2). |
| `$16` | 2 | Number of data clusters + 3 (i.e. highest cluster number + 2). |
| `$18` | 2 | First root-directory sector. |
| `$1A` | 1 | Media byte. |
| `$1B` | 1 | log2(bytes per sector). |
| `$1C` | 2 | Allocation rover: cluster where the next free-cluster search starts (2 after a rebuild, after an eject, or after "disk full"). |
| `$1E`–`$37` | | Directory-search hints (only used when DIRSCH is on; contents are an optimisation and need not be reproduced). |

### 5.2 BPB → DPB conversion

The BPB returned by a block driver (command 2, §12) has this layout
[verified]:

| Off | Size | Meaning |
|-----|------|---------|
| 0 | 2 | Bytes per sector |
| 2 | 1 | Sectors per cluster |
| 3 | 1 | bits 0–6 number of FATs; bit 7 = FAT16 little-endian flag |
| 4 | 2 | Reserved sectors (first FAT sector) |
| 6 | 2 | Root directory entries |
| 8 | 2 | Total sectors (0 → use the long at +12) |
| 10 | 1 | Media byte |
| 11 | 1 | Sectors per FAT |
| 12 | 4 | Total sectors (32-bit), only if +8 is 0 |

Derived values [verified]:

* bytes/sector must be ≤ `$1C70`, otherwise the BPB is rejected.
* `$1B` = number of low 1-bits of (bytes/sector − 1), i.e. log2 for a power
  of two. `$0D` bits 0–6 likewise from sectors/cluster. Non-powers of two
  are not detected.
* root sector `$18` = reserved + nFATs × sectorsPerFAT.
* data sector `$14` = `$18` + ⌈rootEntries × 32 / bytesPerSector⌉.
* `$16` = ((totalSectors − `$14`) >> log2(spc)) + 3; if this is ≥ `$FFF8` the
  BPB is rejected.
* `$1C` = 2, hints cleared.

A rejected BPB raises the critical-error handler with code 7 ("invalid
media") and the conversion is retried after the user's answer.

### 5.3 GETDPB ($FF32)

Args: `w drive` (0 = current), `l buffer` (94 bytes). [verified]

The drive must be a usable drive of type `$40` (a `$50` alias or invalid
drive → −15; in that case the word at buffer+2 is overwritten with
`$00, 'A'+physical drive`). Output (all big-endian):

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | Logical drive (0 = A:) |
| `$01` | 1 | Unit number |
| `$02` | 16 | Copy of internal DPB `$0A`–`$19` (bytes/sector, spc−1, shift, FAT sector, nFATs, sectors/FAT, root entries, data sector, clusters+3, root sector) |
| `$12` | 4 | Device-driver pointer |
| `$16` | 1 | Media byte |
| `$17` | 1 | `$FF` if the allocation rover equals 2, else 0 |
| `$18` | 4 | Pointer to next internal DPB (−1 at end) |
| `$1C` | 2 | Current-directory cluster of that drive (`$FFFF` if unresolved) |
| `$1E` | 64 | Current directory: `\` followed by the path, `\` separators, NUL-terminated |

Returns 0. For a remote drive, bytes 0–1, `$12` and `$18` come from the
local DPB, the remote driver fills from offset 2 (request `$52`), then `$16`
= `'a'` + physical drive, `$17` = 0, `$1C` = 0, `$1E` = path as above.

---

## 6. FAT rules

### 6.1 Cluster ↔ sector

sector(c) = `$14` + ((c − 2) << log2(spc)) for c ≥ 2; cluster 0 means
"the root directory" (sector `$18`, length `$14`−`$18` sectors). Valid
data clusters are 2 … `$16`−2. [verified]

### 6.2 FAT format selection

* **FAT12** when DPB `$16` < `$FF8`; otherwise **FAT16**. [verified]
* FAT12 entries: standard IBM packing (entry *n* at byte ⌊3n/2⌋, low
  nibble-first for even *n*), always little-endian. [verified]
* FAT16 entries: 16-bit word at byte 2n. **Byte order is big-endian unless
  bit 7 of the BPB "number of FATs" byte (DPB `$0D` bit 7) is set**, in which
  case little-endian (MS-DOS) order is used. [verified]
* Only the first FAT copy is ever read or written; additional FAT copies are
  never updated. [verified]

### 6.3 Entry values

| Value read | Meaning |
|------------|---------|
| 0 | free |
| FAT12 `$FFF`, FAT16 `$FFFF` | end of chain (reported internally as `$FFFF`) |
| anything else | next cluster (FAT12 `$FF8`–`$FFE` are **not** treated as end of chain) [verified] |

Following a chain into a free (0) entry is treated as a corrupted FAT: the
critical-error handler is invoked with code 5 ("management area destroyed")
and the operation cannot continue. [verified]

### 6.4 Allocation

* A new cluster is found by scanning upward from the rover (DPB `$1C`), or
  from cluster 2 when **NEWFAT** is set, wrapping from the last cluster to
  cluster 2, for the first entry equal to 0. [verified]
* The found cluster is immediately marked end-of-chain and becomes the new
  rover value (the rover points at the last allocated cluster, not after it).
* If the scan returns to its start: rover := 2, result −23 (disk full).
* Extending a chain = allocate, then write the new cluster number into the
  previous end entry.

### 6.5 Freeing / counting

* Freeing a chain zeroes every entry from the first cluster to the
  end-of-chain entry inclusive.
* Free count (DSKFRE) = number of entries equal to 0 among clusters
  2 … `$16`−2.

### 6.6 Truncation detail

Truncating a file (0-byte WRITE, 21-file-io) keeps the cluster that contains
the current position (or the first cluster when the position is 0), marks
it end-of-chain and frees the rest. A file therefore never loses its first
cluster through truncation. [verified]

---

## 7. Disk buffer cache

[verified] unless noted.

* `BUFFERS` (`$1C72`) buffers, each with a data area of `$1C70` bytes (the
  largest sector size), plus a 16-byte header. They form one most-recently-
  used list shared by all drives.
* Each buffer is tagged with (physical drive, sector number) and the owning
  DPB; it has a dirty bit and a use class (FAT, directory, file data). The
  class only affects whether the sector is pre-read: requests that will
  overwrite a whole sector (new directory cluster, full-sector data writes
  through the buffer) skip the read.
* Lookup moves the buffer to the head of the list. On a miss the least
  recently used buffer is taken; if it is dirty it is written first.
* **Write-back policy.** Data written through the cache stays dirty until:
  the buffer is evicted; the drive is flushed; FFLUSH (if FFLUSH mode on);
  Ctrl-C abort / process kill; a media change; DRVCTRL eject/flush.
  The following calls flush all dirty buffers of the affected drive before
  returning: CLOSE (any file), MKDIR, RMDIR, DELETE, RENAME, CHMOD (set),
  DRVCTRL 1/3/9. CREATE/NEWFILE and FILEDATE (set) only update the
  directory sector in the cache (dirty); it reaches the disk on the next
  flush (normally the CLOSE).
* **Direct transfers.** READ/WRITE move whole sectors straight between the
  user buffer and the driver (multi-sector requests). Before a direct read,
  dirty buffers inside the range are written; before a direct write, cached
  copies inside the range are discarded.
* **Eject interlock.** When a buffer of a drive goes from clean to dirty the
  kernel sends that drive a DRVCTRL request (command 5) with mode 6 ("OS
  eject inhibit"); after flushing it sends mode 7 ("OS eject allow"). [verified]
* **Verify.** With VERIFY on, every sector write uses command 9 (write with
  verify) instead of 8.
* Flush+invalidate of all buffers is also done by the internal "flush all"
  path used by FFLUSH and Ctrl-C.

**FFLUSH ($FF0D)** — no args. If FFLUSH mode (`$1CBA`) is non-zero: writes
every dirty buffer, invalidates all buffers, resets the console line-input
state, and sends request `$56` to every remote drive. Returns 0 always.
[verified]

**$FFAA (FFLUSH mode set/get)** — arg `w mode`: −1 = query only; otherwise
`$1CBA` := low byte. Returns the previous mode. [verified]

---

## 8. Directories

### 8.1 Directory entry (32 bytes, on disk, little-endian numbers)

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 8 | Name, space-padded. First byte `$00` = end of directory; `$E5` = deleted; `$05` stands for a real first byte `$E5` (Shift-JIS lead byte). |
| `$08` | 3 | Extension, space-padded. |
| `$0B` | 1 | Attribute: `$01` read-only, `$02` hidden, `$04` system, `$08` volume label, `$10` directory, `$20` archive. |
| `$0C` | 10 | **Human68k name extension ("name2")**: characters 9–18 of the name, NUL-padded. Zero when the name has ≤ 8 characters. (MS-DOS reserved area.) |
| `$16` | 2 | Time (MS-DOS format) |
| `$18` | 2 | Date (MS-DOS format) |
| `$1A` | 2 | First cluster (0 for an empty file created elsewhere, for the root in `..`) |
| `$1C` | 4 | File size |

### 8.2 Name matching rules [verified]

* Lookups (open, path components, delete, rename, FILES, sharing) compare
  **only name (8) + extension (3)**. `name2` is stored and displayed but never
  compared: `ABCDEFGHIJ.X` and `ABCDEFGHKL.X` are the same file.
* Comparison is case-insensitive for ASCII letters only. A pattern byte `?`
  matches any byte. If the pattern byte is a Shift-JIS lead byte
  (`$80`–`$9F`, `$E0`–`$FF`) the two-byte character must match exactly.
* Directory scanning stops at the first entry whose first byte is `$00`;
  `$E5` entries are skipped. Names are stored with the case the user typed
  (no upper-casing on create).
* Attribute filter (FILES): an entry matches if `(entryAttr OR-ed with $20
  when entryAttr is 0) AND mask` is non-zero. Internal lookups use mask
  `$FF`, so they find files, directories and volume labels alike.

### 8.3 Displayed name (FILES result, NAMECK)

Name bytes up to the first space; if all 8 are used, `name2` bytes follow up
to the first NUL or space; then, if the extension's first byte is not a
space, `.` and the extension without trailing spaces; NUL. A leading `$05`
is shown as `$E5`. [verified]

### 8.4 Path walking

The directory part of a NAMESTS path is resolved component by component
from the root, or from the drive's current directory when the current path
is a prefix of the requested one. Each component (≤ 22 bytes) is matched
like a file name; it must exist and have the directory attribute, otherwise
−3. The root has no `.`/`..` entries; `..` is resolved textually by the
parser (§9). [verified]

### 8.5 Creating entries

A new entry goes into the first slot whose first byte is `$00` or `$E5`
(searching from the directory start, or from a hint position when DIRSCH is
on [inferred: placement may differ from a plain first-fit only in rare
cases]). When a subdirectory is full a new cluster is allocated, linked,
and all its sectors are zero-filled. The root cannot grow: −24. If no
cluster can be allocated for a subdirectory: −24 (not −23). [verified]

New directory (MKDIR): one cluster, zero-filled, with entries `.` (cluster
= itself) and `..` (cluster = parent, 0 for the root), attribute `$10`, both
stamped with the current date/time. [verified]

---

## 9. Path and file-name parsing

### 9.1 Stage 1 — lexical clean-up [verified]

Input: NUL-terminated string.

1. Leading spaces are skipped.
2. Bytes are copied with these rules:
   * `\` and `/` → internal separator (`$09`).
   * Shift-JIS lead byte (`$80`–`$9F`, `$E0`–`$FF`): copied together with
     the next byte; the trail byte must be ≥ `$20`.
   * `$A0`–`$DF` (half-width kana): copied.
   * Control characters (< `$20`): error −13.
   * `"` `'` `+` `,` `;` `<` `=` `>` `[` `]` `|`: error −13.
   * `-` as the very first character: error −13 (allowed elsewhere).
   * Space: all following spaces are skipped; the next character must be NUL,
     a separator or `.` (the spaces are dropped), otherwise −13.
   * Everything else, including `:` `.` `*` `?`, is copied.
3. At most 89 bytes may be stored; more → −13.

### 9.2 Stage 2 — drive and absolute path [verified]

* If the string starts with a letter followed by `:`, that letter (case
  insensitive) is the logical drive; a non-letter → −15. Otherwise the
  current drive.
* The drive is translated (§3) and must be usable (−15).
* If the remainder does not start with a separator, the drive's current
  directory is prefixed.
* Path components are appended with these rules: `.` is dropped, `..`
  removes the previous component (`..` at the root → −13); any other
  component that starts with `.` → −13.
* The resulting directory path (without the final name) must be shorter than
  63 bytes, else −13.

### 9.3 Stage 3 — last component (name) [verified]

The bytes after the last separator form the name. A *fill character* is
used for "unspecified" parts: space for most calls, `?` for FILES when the
high byte of the attribute argument is 1 (21-file-io §11).

| Input form | name (8) | name2 (10) | ext (3) | flag byte |
|------------|----------|------------|---------|-----------|
| empty (path ends with separator), `.` | 8 × fill | zeros | 3 × fill | `$FF` |
| `..` | as empty, after removing one directory level | | | `$FF` |
| `.xyz` | 8 × fill (counted as 8 wildcards) | zeros | `xyz` | 8 + `?` count |
| `abc` | `abc` + spaces | zeros | 3 × fill | `?` count |
| `abc.x` | `abc` + spaces | zeros | `x` + spaces | |
| `abcdefghijk.x` | `abcdefgh` | `ijk` + NULs | `x  ` | |

* `*` in the name: rest of name and all of name2 become `?`; the next
  character must be NUL or `.` (else −13).
* `*` in the extension: rest of the extension becomes `?`.
* `:` anywhere in the name/extension → −13; a second `.` in the extension →
  −13; more than 18 name characters or more than 3 extension characters →
  −13.
* The flag byte counts every `?` stored in name, name2 or extension
  (including those produced by `*`), except the fill used for a missing
  extension.

### 9.4 NAMESTS ($FF29)

Args: `l name`, `l buffer` (88 bytes). Runs stages 1–3 with fill = space.
Output [verified]:

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | Flag: 0 = plain name, 1…`$FE` = number of wildcard `?`, `$FF` = no file name (directory only) |
| `$01` | 1 | Logical drive (0 = A:) |
| `$02` | 65 | Absolute path, `\` separators, leading and trailing `\` (root = `\`), NUL-terminated |
| `$43` | 8 | Name (space padded) |
| `$4B` | 3 | Extension (space padded) |
| `$4E` | 10 | name2 (NUL padded) |

Returns 0 or a negative error. Device names are **not** recognised, the file
is not looked up, ASSIGN aliases are not expanded. The path is converted
from internal `$09` to `\`, skipping Shift-JIS trail bytes.

### 9.5 NAMECK ($FF37)

Args: `l name`, `l buffer` (91 bytes). Same parse (fill = space). Output
[verified]:

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 2 | `"X:"` drive letter (logical) and colon |
| `$02` | 65 | Path as in NAMESTS |
| `$43` | 19 | Name: name bytes up to the first space, then name2 bytes up to NUL/space, NUL-terminated |
| `$56` | 5 | `"."` + extension without trailing spaces + NUL, **only if the input contained a `.` introducing an extension**; otherwise just NUL |

Returns the NAMESTS flag byte (0, wildcard count, or `$FF`) — not 0 — on
success, negative on error.

### 9.6 Device names

Calls that create or modify directory entries (CREATE, NEWFILE, MKDIR,
CHDIR, DELETE, RENAME, CHMOD, FATCHK, ASSIGN) return −13 when the 8-byte
name part matches the name of any character device in the driver chain
(case-insensitive; the drive, path and extension are ignored). OPEN instead
opens the device (21-file-io). [verified]

### 9.7 Option-character class

The file-name syntax layer also provides a "switch character" test used by
EXEC when it scans a program name: the characters `/`, `-`, `"` and `'`
end the name there. (Wildcards `?` `*` are handled by EXEC itself; see
11-process.) [verified]

---

## 10. ASSIGN ($FF8F) — virtual drives and directories

`w mode, l drive, …`. `drive` must point to exactly `"X:"` + NUL (letter any
case), else −14; letter > LASTDRIVE → −15. The letter is translated (§3)
and selects a current-directory entry. [verified]

| Mode | Further args | Effect |
|------|-------------|--------|
| 0 | `l buffer` | Get. For type `$50`/`$60` copies the entry's host path (drive + path up to the root offset, without the trailing separator unless it is the root); for other types copies the entry's whole current path. The drive letter is converted to the logical letter, separators to `\`. Returns the type (`$00`, `$40`, `$50`, `$60`). |
| 1 | `l path, w type` | Set. type `$50`: entry must currently be type 0 or `$40`; the drive becomes an alias of directory *path* (SUBST). type `$60`: entry must be type `$40` and not the current drive; the drive is mounted onto directory *path* of another drive (JOIN). Other types → −14. |
| 4 | — | Delete. Entry must be `$50` or `$60` (else −14). Restores a normal entry: type `$40` with the drive's own DPB if a physical unit exists, else type 0 (−14 if that drive is the current drive). Path reset to root. |
| other | | −14 |

Set details [verified]: *path* is parsed as a directory (wildcards → −13; a
trailing name is treated as a directory name); a non-root path must exist as
a directory (searched with attribute `$10`), else its error. The target's
own aliases are expanded first. For `$60`, following existing `$60` mounts
must not lead back to the entry itself (−14). The entry gets: path = host
drive letter + host path (trailing separator removed), root offset = length
of that path, cluster `$FFFF`, type; for `$50` also DPB := host DPB.

How lookups use them [verified]:

* Type `$50`: when a parsed path's drive is such an alias, the host path
  prefix is inserted in front of the path and the host drive is used. The
  combined path must stay ≤ 64 bytes (−13).
* Type `$60`: after alias expansion, if the path (on its drive) starts with
  the host path of a `$60` entry followed by a separator, the remainder is
  re-rooted on the mounted drive. Applied repeatedly.
* `$60` drives cannot be selected or used directly.

---

## 11. Media change handling

Every validation of a local drive performs a media check [verified]:

1. DRVCTRL request (command 5, mode 9) to the driver. If the request fails
   or bit 1 of the returned status byte (+13) is 0 (no medium — [inferred]
   meaning): all buffers of the drive are invalidated (dirty data discarded)
   and the check reports "changed" without rebuilding the DPB. Callers that
   test the result (CLOSE) then give up (21-file-io §7).
2. Otherwise MEDIA CHECK (command 1). Result byte (packet +14): positive or 0
   → unchanged. Negative (or error) → changed: buffers invalidated, BUILD BPB
   (command 2), DPB rebuilt (§5.2), DRVCTRL mode 7 sent, rover reset, and
   every current-directory entry using that DPB is re-validated: its stored
   path is looked up again; if it no longer exists the entry is reset to the
   root.

For remote drives request `$57` replaces steps 1–2; a negative reply causes
the same current-directory re-validation.

DRVCTRL eject (modes 1 and 9) refuses with −34 if any open file uses the
drive, otherwise flushes, invalidates, and resets that drive's current
directory to the root (§14.3).

Before any write-type operation (CREATE, MKDIR, DELETE, RENAME, CHMOD set,
DISKWRT) the kernel issues DRVCTRL status (mode 0); while bit 3
(write-protected) is set it raises the critical-error handler with code `$0E`
("cannot write") and repeats the check after Retry. [verified]

---

## 12. Block-device requests issued

Request header length is `$1A`. Fields used [verified]:

| Cmd | Use | Packet fields set | Reply used |
|-----|-----|-------------------|-----------|
| 1 | media check | +1 unit, +13 media byte | +14 (signed byte), +3 error |
| 2 | build BPB | +1 unit, +13 media, +18 = 0 | +18 = pointer to a long that points at the BPB |
| 3 / 12 | IOCTL read / write (IOCTRL 2–5) | +1 unit, +13 media, +14 buffer, +18 length | — |
| 4 | read sectors | +1 unit, +13 media, +14 buffer, +18 count, +22 start sector | — |
| 5 | drive control/status (DRVCTRL, media check, eject interlock) | +1 unit, +13 mode, +14 = pointer to caller's args, +18 = 0 | +18 long if non-zero, else +13 byte |
| 8 / 9 | write sectors / write with verify | as 4 | — |
| 6 / 10 | input / output status (IOCTRL 6/7) | +1 unit | +3 |
| 19 | generic IOCTL (IOCTRL 12/13) | +1 unit, +13 media, +14 pointer, +18 function code (word) | — |

A non-zero error byte (+3) on read/write/IOCTL requests invokes the
critical-error handler (Abort/Retry/Ignore, see 01-dos-dispatch) with the
status high byte (+4) and error code (+3); Retry re-issues the request.
Media-check, build-BPB, status and DRVCTRL-mode-9 requests are issued
without the handler.

Character devices receive commands 4 (read) and 8 (write) with +14 buffer,
+18 count; the count actually transferred is taken from +18.

---

## 13. Remote drives

A DPB with bytes/sector = 0 marks a remote (network/host-file-system) drive.
Its driver (attribute bit 13 set) receives whole operations instead of sector
I/O. Command byte = value below, OR `$80` when VERIFY is on; packet fields
+13 (byte), +14, +18, +22 (longs); result = long at +18. [verified]

| Cmd | Operation | +14 | +18 | +22 | +13 |
|-----|-----------|-----|-----|-----|-----|
| `$41` | CHDIR (validate dir) | NAMESTS | | | |
| `$42` | MKDIR | NAMESTS | | | |
| `$43` | RMDIR | NAMESTS | | | |
| `$44` | RENAME | old NAMESTS | new NAMESTS | | |
| `$45` | DELETE | NAMESTS | | | |
| `$46` | CHMOD | NAMESTS | | | attr |
| `$47` | FILES | NAMESTS | FILES buffer | | attr |
| `$48` | NFILES | | FILES buffer | | |
| `$49` | CREATE/NEWFILE | NAMESTS | mode word: 1=CREATE/0=NEWFILE, attr high byte in bits 16–23 | FCB | attr |
| `$4A` | OPEN | NAMESTS | | FCB | |
| `$4B` | CLOSE | | | FCB | |
| `$4C` | READ | buffer | length | FCB | |
| `$4D` | WRITE | buffer | length | FCB | |
| `$4E` | SEEK | | offset | FCB | mode |
| `$4F` | FILEDATE | | date/time | FCB | |
| `$50` | DSKFRE | buffer | | | |
| `$51` | DRVCTRL | args ptr | | | mode |
| `$52` | GETDPB | buffer+2 | | | |
| `$53`/`$54` | DISKRED/DISKWRT (long form) | buffer | start | count | |
| `$55` | IOCTRL 13 | pointer | function code in high word | | |
| `$56` | FFLUSH | | | | |
| `$57` | media check | | | | |
| `$58` | LOCK | offset | length | FCB | mode |

The NAMESTS passed is the parsed record (§9.4 layout, internal `$09`
separators in the path) after alias expansion. Files on remote drives have
FCB flag bit 5 set (21-file-io §3).

---

## 14. Calls

### 14.1 CHGDRV ($FF0E)
Arg `w drive` (0 = A:). If drive > `$1C73`: no change, returns
LASTDRIVE+1 (number of drive letters). If the drive is valid but not
usable (type 0 or `$60`): no change, returns the requested drive number.
Otherwise sets the current drive and returns LASTDRIVE+1. [verified]

### 14.2 CURDRV ($FF19)
No args. Returns current drive (0 = A:). [verified]

### 14.3 DRVCTRL ($FF0F)
Arg `w (mode << 8) | drive` (drive 0 = current, 1 = A:). Invalid drive →
−15. [verified]

| Mode | Kernel action before sending command 5 (mode in +13) |
|------|------------------------------------------------------|
| 0 | status only (returns status byte: bit 1 media present, bit 2 eject inhibited, bit 3 write-protected — [public] meaning of bits) |
| 1, 9 | eject: −34 if a file on this DPB is open; flush buffers; invalidate buffers; current directory := root; rover := 2 |
| 2 | none |
| 3 | flush the drive's buffers |
| 4, 5 | none |
| 10 | rover := 2 (local drives) |
| 6–8, 11–15 | −14 (not passed to the driver) |
| ≥ 16 | none |

Returns the driver's reply (+18 if non-zero, else +13).

### 14.4 CURDIR ($FF47)
Args `w drive` (0 = current), `l buffer` (64 bytes). Copies the current
directory of that drive without drive letter and without leading `\`
(root → empty string), `\` separators, NUL-terminated (at most 63 chars +
NUL). Returns 0 or −15. [verified]

### 14.5 CHDIR ($FF3B)
Arg `l path`. Parse; wildcards → −13; a plain name is appended as the final
directory component; a trailing separator or `.` means "this path". Device
name → −13. The directory must exist (−3). Sets the entry's cluster and
path (trailing separator removed except for root). The current drive is not
changed. Remote: request `$41`. Returns 0. [verified]

### 14.6 MKDIR ($FF39)
Arg `l path`. Parse; wildcards or no name (`$FF`) → −13. Parent must exist
(−3). Existing entry of that name (any attribute) → −20. Creates the entry
(attribute `$10`, size 0, current date/time) and the first cluster (§8.5).
Errors −23/−24 as in §6/§8. Flushes. Returns 0. Remote: `$42`. [verified]

### 14.7 RMDIR ($FF3A)
Arg `l path`. Parse; wildcards or no name → −13 (so the root cannot be
removed). If the directory is the current directory of any drive → −16. If
it contains any entry other than `.` and `..` → −21. Not found → −2; found
but not a directory → −3; read-only or system → −19. Deletes the entry and
frees its chain; flushes. Returns 0. Remote: `$43`. [verified]

### 14.8 DSKFRE ($FF36)
Args `w drive` (0 = current), `l buffer` (8 bytes). [verified]

| Off | Size | Value |
|-----|------|-------|
| 0 | 2 | free clusters |
| 2 | 2 | total clusters (DPB `$16` − 3) |
| 4 | 2 | sectors per cluster |
| 6 | 2 | bytes per sector |

Returns free bytes (free × spc × bps; 32-bit, may wrap) or −15.
Remote: `$50`, result = driver reply.

### 14.9 FATCHK ($FF17)
Args `l name`, `l buffer` [, `w length`]. [verified]

* If bit 31 of `buffer` is clear (classic form): entries are **words**;
  values ≥ `$10000` are stored as `$FFFF`; no length limit.
* If bit 31 is set (extended form): buffer address = low 24 bits, the third
  argument is the buffer length in bytes, entries are longs; running out of
  room → −14.

Output: word logical drive + 1; then for each run of physically consecutive
clusters a pair (first sector, sector count); then a single 0 entry.
Empty file (cluster 0): just the terminator. Returns the number of bytes
written. Errors: wildcard or no name → −13; device name → −13; not found →
−2; remote drive → −15; buffer too small (extended) → −14.

### 14.10 VERIFY ($FF2E) / VERIFYG ($FF84)
Set `$1C10` := arg word / return it (see 40-misc-calls). Effect: §7, §12.

### 14.11 NAMESTS, NAMECK, ASSIGN, GETDPB, DRVXCHG
See §9.4, §9.5, §10, §5.3, §3.

---

## 15. Error codes used here

| Code | Name | Typical cause |
|------|------|---------------|
| −2 | file not found | lookup failed |
| −3 | directory not found | path component missing / not a directory; RMDIR of a file |
| −5 | cannot access directory/volume | OPEN of a directory or label |
| −13 | invalid name | parser errors, wildcards where not allowed, device names |
| −14 | invalid parameter | bad mode/sub-function, FATCHK buffer |
| −15 | invalid drive | bad letter, unusable drive, remote-only restriction |
| −16 | current directory | RMDIR of a current directory |
| −19 | cannot write | read-only/system/dir/label target |
| −20 | directory exists | MKDIR |
| −21 | directory not empty | RMDIR |
| −23 | disk full | no free cluster |
| −24 | directory full | no free directory slot |
| −34 | file in use | DRVCTRL eject with open files |
