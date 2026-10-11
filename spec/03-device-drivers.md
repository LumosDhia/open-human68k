# 03 — Device drivers

Device-header layout, attribute bits, request packets per command, chain handling, the
built-in devices and how the kernel talks to drivers.

Confidence tags: **[verified]**, **[inferred]**, **[public]**. Unless tagged, statements are [verified].

---

## 1. Device header

Every driver starts with one or more 22-byte headers (a driver file may chain several).

| Offset | Size | Meaning |
|---|---|---|
| +$00 | L | Next header address. Negative (normally `$FFFFFFFF`) = end of this file's chain / end of the system chain. Rewritten by the kernel when linking. |
| +$04 | W | Attribute word (§1.1). |
| +$06 | L | Strategy routine address. |
| +$0A | L | Interrupt (execution) routine address. |
| +$0E | 8 B | Character device: name, space-padded (e.g. `CON     `). Block device: byte 0 = unit count hint, bytes 1-7 = descriptive name (not used for look-up; the unit count actually used is the one returned by INIT). |

The kernel never reads beyond +$15 of a header. Built-in drivers keep private storage
right after the header (not part of the interface).

### 1.1 Attribute word

| Bit | Mask | Meaning | |
|---|---|---|---|
| 15 | `$8000` | 1 = character device, 0 = block device | [verified] |
| 14 | `$4000` | IOCTRL (commands 3/12) supported; IOCTRL modes 2-5 fail with −17 otherwise | [verified] |
| 13 | `$2000` | **Special (remote) block device**: file-system level commands `$40-$58` (§4.4) are used instead of sector I/O; no BPB/FAT handling by the kernel | [verified] |
| 6 | `$0040` | Supports command 19 (special IOCTRL; IOCTRL modes 12/13) | [verified] |
| 5 | `$0020` | Raw/binary mode capable (char) | [public] |
| 3 | `$0008` | CLOCK device | [public; built-in CLOCK has it] |
| 2 | `$0004` | NUL device | [public; built-in NUL has it] |
| 1 | `$0002` | Standard output device — installing a char driver with this bit rebinds stdout/stderr (§5) | [verified] |
| 0 | `$0001` | Standard input device — rebinds stdin (§5) | [verified] |

---

## 2. Calling a driver

[verified]

* The kernel builds a request packet (§3) in its own memory (usually on its stack) and
  calls **strategy** then **interrupt** as subroutines (`jsr`), both with
  **a5 = packet address**, a1 = header address, supervisor mode, inside a DOS call or at
  boot. [verified] The built-in drivers preserve all registers except d0; third-party
  drivers should do the same — the kernel does not use d0 from the driver but does rely
  on a5/a1 surviving the strategy call. [inferred]
* On MPU type ≥ 2 (68020+), around every driver call the kernel reads the cache state
  (IOCS `$AC`, d1 = 1), sets it to "instruction cache only" (d1 = 4, d2 = state & 1),
  calls the driver, flushes the caches (d1 = 3), and restores the original state (d1 = 4).
  Drivers therefore run with the data cache disabled.
* **Completion status** is the error pair at packet +3 (low) / +4 (high). 0 at +3 = success.
* For data-transfer and control requests the kernel retries on error: it raises trap #14
  with d7 = (+4 << 8) | +3 (00 §5.2). Answer Retry → the same request is issued again;
  Ignore → the request is treated as successful; Abort → the DOS call is aborted (ERRJVC).
  The high byte therefore tells which answers are offered: `$10` abort, `$20` retry,
  `$40` ignore (e.g. `$7002` = A/R/I, "not ready"). Low byte = device error number 1-15
  (00 §5.2). Status queries (6, 10, sense) and INIT are **not** retried: a non-zero +3
  just means "not ready" / "failed".

---

## 3. Request packet

All kernel-built packets are 26 (`$1A`) bytes, except INIT: 22 (`$16`) from `device=`,
23 (`$17`) at boot. Layout of the common part:

| Offset | Size | Meaning |
|---|---|---|
| +$00 | B | Packet length |
| +$01 | B | Unit number (block devices; 0-based within the driver) |
| +$02 | B | Command code (bit 7 set on remote commands when VERIFY is on, §4.4) |
| +$03 | B | Out: error code low byte (0 = OK) |
| +$04 | B | Out: error code high byte (allowed answers) |
| +$05 | 8 B | Reserved |
| +$0D | B | Command specific |
| +$0E | L | Command specific |
| +$12 | L | Command specific |
| +$16 | L/B | Command specific |

---

## 4. Commands

### 4.1 Standard commands

| Cmd | Name | Inputs | Outputs |
|---|---|---|---|
| 0 | INIT | +$12 L: parameter string (for `device=` drivers: `file\0arg1\0…\0\0`; built-ins and ROM/bound drivers: empty string; at boot: undefined). +$16 B: drive number the first unit will get (1 = A:). | +$0D B: number of units (block). +$0E L: **end address** (first free byte after the resident part). +$12 L (block): address of an array of BPB pointers, one per unit. +$16 B: a block driver may change this to report the boot unit (only honoured for boot-time drivers: boot drive = +$16 − 1). |
| 1 | MEDIA CHECK (block) | +$01 unit, +$0D media byte the kernel has in its DPB | +$0E **B**: 1 = not changed, 0 = unknown, negative (`$FF`) = changed. An error status is treated as "changed". |
| 2 | BUILD BPB (block) | +$01 unit, +$0D media byte, +$12 = 0 | +$12 L: 0 = no new BPB; otherwise the address of a **long containing the BPB address**. |
| 3 | IOCTRL INPUT | +$0E buffer, +$12 count/parameter, +$0D extra byte (0 from IOCTRL handle/drive calls) | driver specific |
| 4 | INPUT | +$0D media byte (block), +$0E buffer, +$12 count (bytes for char, sectors for block), +$16 L start sector (block) | data in buffer |
| 5 | char: NON-DESTRUCTIVE READ | — | +$0D B: next character, without removing it (0 if none for CON). |
| 5 | block: DRIVE CONTROL / STATUS | +$01 unit, +$0D mode (DRVCTRL mode; the kernel uses 9 to query media presence before a media check), +$0E pointer to extra DRVCTRL arguments, +$12 = 0 | +$12 L: if non-zero it is the DRVCTRL result; else +$0D B = status byte. Kernel tests: bit 1 = media inserted (0 → drive treated as empty), bit 3 = write-protected (checked before writes; → error `$700E`). [bits verified as used; names inferred] |
| 6 | INPUT STATUS | — | +$03 = 0 ready, non-zero not ready |
| 7 | INPUT FLUSH | — | — |
| 8 | OUTPUT | as 4 | — |
| 9 | OUTPUT WITH VERIFY | as 4 (used instead of 8 when VERIFY is on) | — |
| 10 | OUTPUT STATUS | — | +$03 = 0 ready, non-zero busy |
| 11 | — | unused by the kernel | built-ins return OK |
| 12 | IOCTRL OUTPUT | as 3 | driver specific |
| 19 | SPECIAL IOCTRL (attr bit 6) | +$01 unit, +$0D media byte, +$12 **W** function code, +$0E L pointer (from IOCTRL modes 12/13) | driver specific |

Built-in dispatch has no bounds check on the command code; a compatible kernel never
issues codes other than those listed. [verified]

### 4.2 BPB (returned by INIT / BUILD BPB)

| Offset | Size | Meaning |
|---|---|---|
| +$00 | W | Bytes per sector — must not exceed the configured sector-buffer size (default 1024); at boot/`device=` time a larger value is **fatal** ("bytes per sector too large"), on media change the kernel raises error `$2007` (invalid media, abort/retry) and retries BUILD BPB. Must be a power of two. |
| +$02 | B | Sectors per cluster (power of two) |
| +$03 | B | Number of FATs (bits 0-6); bit 7 is a flag copied into the DPB (meaning in 20-filesystem) |
| +$04 | W | Reserved sectors |
| +$06 | W | Root directory entries |
| +$08 | W | Total sectors (0 → use +$0C) |
| +$0A | B | Media byte |
| +$0B | B | Sectors per FAT |
| +$0C | L | Total sectors when +$08 = 0 |

Validity: (total − first data sector) / sectors-per-cluster + 3 must be < `$FFF8`, else
the BPB is rejected. DPB derivation is specified in 20-filesystem. [verified]

### 4.3 Kernel use of block commands

* Before using a removable drive: command 5 (+$0D = 9). If "no media" → buffers for the
  drive are invalidated and the access fails. Otherwise command 1; on "changed" (or error)
  → buffers invalidated, command 2, DPB rebuilt. [verified]
* Sector read/write: 4 / 8 / (9 when VERIFY). DISKRED/DISKWRT use the same packets.
* IOCTRL modes 2/3 (drive) and 4/5 (handle) → commands 3 / 12; modes 12/13 → command 19
  (char handle: always; block: only if attribute bit 6). Status modes 6/7 → commands 6/10
  (no retry; d0 = −1 if ready, 0 if not, see 21).
* DRVCTRL → command 5 (+$0D = mode). An internal "drive release" uses mode 7.

### 4.4 Special (remote) block devices (attribute bit 13)

INIT is sent with command **`$40`** instead of 0. Each unit gets a minimal drive entry (no
BPB, no FAT, no buffers). All file-system DOS calls on such a drive are forwarded as a
generic packet: [verified for command ↔ call mapping and register placement; argument
semantics per call are in 20/21]

| +$0D | +$0E | +$12 | +$16 |
|---|---|---|---|
| B arg4 | L arg1 | L arg2 (and **returned value**: after the call d0 := +$12) | L arg3 |

Bit 7 is OR-ed into the command when VERIFY is on. Errors go through §2 retry handling.

| Cmd | Issued by | Arguments (as passed) |
|---|---|---|
| `$40` | INIT | as command 0 |
| `$41` | CHDIR (path check) | +$0E name buffer |
| `$42` | MKDIR | +$0E name buffer |
| `$43` | RMDIR | +$0E name buffer |
| `$44` | RENAME | +$0E old name, +$12 new name |
| `$45` | DELETE | +$0E name buffer |
| `$46` | CHMOD | +$0E name buffer, +$0D attribute |
| `$47` | FILES | +$0E name buffer, +$12 FILES buffer, +$0D attribute |
| `$48` | NFILES | +$12 FILES buffer |
| `$49` | CREATE / NEWFILE | +$0E name, +$12 mode flag, +$16 file-table entry, +$0D attribute |
| `$4A` | OPEN | +$0E name, +$16 file-table entry |
| `$4B` | CLOSE | +$16 file-table entry |
| `$4C` | READ | +$0E buffer, +$12 count, +$16 file-table entry |
| `$4D` | WRITE | +$0E buffer, +$12 count, +$16 file-table entry |
| `$4E` | SEEK | +$12 offset, +$0D mode, +$16 file-table entry |
| `$4F` | FILEDATE | +$16 file-table entry (+$12 date/time) |
| `$50` | DSKFRE | +$0E result buffer |
| `$51` | DRVCTRL | as command 5 |
| `$52` | GETDPB | +$0E DPB buffer |
| `$53` | DISKRED | as command 4 |
| `$54` | DISKWRT | as command 8 (`$D4` when VERIFY) |
| `$55` | IOCTRL special | +$0E pointer, +$12 function code in upper word |
| `$56` | FFLUSH / buffer flush | — |
| `$57` | media check | — (result byte as command 1) |
| `$58` | LOCK | +$0E/+$12/+$16 lock parameters, +$0D mode |

---

## 5. Driver chain

[verified]

* **Head**: the built-in NUL header (inside the kernel). The kernel does not publish its
  address in the work area; programs conventionally locate it by scanning kernel memory
  for the NUL header (attribute `$8024`, name `NUL     `). A compatible kernel should
  keep a NUL header with exactly that attribute and name inside its image. [inferred]
* **Tail**: `$1C1C` holds the last header; new drivers are linked after it.
* **Order**: NUL, CON, AUX, PRN, LPT, CLOCK, boot block drivers, scsidev ROM drivers,
  bound modules, `device=` drivers (02 §4.2).
* **Name look-up** (used for device names in paths and for CLOCK at boot): walk the whole
  chain from NUL, considering **character devices only**, compare the 8-byte name with
  the (space-padded) requested name case-insensitively for ASCII letters (Shift-JIS lead
  bytes are compared exactly with their trail byte); the **last** match wins; −1 if none.
* **Standard-handle rebinding**: whenever a character driver is installed by
  `device=`/bound module/ROM, and also whenever the last handle referring to one of the
  five standard file-table entries (stdin, stdout, stderr, stdaux, stdprn) is closed (the
  entry is then reset by walking the **whole** chain from NUL, so the last qualifying
  driver wins), the kernel updates these entries: attribute bit 0 → stdin entry points at this driver;
  bit 1 → stdout and stderr entries; if the driver's name equals the name in the stdaux
  entry (`AUX`) or stdprn entry (`PRN`), that entry is repointed too. So loading a driver
  named `AUX` replaces the serial device for handle 3. (Entries are 21-file-io FCBs:
  device pointer at +2, name at +$24.) Initial binding: stdin/stdout/stderr = CON,
  stdaux = AUX, stdprn = PRN. [initial binding inferred]

---

## 6. Built-in devices

All built-ins share one interrupt-routine scheme: packet address saved by strategy,
command used as an index into a per-device table, result word written to +3/+4.
`OK` = status 0. `ERR3` = status `$5003` (unknown command; answers Abort+Ignore).

### 6.1 NUL — attribute `$8024`

INIT: end address = kernel's own; every other command 1-12 → OK (reads transfer nothing,
writes discard data).

### 6.2 CON — attribute `$8003` (stdin + stdout)

| Cmd | Behaviour |
|---|---|
| 0 | Set the CRT mode from SRAM (`$ED001D`, IOCS `$10`), read the console window (IOCS `$2E` with −1,−1) and set it with the height limited to 30 lines (bottom line kept for the function-key display), install an ESC-sequence extension hook (IOCS `$37`) that implements `ESC[6n` (cursor position report: the reply `ESC[row;colR` is queued as console input), record the shift-key state (IOCS `$02`). End address = kernel's. |
| 1, 2, 3, 12 | ERR3 |
| 4 | Read +$12 characters into +$0E, **blocking** until each is available. Characters come from the keyboard translation layer (function keys, kanji input, queued ESC replies; see 30). Count 0 → nothing. |
| 5 | +$0D = next character without consuming it, or 0 if none. |
| 6 | OK (always ready) |
| 7 | Discard all pending keyboard input. |
| 8, 9 | Write +$12 bytes from +$0E with IOCS `$20` (_B_PUTC), one by one (escape sequences handled by IOCS). |
| 10 | OK |
| 11 | OK |

### 6.3 AUX — attribute `$8000` (RS-232C)

| Cmd | Behaviour |
|---|---|
| 0 | Set RS-232C mode from SRAM `$ED001A` (IOCS `$30`). |
| 1, 2, 3, 12 | ERR3 |
| 4 | Read +$12 bytes, blocking (IOCS `$32`). |
| 5 | +$0D = **receive-status value** from IOCS `$33` (not the character). |
| 6 | OK |
| 7 | While IOCS `$33` reports data, read and discard (IOCS `$32`). |
| 8, 9 | Write bytes with IOCS `$35`. |
| 10 | IOCS `$34`: non-zero → OK; zero → status `$0001` (busy). |
| 11 | OK |

### 6.4 PRN — attribute `$8000` (printer, with code conversion)

| Cmd | Behaviour |
|---|---|
| 0 | IOCS `$3C` with d1 = −1. |
| 1-7, 12 | ERR3 (input not possible) |
| 8, 9 | Each byte output with IOCS `$3F` (printer output with character-code conversion). [IOCS meaning public] |
| 10 | IOCS `$3D`: non-zero → OK; zero → status `$0001`. |
| 11 | OK |

### 6.5 LPT — attribute `$8000` (printer, raw)

Same as PRN except commands 8/9 use IOCS `$3E` (raw output, no conversion).

### 6.6 CLOCK — attribute `$8008`

| Cmd | Behaviour |
|---|---|
| 0 | End address = kernel's. |
| 4 | +$16 **long**: 0 = date, non-zero = time. Writes 4 bytes (big-endian long) to +$0E: date = IOCS `$54` then `$55` → `(day-of-week << 28) | (year << 16) | (month << 8) | day` (year in full, e.g. 1993); time = IOCS `$56`, `$57` → `(hour << 16) | (minute << 8) | second`. |
| 8, 9 | Reads the 4-byte long at +$0E; date → IOCS `$50` (binary→BCD, negative = invalid) then `$51`; time → `$52`, `$53`. Invalid value → status `$050C` (general error; class < `$10` so treated as abort-only if it ever reached trap #14). |
| others | OK |

Kernel usage: date/time DOS calls build a packet with command 4 or 8, +$0E = pointer to a
4-byte long, **+$12 = 4**, +$16 = 0 (date) or 1 (time), and send it (no retry) to the
device recorded in `$1CB6` at boot. For the *set* calls a non-zero status makes the DOS
call return −1. The *get* calls ignore the status and decode whatever the long contains;
it is pre-loaded with a default (date: `$07C10707`; time: `$000C0500`), which is what
they report if there is no CLOCK device or the driver did not write it. [verified]

### 6.7 Built-in block devices

Two built-in block drivers exist, appended after CLOCK in boot-device order (00 §2 step 6):

* **Floppy driver** — attribute `$4040` (IOCTRL + special IOCTRL), name byte 0 = 4. INIT
  counts the floppy units present via IOCS (up to 4) and returns their BPBs; at floppy
  boot the boot unit is added to +$16. Commands: 1 (IOCS `$4E` status, with a per-unit
  "changed" latch), 2 (looks up the BPB for the media now in the drive; if its media byte differs
  from +$0D, +$12 points at the BPB pointer, else +$12 stays 0),
  3 (copy 12 bytes of drive parameters to +$0E), 4 (IOCS `$46` read), 5 (IOCS `$4E` with
  mode +$0D; mode 1 = eject also sets the changed latch), 8 (IOCS `$45` write),
  9 (write then IOCS `$41` verify, track by track), 12 (accept 6 bytes of parameters),
  19 (+$12 function: −1 → write the 8-byte identifier `DISKdev1` to +$0E; 0 → return the
  current media byte as a word; 1 → copy drive parameter block; 2 → set the changed latch
  from +$0E). Others OK/ERR3. [verified at this level; exact IOCS parameters in evidence]
* **SASI hard-disk driver** — attribute `$0000`. INIT scans SASI IDs 0-15 (IOCS `$47`/`$46`)
  for a sector-0 signature `X68K` and partition entries named `Human68k` (or `Human/NN`,
  NN = cluster-size hint), up to 16 partitions, each becoming a unit; at HD boot the
  booted partition becomes the boot drive. Commands 1, 2, 4, 5, 8, 9 supported; 3 and 12
  → ERR3. [verified at this level]

SCSI drives are not handled by the kernel itself; they come from the SCSI ROM driver
protocol (02 §4.3).
