# 21 — File I/O: handles, FCBs, sharing, file calls

Companion to `20-filesystem.md` (paths, directories, FAT, buffers, remote
drives). Arguments are on the caller's stack, first argument at the lowest
address; result in `d0.l`. Error codes: see §13 and `01-dos-dispatch.md`.

---

## 1. Handle model

[verified] unless noted.

* Handles are **system-wide**, not per process. A handle number indexes one
  global handle table; each used entry names an internal file control block
  (FCB, §2). Several handles may share one FCB (DUP), each FCB has a
  reference count.
* Handle numbers run from 0 to FILES (`$1C6E`). Handles 0–5 and FCBs 0–5 are
  static; handles/FCBs 6…FILES live in tables allocated at boot from the
  CONFIG `FILES=` value (pointers at `$1C2C` / `$1C30`).
* **Allocation**: OPEN/CREATE/NEWFILE/MAKETMP/DUP take the lowest free
  handle starting at 5, but never use the two highest numbers
  (FILES−1 and FILES); likewise FCBs are taken from 5 … FILES−2. So at most
  FILES−5 handles can be opened by these calls. DUP2 can target any handle up
  to FILES. Failure → −4.
* A handle argument greater than FILES → −4; a free handle → −6.
* Internally each handle-table entry is a word whose low byte is the FCB
  index (`$FF` = free). The high byte has no further meaning except that a
  free entry is `$FFFF`.

### 1.1 Standard handles

| Handle | Default FCB / device |
|--------|----------------------|
| 0 | stdin — CON |
| 1 | stdout — CON |
| 2 | stderr — CON |
| 3 | stdaux — AUX |
| 4 | stdprn — PRN |

[verified] For each of 0–4 the kernel keeps a *default* entry. Closing one of
these handles does not free it: the handle is reset to its default entry
and the reference count of the FCB it pointed to is decremented. The five
static device FCBs are never freed: when the count of one of FCBs 0–4 would
drop to 0 it stays 1 and FCBs 0–4 are re-bound to the current devices
(FCB0 to the device with the "standard input" attribute bit, FCBs 1 and 2 to
the "standard output" device, FCB3 to the device named `AUX`, FCB4 to `PRN`,
matching on the 8-byte name in the driver header). DUP0 changes both the
live and the default entry (§9.3).

### 1.2 Ownership, inheritance, process exit

[verified]

* When a handle ≥ 5 and < 96 is allocated, its bit is set both in a global
  in-use bitmap and in the **current process's** handle bitmap: 12 bytes at
  PSP+`$14` (bit *n mod 8* of byte *n div 8*). The bit is cleared when the
  handle is closed.
* Child processes simply see all open handles (global table) — that is the
  inheritance mechanism; nothing is copied.
* At process exit (EXIT/EXIT2) and on ALLCLOSE, every handle
  5…95 whose bit is set in the process's bitmap is closed.
* The forced-termination path (Ctrl-C abort / kill) closes every handle
  0…FILES and flushes all buffers.

---

## 2. FCB (internal file control block) — GETFCB ($FFAC)

GETFCB: arg `w handle`; returns the address of the handle's 96-byte FCB, or
−4/−6. [verified] Programs do read this block (e.g. to get the file name or
size of an open handle), so the layout is an ABI.

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | Reference count (0 = FCB free) |
| `$01` | 1 | Flags, see below |
| `$02` | 4 | Character device: driver header. File: internal DPB |
| `$06` | 4 | Current file position |
| `$0A` | 4 | Sharing-table entry (0 = none) |
| `$0E` | 1 | Open mode as passed to OPEN (CREATE stores 3) |
| `$0F` | 1 | Index (0–n) of the directory entry within its directory sector |
| `$10` | 1 | Sector index within the current cluster |
| `$11` | 1 | (cleared) |
| `$12` | 2 | Current cluster (0 = not yet positioned) |
| `$14` | 4 | Current absolute sector (0 = not positioned; −1 = position lies beyond the allocated chain, e.g. after "disk full") |
| `$18` | 4 | Cached pointer to the buffer holding the current sector (0 = none) |
| `$1C` | 4 | Sector containing the directory entry |
| `$20` | 4 | File position for which `$10`/`$12`/`$14` are valid |
| `$24` | 32 | Copy of the directory entry, numbers **big-endian**: name 8 (`$24`), ext 3 (`$2C`), attribute (`$2F`), name2 10 (`$30`), time (`$3A`), date (`$3C`), first cluster (`$3E`), size (`$40`). For devices only the 8-byte name at `$24` is meaningful. |
| `$44` | 28 | Cluster-run cache (7 longs, −1 = empty). Internal. |

Flags byte `$01` [verified]:

| Bit | Character device | File |
|-----|------------------|------|
| 0–4 | copy of driver attribute bits 0–5 (0 stdin, 1 stdout, 2 NUL, 3 CLOCK, 5 raw) | physical drive (0 = A:) |
| 5 | raw (binary) mode | remote-drive file |
| 6 | 1 | file modified since open / last FILEDATE (directory entry needs update on close) |
| 7 | 1 = character device | 0 |

A newly allocated FCB is cleared to zero in `$00`–`$43` and to `$FF` in
`$44`–`$5F` before being filled.

---

## 3. Text/binary behaviour of character devices

[verified]

* **Cooked read, console** (device with stdin attribute, raw bit clear):
  the kernel keeps a line buffer. When it is empty a whole line is read with
  the normal line editor (as GETS, 30-char-io) and CR LF is appended. READ
  then returns bytes from this buffer, stopping after the LF or when the
  requested length is reached; the rest is kept for the next READ. If the
  byte handed out is Ctrl-Z (`$1A`) the rest of the line is discarded and the
  READ ends there (the `$1A` is returned and counted). FFLUSH discards a
  pending line.
* **Cooked read, other character devices**: one byte per driver request;
  stops after storing a `$1A` or `$0A` (both stored and counted), when the
  driver returns 0 bytes, or at the requested length.
* **Raw read** (raw bit set): one driver request for the whole length; the
  count returned is what the driver reports.
* **Cooked write**: each byte goes through the console output routine of
  that handle (so Ctrl-S/Ctrl-C checking and TAB handling apply as in
  30-char-io); the call returns the requested length.
* **Raw write**: one driver request; returns the driver's count.
* **NUL device** (attribute bit 2): READ returns 0, WRITE returns the
  requested length, no driver call.
* Files are always binary: no Ctrl-Z or CR/LF processing on files.

---

## 4. Opening and creating

### 4.1 OPEN ($FF3D)

Args `l name`, `w mode`. [verified]

Mode byte: bits 0–3 access (0 read, 1 write, 2 read/write), bits 4–6
sharing (0 compatibility, 1 deny read/write, 2 deny write, 3 deny read,
4 deny none). Access ≥ 3 or mode byte ≥ `$50` → −12. The high byte of the
mode word is ignored.

1. Name parsed (20-filesystem §9); wildcards or no name → −13.
2. A handle and FCB are allocated (−4).
3. **Device**: if the 8-byte name part equals a character device name, the
   device is opened regardless of drive, path or extension. FCB: device
   pointer, mode, flags = attribute bits 0–5 | `$C0`, name. Opening the CLOCK
   device (attribute bit 3) fails with −13. No sharing check.
4. **File**: drive/alias resolution, then sharing registration (§6); remote
   drive → request `$4A`.
5. The entry is looked up (any attribute): not found → −2 (missing path →
   −3). Directory or volume label → −5. Write or read/write access on a
   read-only or system file → −19. Hidden files can be opened.
6. FCB gets the directory entry copy, position 0. Returns the handle.

On any error after step 2 the handle, FCB and sharing slot are released.

### 4.2 CREATE ($FF3C) and NEWFILE ($FF8B)

Args `l name`, `w attr`. Same code; NEWFILE fails if the file exists.
[verified]

* attr 0 is replaced by `$20`. Bit 15 of attr set ("no existence check"):
  the directory is not searched — a second entry with the same name may be
  created.
* Name rules as for OPEN but device names → −13; wildcards/no name → −13.
* The FCB is opened with internal mode 3 (read/write); sharing registration
  with that mode.
* If an entry with that name exists (any attribute): NEWFILE → −80.
  CREATE: directory or volume label → −19; read-only or system → −19;
  otherwise the old entry is deleted and its chain freed, then a new entry
  is made (usually in the same slot).
* New entry: given attribute, name/name2/ext from the parsed name (case as
  typed), current time and date, size 0. **A first cluster is allocated
  immediately** (unless the attribute has the volume-label bit), so a
  freshly created empty file owns one cluster. No cluster → −23. No
  directory slot → −24.
* The directory sector is updated in the cache; nothing is flushed.
* Remote drives: request `$49`.
* NEWFILE quirk: if the sharing registration fails, NEWFILE returns −80
  instead of the sharing error.
* Returns the handle.

### 4.3 MAKETMP ($FF8A)

Args `l name` (modified in place), `w attr`. [verified]

* The file-name part is the text after the last `\`, `/` or `:` (Shift-JIS
  lead bytes `$81`–`$9F`, `$E0`–`$EF` skip their trail byte). Empty → −13.
* Every `?` in the file-name part is replaced by `0`.
* NEWFILE is attempted. While it returns −80 the name is "incremented": the
  rightmost ASCII digit of the file-name part (digits anywhere in it,
  including the extension) is incremented; `9` wraps to `0` and the carry
  moves to the next digit to the left; non-digits are skipped. When all
  digits have wrapped → −80.
* Any other result (handle or error) is returned; the caller's string holds
  the name actually used.

---

## 5. Reading, writing, positioning

### 5.1 READ ($FF3F)

Args `w handle`, `l buffer`, `l length`. [verified]

* length 0 → returns 0 immediately (even for an invalid handle).
* Character devices: §3.
* Files: the open mode is **not** checked (a write-only handle can read).
  Lock check against other handles' locks (§6.3) → −33. Media check. Reads
  min(length, size − position) bytes; returns the count (0 at EOF) and
  advances the position.
* After a file READ or WRITE, if BREAK mode (`$1C12`) is 1, the keyboard is
  polled for Ctrl-C.

### 5.2 WRITE ($FF40)

Args `w handle`, `l buffer`, `l length`. [verified]

* Handle opened with access 0 (read) → −12 (devices too).
* Character devices: §3. length 0 → 0.
* Files: lock check (−33). Media check.
  * **length 0: truncates the file at the current position** (size :=
    position, clusters beyond it freed, see 20-filesystem §6.6) and returns
    0.
  * Otherwise data are written at the position, extending the chain as
    needed; size := max(size, new position); modified flag set. Returns the
    number of bytes written.
  * **Disk full is not an error**: the call returns the number of bytes
    actually written (possibly 0).
  * A file whose directory entry has first cluster 0 (empty file created
    by another system) cannot be written: −25.
* Remote drives: request `$4D`; the modified flag is set.

### 5.3 SEEK ($FF42)

Args `w handle`, `l offset`, `w mode` (0 from start, 1 from current, 2 from
end). [verified]

* Character device: no effect, returns 0.
* Mode > 2 → −14.
* New position < 0 or > file size → −25 (**cannot seek past end of
  file**). Otherwise position := new value; returns it.
* Remote: request `$4E`.

### 5.4 FGETC ($FF1B), FGETS ($FF1C), FPUTC ($FF1D), FPUTS ($FF1E)

[verified]

* **FGETC** `w handle`: reads one byte (as READ). Returns the byte (0–255),
  −1 if nothing was read, or the error.
* **FGETS** `l buffer`, `w handle`. Buffer: byte 0 = maximum length, byte 1
  = returned length, data from byte 2.
  * If the handle is the cooked console input (stdin device, raw clear):
    behaves exactly like GETS ($FF0A) on that buffer.
  * Otherwise bytes are read one at a time up to the maximum: CR is dropped
    (not counted); LF ends the line and is replaced by NUL (not counted);
    `$1A` is stored, counted and ends the line. A NUL is written after the
    data. If the first read returns nothing or fails the result is −1.
    Returns the count (also stored in byte 1).
* **FPUTC** `w char`, `w handle`: writes one byte; returns WRITE's result.
* **FPUTS** `l string`, `w handle`: writes the string without its NUL;
  empty string → 0 without calling WRITE; else WRITE's result.

---

## 6. Sharing and locking

Active only when CONFIG `SHARE=` created a sharing table (`$1C40` ≠ 0).
[verified]

### 6.1 Sharing table

`$1C76` entries of `$1C7A` = `$5C` + 12 × `$1C78` bytes:

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | Number of FCBs using this entry (0 = free) |
| `$01` | 1 | Open mode of the **first** opener (later openers do not change it) |
| `$02` | 2 | Number of used lock records |
| `$04` | 88 | NAMESTS record of the file (identifies it) |
| `$5C` | 12×n | Lock records: offset (l, −1 = placeholder), length (l), FCB (l) |

A file is identified by comparing drive, path (case-insensitive) and the
11-byte name+extension of the NAMESTS records.

### 6.2 Opening with sharing

* Without a sharing table, any mode with sharing bits ≠ 0 → −12.
* With a table: if no entry exists for the file a free one is taken (none →
  −32); otherwise the new open is checked against the entry's stored mode
  using the matrix below (fail → −33). Each open also consumes one lock
  record as a placeholder (table of records full → −32), and the FCB
  remembers the entry.
* Compatibility table [verified] — first column: mode stored in the entry
  (share/access of the first opener); second column: requested modes that
  are allowed. Access r/w/rw = 0/1/2; "3" is the access value CREATE uses
  internally and the value used for the delete/rename/chmod check. Any
  combination not listed → −33.

| Existing | Allowed requests |
|----------|------------------|
| compat/r | compat/r |
| compat/w, compat/rw, compat/3 | — |
| deny-RW/any | — |
| deny-W/r | deny-W/r, deny-none/r |
| deny-W/w | deny-R/r, deny-none/r |
| deny-W/rw | deny-none/r |
| deny-W/3 | deny-R/r, deny-none/r |
| deny-R/r | deny-W/w, deny-none/w, deny-none/3 |
| deny-R/w | deny-R/w, deny-R/3, deny-none/w, deny-none/3 |
| deny-R/rw | deny-none/w, deny-none/3 |
| deny-R/3 | deny-R/w, deny-R/3, deny-none/w, deny-none/3 |
| deny-none/r | deny-W/(r, w, rw, 3), deny-none/(r, w, rw, 3) |
| deny-none/w | deny-R/(r, w, rw, 3), deny-none/(r, w, rw, 3) |
| deny-none/rw | deny-none/(r, w, rw, 3) |
| deny-none/3 | deny-R/(r, w, rw, 3), deny-none/(r, w, rw, 3) |

  Share values 5–7 cannot reach the table (OPEN rejects mode ≥ `$50`).
* DELETE, RENAME (source) and CHMOD (set) on a file present in the sharing
  table are checked as requested mode "compat, access 3", which no row
  allows → −33. [verified]
* CLOSE of the last FCB frees the entry; otherwise the closing FCB's lock
  records (including its placeholder) are removed.

### 6.3 LOCK ($FF8C)

Args `w mode` (0 lock, non-zero unlock), `w handle`, `l offset`,
`l length`. [verified]

* Character device, or file without a sharing entry → −14.
* Remote drive: request `$58`.
* Lock: if [offset, offset+length) overlaps any existing lock record of the
  file (any FCB, including the caller's own) → −33; record table full →
  −14; else the record is added. Returns 0.
* Unlock: a record with exactly this offset, length and FCB must exist
  (else −33); it is removed. Returns 0.
* READ/WRITE of [position, position+length) overlapping a lock record owned
  by **another** FCB → −33 (before any data is moved).

---

## 7. CLOSE ($FF3E)

Arg `w handle`. [verified]

1. Invalid/closed handle → −4/−6.
2. Handle 0–4: reset to its default (§1.1). Handle ≥ 5: freed, bitmap bits
   cleared. The FCB reference count is decremented.
3. Character device: returns 0.
4. If the count is still > 0: for a local file the directory entry is still
   updated and the drive flushed (step 6); for a remote file nothing more.
5. Count reached 0: sharing entry released; remote → request `$4B`.
6. Local file: media check — if the medium was changed, returns −1 without
   writing. If the modified flag is set, the entry's time and date are set
   to **now**, the flag cleared, and the directory entry (size, first
   cluster, time, date, attribute) rewritten. Before rewriting, the
   kernel verifies that the on-disk slot still holds an entry with the same
   first cluster that is not deleted; if not, the critical-error handler is
   invoked (code `$0F`) and the update is skipped. Then all dirty buffers of
   the drive are written. Returns 0.

---

## 8. Directory-entry calls on names

### 8.1 DELETE ($FF41)

Arg `l name`. Wildcards/no name/device name → −13. Sharing check (§6.2).
Not found → −2. Directory or volume label → −19; read-only or system →
−19 (hidden files can be deleted). Marks the entry `$E5`, frees the chain,
flushes. Returns 0. Remote: `$45`. [verified]

### 8.2 RENAME ($FF86)

Args `l old`, `l new`. [verified]

* Both parsed; wildcards/no name/device name → −13. Both must be on the
  same physical drive after alias expansion, else −15. Sharing check on
  `old`.
* If `new` already exists: allowed only if it is the very same entry as
  `old` (same first cluster and same low 16 bits of size) — this permits
  changing the case of a name; otherwise −22.
* Same directory: `old` must not be read-only/system (−19); name, ext and
  name2 are overwritten in place (directories may be renamed this way).
* Different directory (move): `old` must not have read-only, hidden,
  volume or directory attribute (−19). The old slot is marked deleted,
  then a slot is allocated in the target directory (−24 possible — the
  file is then lost, the old slot already being deleted) and the entry
  copied there with the new name.
* Flushes; returns 0. Remote: `$44`.

### 8.3 CHMOD ($FF43)

Args `l name`, `w attr`. [verified]

* Wildcards/no name/device → −13. Not found → −2.
* attr = −1 (`$FFFF`): returns the entry's attribute byte.
* Otherwise: sharing check; the attribute byte is replaced by the low byte
  of `attr` **without any validation** (directory and volume bits can be
  set or cleared); flush; returns 0.
* Works on directories and volume labels too. Remote: `$46`.

### 8.4 FILEDATE ($FF87)

Args `w handle`, `l datetime`. [verified]

* datetime ≠ 0 and handle opened read-only → −12.
* Character device: returns 0 (both get and set).
* datetime = 0: returns `(date << 16) | time` of the FCB.
* Otherwise: FCB time := low word, date := high word; directory entry
  rewritten in the cache (with the same "slot still valid" check as CLOSE);
  modified flag cleared, so a later CLOSE keeps this stamp unless more data
  are written. Returns 0.
* Remote: `$4F`.

---

## 9. Handle duplication

### 9.1 DUP ($FF45)

Arg `w handle`. New handle (lowest free ≥ 5, see §1) referring to the same
FCB; reference count +1; bitmap bits set. Returns the new handle, −4 or −6.
The position is shared (it lives in the FCB). [verified]

### 9.2 DUP2 ($FF46)

Args `w src`, `w dst`. [verified]

* `src` must be open (−4/−6).
* If `dst` is open it is closed first (full CLOSE semantics, including
  directory update), except that for 0–4 the handle is not reset to its
  default.
* `dst` then refers to `src`'s FCB; count +1; bitmap bit of `dst` set (if
  < 96).
* Returns a **non-negative value that is the internal FCB index of `src`**,
  not 0 and not `dst`. Callers should only test the sign.
* `dst` greater than FILES is not rejected; behaviour undefined (QUESTIONS).
* `src == dst` is not special-cased.

### 9.3 DUP0 ($FF2F)

Args `w file`, `w std` (std = 0–4). [verified]

* `file` > FILES or `std` > 4 → −4.
* Both the live and the default table entry of handle `std` are set to
  refer to internal FCB index `file`. The value is used directly as an FCB
  index: it designates the FCB of handle `file` only when that FCB index
  equals the handle number (true for handles 0–5 and often, but not
  necessarily, for others). No reference count is changed.
* Returns the FCB index that the default entry had before.

---

## 10. FFLUSH ($FF0D), ALLCLOSE ($FF1F)

* FFLUSH: see 20-filesystem §7.
* **ALLCLOSE**: closes every handle 5…95 whose bit is set in the current
  process's bitmap, then repeats for the process block linked from the
  current one (child chain) as long as that block's parent is the process
  just handled. Returns 0. Handles 0–4 are not touched. [verified]

---

## 11. FILES ($FF4E) / NFILES ($FF4F)

### 11.1 FILES

Args `l buffer`, `l pattern`, `w attr`. [verified]

* attr low byte = attribute mask (stored at buffer+0). If the **high byte**
  of `attr` is 1, unspecified name/extension parts are filled with `?`
  instead of spaces (so `FOO` matches `FOO.*` and `*` matches every name);
  otherwise `FOO` matches only `FOO` without extension and `*` only names
  without extension.
* If bit 31 of `buffer` is set, the buffer address is the low 24 bits and
  the full path of the search (`X:\path\`, `\` separators) is also stored at
  buffer+`$35` (extended 141-byte buffer).
* The directory is searched from the start; matching per 20-filesystem
  §8.2.

Buffer (53 bytes, +88 in extended form):

| Off | Size | Meaning |
|-----|------|---------|
| `$00` | 1 | attribute mask |
| `$01` | 1 | physical drive (0 = A:) |
| `$02` | 4 | sector of the directory containing the match |
| `$06` | 2 | sectors remaining in the current cluster (internal) |
| `$08` | 2 | byte offset of the matched entry in that sector; `$FFFF` = search finished |
| `$0A` | 11 | pattern: name 8 + extension 3 |
| `$15` | 1 | attribute of the found entry |
| `$16` | 2 | time |
| `$18` | 2 | date |
| `$1A` | 4 | size |
| `$1E` | 23 | name as text (20-filesystem §8.3), NUL-terminated |
| `$35` | 88 | (extended) search path |

Results: 0 = found (fields filled). Not found / end of directory → −2.
Missing directory → −3. Parse errors as usual. On any error, and when the
pattern contained no wildcard, `$08` is set to `$FFFF` so that NFILES
returns −18. If a found entry's name contains a control character, `:`, `?`
or `*`, the critical-error handler is invoked (code 7) and −18 returned.
Remote: request `$47`.

### 11.2 NFILES

Arg `l buffer` (as left by FILES). Drive from buffer+1 must have a DPB
(−15). `$08` = `$FFFF` → −18. Otherwise continues after the previous match
in the same directory. Found → 0 with fields updated; end of directory →
−2 and `$08` := `$FFFF` (so the next NFILES gives −18). Remote: `$48`.
[verified]

---

## 12. IOCTRL ($FF44)

First argument `w function`. Function ≥ 14 or 8 → −14. [verified]

| Fn | Further args | Behaviour |
|----|--------------|-----------|
| 0 | `w handle` | Returns `(driver attribute & $FF00) \| FCB flags byte` (§2). For files the driver is the block driver of the drive. |
| 1 | `w handle, w data` | Character device: FCB raw bit (bit 5) := bit 5 of `data`; returns the new flags byte. File: no change, returns the flags byte. |
| 2 / 3 | `w handle, l ptr, l len` | IOCTL read / write (driver commands 3 / 12). Requires driver attribute bit 14 (IOCTRL supported), else −17; for a file the block driver is used and a remote drive → −17. Returns 0. |
| 4 / 5 | `w drive, l ptr, l len` | Same as 2/3 addressed by drive (0 = current); −15 for invalid drive. |
| 6 / 7 | `w handle` | Input / output status (driver commands 6 / 10). Returns −1 (`$FFFFFFFF`) when the driver's status byte (+3) is 0 (ready), 0 otherwise. Files: the block driver of the drive is asked; remote files return −1. |
| 9 | `w drive` | Returns `(driver attribute & $FF00) \| physical drive`; if attribute bit 13 (remote) is set, bit 5 of the result is also set. |
| 10 | `w handle` | Same as 0. |
| 11 | `w count, w wait` | Sets retry count (`$1C0C`) and retry wait (`$1C0E`); returns 0. |
| 12 | `w handle, w code, l ptr` | Generic IOCTL (driver command 19, +18 = code, +14 = ptr). Character devices: always sent, returns 0. Files: as 13 on the file's drive. |
| 13 | `w drive, w code, l ptr` | Requires driver attribute bit 6, else −17. Remote drive: request `$55`, returns its result. Otherwise command 19; returns 0. |

---

## 13. Error codes used here

| Code | Meaning in this file |
|------|----------------------|
| −1 | CLOSE after media change; FGETC/FGETS nothing read |
| −2 | file not found / FILES no match / NFILES end |
| −3 | path not found |
| −4 | too many open files; handle number > FILES |
| −5 | OPEN of directory or volume label |
| −6 | handle not open |
| −12 | invalid access mode (OPEN mode, WRITE on read handle, FILEDATE set on read handle, sharing bits without SHARE) |
| −13 | bad name / wildcard / device name where a file is required / CLOCK open |
| −14 | invalid parameter (SEEK mode, IOCTRL function, LOCK on device or unshared file, lock table full) |
| −15 | invalid drive; RENAME across drives |
| −17 | IOCTRL not supported by driver |
| −18 | no more files (NFILES) |
| −19 | write-protected entry (read-only/system/dir/label) |
| −22 | RENAME target exists |
| −23 | disk full (CREATE) |
| −24 | directory full |
| −25 | SEEK out of range; WRITE to a file with no first cluster |
| −32 | sharing table / lock records exhausted |
| −33 | sharing or lock violation |
| −80 | file exists (NEWFILE, MAKETMP) |
