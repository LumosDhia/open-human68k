# 40 — Miscellaneous DOS calls

Scope: date/time ($FF27 GETTIM2, $FF28 SETTIM2, $FF2A GETDATE, $FF2B
SETDATE, $FF2C GETTIME, $FF2D SETTIME), $FF20 SUPER, $FFF6 SUPER_JSR,
$FF25 INTVCS / $FF35 INTVCG, $FF30 VERNUM, $FF2E VERIFY / $FF84 VERIFYG,
$FF33 BREAKCK, $FF34 DRVXCHG, $FF85 COMMON, $FFAB OS_PATCH, $FFF5
INDOSFLG, $FFF7 BUS_ERR, $FFF3 DISKRED / $FFF4 DISKWRT, $FFAA (alias
$FF7A) FFLUSH-mode.

Conventions: arguments on the caller's stack, result in d0.l, all other
registers preserved (see `01-dos-dispatch.md`). "Error −14" = $FFFFFFF2
(invalid parameter), "−15" = $FFFFFFF1 (invalid drive), "−8" =
$FFFFFFF8 (out of memory), "−26" = $FFFFFFE6 (already in supervisor
mode), "−2" = $FFFFFFFE (not found). Handlers that do not load d0 return
the call-number residue left by the dispatcher (low byte of the call
number, zero-extended) **[verified]**; such cases are marked below.

$FF50–$FF5F and $FF70–$FF7F are aliases of $FF80–$FF8F and $FFA0–$FFAF
respectively (see 01-dos-dispatch). Unimplemented numbers in this area
($FF14–$FF16, $FF38, …) return −1.

---------------------------------------------------------------------------

## 1. Date and time

### 1.1 Mechanism **[verified]**
The kernel does not call IOCS for the clock. It sends request packets to
the **CLOCK character device**: at boot (before CONFIG.SYS `DEVICE=`
lines are processed) it walks the device chain from NUL and remembers the
*last* character device whose 8-byte name matches `CLOCK   ` (case-
insensitive). If none is found it remembers "none". The lookup is not
repeated, so a CLOCK driver installed by CONFIG.SYS is never used by these
calls (see QUESTIONS).

Request packet (26 bytes): +0 = $1A, +2 = command (4 = read, 8 = write),
+14 (long) = pointer to a 4-byte buffer, +18 (long) = 4, +22 (long) =
**0 for date, 1 for time**. +1 and +13 are not initialised. The driver is
called (strategy then interrupt) without the device-error handler. Result:
success iff request byte +3 is 0 afterwards; otherwise the DOS call
returns −1.

4-byte payloads (big-endian long):

| Kind | Layout |
|------|--------|
| date | bits 31–28 day of week (0 = Sunday), bits 27–16 year (full, e.g. 1993), bits 15–8 month (1–12), bits 7–0 day (1–31) |
| time | bits 23–16 hour, 15–8 minute, 7–0 second (binary); bits 31–24 zero |

The built-in CLOCK driver implements read with IOCS `_DATEGT`($54)
+ `_DATEBIN`($55) / `_TIMEGT`($56) + `_TIMEBIN`($57), and write with
`_DATEBCD`($50) + `_DATESET`($51) / `_TIMEBCD`($52) + `_TIMESET`($53);
when `_DATEBCD`/`_TIMEBCD` returns a negative value (invalid input) it
fails the request with status $050C (so the DOS call returns −1). **The
kernel itself performs no range validation**; all validation is the
IOCS conversion routine's.

If there is no CLOCK device, reads return the defaults below and writes
return −1.

### 1.2 Calls

| Call | In | Out d0.l |
|------|----|----------|
| $FF27 GETTIM2 | — | time payload `$00HHMMSS` (binary). Default without device: $000C0500 (12:05:00). |
| $FF28 SETTIM2 | long `$00HHMMSS` | 0, or −1 |
| $FF2C GETTIME | — | MS-DOS packed time: bits 15–11 hour, 10–5 minute, 4–0 second/2 (seconds truncated); upper word 0. |
| $FF2D SETTIME | word packed time | 0 or −1. Converted to `$00HHMMSS` with seconds = 2 × (bits 4–0). |
| $FF2A GETDATE | — | bits 18–16 day of week (0–6); bits 15–9 year−1980, 8–5 month, 4–0 day (MS-DOS packed date). Default without device: payload $07C10707 → 1985-07-07, day-of-week 0. |
| $FF2B SETDATE | word packed date | 0 or −1. Converted to payload with year = 1980 + bits 15–9, day-of-week field 0 (the driver/IOCS recomputes it). |

GETDATE edge case **[verified]**: the year is taken as payload bits
27–16 minus 1980 without range check; a year outside 1980–2107 corrupts
the upper bits of the result.

---------------------------------------------------------------------------

## 2. SUPER ($FF20)

In: long `ssp`. Out: d0.l. **[verified]**

The DOS-call exception frame is 6 bytes on a 68000 and 8 bytes (format
word) on 68010 and later; the kernel's per-call stack usage including the
frame is $42 bytes (68000) or $44 bytes (68010+).

* `ssp` = 0, caller in **user** mode: the whole kernel stack frame of this
  call is moved so that, after the call returns, **SSP = the caller's
  current USP** and the CPU is in **supervisor** mode (S bit set in the
  returned SR). USP is not changed (so after the call SSP = USP).
  d0 = the caller's former SSP (the SSP value just above the exception
  frame, i.e. what SSP was before the F-line trap).
* `ssp` = 0, caller already in supervisor mode: nothing changes,
  d0 = −26.
* `ssp` ≠ 0 (either mode): the frame is moved so that after the call
  **SSP = `ssp`**, and the S bit is cleared in the returned SR (CPU in
  user mode; a7 is then the unchanged USP). d0 = `ssp` − $42 (68000) or
  `ssp` − $44 (68010+) — a meaningless value; programs ignore it.
  No check is made that the caller was in supervisor mode.

The typical pattern `old = SUPER(0); … SUPER(old);` therefore works.

## 3. SUPER_JSR ($FFF6)

In: long `addr`. Out: whatever the routine leaves. **[verified]**

Handled directly in the dispatcher (not through the DOS vector table;
INTVCS($FFF6) has no effect). The routine at `addr` is entered by a
subroutine call **in supervisor mode** with **all registers d0–d7/a0–a6
equal to the caller's values at the DOS call** (d0 included), a7 = the
supervisor stack. The INDOS count is *not* incremented. When the routine
executes RTS, the kernel returns from the F-line exception with the SR
of the original caller (so the routine's condition codes are lost and the
caller's mode is restored) and with every register as the routine left it
(the routine's d0 is the call's result).

## 4. INTVCS ($FF25) / INTVCG ($FF35)

INTVCS in: word `vecno`, long `addr`. Out: d0.l = previous contents.
INTVCG in: word `vecno`. Out: d0.l = current contents. **[verified]**

Vector address computed from `vecno`:

| vecno | Location |
|-------|----------|
| $0000–$00FF | 68000 exception vector, address `vecno`×4 ($000–$3FC) |
| $0100–$01FF | IOCS call vector, address `vecno`×4 ($400–$7FC) |
| ≥ $0200 | DOS call vector table: $1800 + (`vecno` AND $FF)×4. Intended range $FF00–$FFFF; any value ≥ $200 aliases into it (e.g. $0225 = $FF25). |

INTVCS stores `addr` without validation. Side effects:

| Location set | Additional effect |
|--------------|-------------------|
| $1BC0 (vecno $FFF0, EXITVC) | Also stored in the current process's PSP at +$14 (relative to the memory-block header, see 11-process). |
| $1BC4 (vecno $FFF1, CTRLVC) | Stored in PSP +$18 **and also into $1BC8 (ERRJVC) and PSP +$1C** — quirk: setting CTRLVC overwrites ERRJVC with the same address. Then the "abort context" is captured (next row). |
| $1BC8 (vecno $FFF2, ERRJVC) | Stored in PSP +$1C. Abort context captured: the SR at the time of the (outermost) current DOS call → word $1C60 and PSP +$46; the supervisor-stack address just above that call's 6-byte 68000 exception frame → long $1C62 and PSP +$48 (on 68010+ this points at the format word, 2 bytes short; reproduced as is). |
| $00A8, $00AC, $00B0, $00B4, $00B8 (vecno $2A–$2E: trap #10–#14) | Also stored in PSP +$4C, +$50, +$54, +$58, +$5C respectively. |
| others | none |

Why: the PSP holds the per-process copy of these vectors. Whenever a
process becomes current again (its child exits, or SETPDB), the kernel
reloads $1BC0–$1BC8, $1C60/$1C62 and the five trap vectors from its PSP;
updating the record keeps a vector set through INTVCS in force after a
child terminates (11-process). The abort context is what the kernel
restores (SR, SSP) before jumping to ERRJVC when the user chooses "abort"
in the device-error dialog; that jump is made with d0 = $00004000. A
Ctrl-C abort jumps to CTRLVC with d0 = $00002000 (30-char-io §4.3).

DOS-vector hooks: a handler installed for $FF00–$FFF4 is called by the
dispatcher with a subroutine call in supervisor mode, a6 = pointer to the
caller's arguments, d0.l = d1.l = call number AND $FF, INDOS incremented;
it returns its result in d0 with RTS and may clobber d1–d7/a0–a6 (the
dispatcher restores them). Entries $FFF5–$FFFF of the table are ignored
by the dispatcher (those calls are decoded before the table lookup), so
INTVCS on them changes memory but not behaviour **[verified]**.

## 5. VERNUM ($FF30)
Out: d0.l = **$36380302** ("68" in the high word, version 3.02 in the low
word: major in bits 15–8, minor in bits 7–0). **[verified]**

## 6. VERIFY ($FF2E) / VERIFYG ($FF84)
VERIFY in: word `flag` — stored verbatim in the word at **$1C10**.
Out: d0 not set (residue $0000002E) **[verified]**.
VERIFYG: out d0.l = word at $1C10, zero-extended.
Effect: while $1C10 ≠ 0, block-device writes use driver command 9 (write
with verify) instead of 8, and extended-sector writes use $D4 instead of
$54 (see 20-filesystem / 03-device-drivers). Initial value from CONFIG
`VERIFY=` (default 0).

## 7. BREAKCK ($FF33)
In: word `arg`. Out: d0.l. **[verified]**

| arg | Meaning | Return |
|-----|---------|--------|
| $0000 | set break mode OFF | new mode (0) |
| $0001 | set break mode ON | 1 |
| $0002 | set break mode KILL | 2 |
| $00FF, $FFFF | query | current mode |
| $0003–$00FE | — | −14 |
| $0n00 (n = 1–5) | disable control key n | previous state of key n: 1 = was enabled, 0 = was disabled |
| $0n01 | enable control key n | previous state |
| $0nFF | query control key n | current state |
| $0n02–$0nFE | — | −14 |
| $0600–$FFFE | — | −14 |

Mode is the byte at **$1C12** (meanings in 30-char-io §4.1).
Key n: 1 = break (Ctrl-C, word $1CBC), 2 = printer-echo-off (Ctrl-N,
$1CBE), 3 = printer toggle (Ctrl-P, $1CC0), 4 = resume (Ctrl-Q, $1CC2),
5 = pause (Ctrl-S, $1CC4). "Disabled" = high byte of that word is 1,
"enabled" = 0; enabling/disabling writes only the high byte (the key
code in the low byte is kept). Only bit 0 of the high byte is looked at
when reporting.

## 8. DRVXCHG ($FF34)
In: word `drv_a`, word `drv_b` (1 = A:, …; 0 = current drive).
Out: d0.l. **[verified]**

The kernel keeps a 26-byte logical→physical drive map at **$1C7E**
(entry i = physical drive index used when the program names drive i,
0-based); every drive-number argument of every DOS call is translated
through it.

* If the two words together form the long $FFFFFFFF: d0 = the map entry
  of the current drive *before* the reset (0-based, zero-extended); then
  the map is reset to the identity (entry i = i, all 26 entries).
* Otherwise each argument is converted to a 0-based index (0 → current
  drive from byte $1C15); if either index (compared as an unsigned
  byte) exceeds the last-drive index (byte $1C73) → −15. Otherwise the
  two map entries are swapped and d0 = 0.

Quirk: only the low byte of the 0-based index is range-checked but the
full word is used as the table index; arguments ≥ $101 can therefore
address beyond the table. A compatible kernel may reject them instead.

## 9. COMMON ($FF85)

### 9.1 Common area
A memory area reserved by CONFIG `COMMON=` (see 02-config-sys) for named
blocks shared between programs. Work-area pointers **[verified]**:

| Address | Meaning |
|---------|---------|
| $1C44 | start of the common area (0 = no common area) |
| $1C48 | end of the used part (next free byte) |
| $1C4C | limit (end of the area) |

The used part is a packed sequence of entries:

| Offset | Size | Meaning |
|--------|------|---------|
| +$00 | long | L = size of the rest of the entry; next entry at +4+L. L = (datasize + $1D) AND NOT 1. |
| +$04 | 12 bytes | name; NUL-terminated if shorter than 12, zero padded |
| +$10 | long | data size (bytes) |
| +$14 | long | lock offset |
| +$18 | long | lock length |
| +$1C | long | lock owner (process id as given to mode 3; 0 = unlocked) |
| +$20 | … | data |

Name matching: up to 12 characters; ASCII letters compare case-
insensitively, Shift-JIS double-byte characters compare exactly, a NUL in
the stored name matches only the end of the caller's name.

### 9.2 Call
In: word `mode`, long `name`, then for modes 1–4: long `pos`, long `p4`,
long `len`. Out: d0.l. **[verified]**

Common errors: no common area → −1 (modes 0,1,3,4,5); name not found →
−2 (modes 0,1,3,4,5); mode ≥ 6 → −14; modes 1–4 with `pos` < 0 or `len`
< 0 (signed) → −14.

"Lock conflict" for modes 1 and 2: the entry's owner is non-zero, owner −
$10 ≠ the current process's PSP block address (i.e. owner ≠ GETPDB()),
and the byte range [pos, pos+len) overlaps [lock offset, lock offset +
lock length) → −14.

| mode | Arguments | Action | Return |
|------|-----------|--------|--------|
| 0 | name | — | data size |
| 1 read | pos, p4 = buffer, len | lock check; pos > size → −14; copy min(len, size−pos) bytes from data+pos to buffer | bytes copied |
| 2 write | pos, p4 = buffer, len | **Not found**: if pos ≠ 0 → −14; create a new entry at the end ($1C48) holding `len` bytes from buffer (lock fields 0); if it would pass $1C4C → −8. **Found**: lock check; pos > size → −14. len = 0: truncate data to `pos` bytes (entry shrunk, later entries moved down, $1C48 reduced), return 0. pos+len > size: grow the entry to pos+len (later entries moved up; −8 if past $1C4C), then copy. Else overwrite in place. | len (bytes written) |
| 3 lock | pos, p4 = owner id, len | if the entry is already locked (any of the three lock fields non-zero) → −14; else store pos, len, owner | 0 |
| 4 unlock | pos, p4 = owner id, len | the three values must equal the stored ones exactly, else −14; clears them | 0 |
| 5 delete | name | if owner ≠ 0 and owner ≠ (GETPDB() − $10) → −14; remove entry, close the gap | 0 |

Note: mode 2 on a missing name with no common area at all fails with −8
(the pointers are 0). Lock ranges are only enforced against processes
other than the owner, and only by modes 1, 2 and 5.

Quirk **[verified]**: "is the caller the owner" is computed differently
by modes 1/2 (owner must equal the GETPDB() value, i.e. PSP block address
+ $10) and by mode 5 (owner must equal the PSP block address itself,
GETPDB() − $10). A program that locks with its GETPDB() value can read
and write the locked range itself but cannot delete the entry until it
unlocks it.

## 10. INDOSFLG ($FFF5)
Out: d0.l = **$00001C08** — the address of the INDOS area **[verified]**:

| Address | Size | Meaning |
|---------|------|---------|
| $1C08 | word | DOS nesting count (0 = not inside DOS) |
| $1C0A | byte | low byte of the call number of the outermost active DOS call (0 when idle) |

Decoded in the dispatcher before the vector table (not hookable).

## 11. BUS_ERR ($FFF7)
In: long `src`, long `dst`, word `size`. Out: d0.l. **[verified]**
Copies one item of `size` bytes from `src` to `dst` with the interrupt
mask raised to 7 and a temporary bus-error handler, to probe whether
addresses respond.

| Result | Meaning |
|--------|---------|
| 0 | read and write succeeded |
| 1 | bus error on the write to `dst` |
| 2 | bus error on the read from `src` |
| −1 | `size` not 1, 2 or 4, or (size 2/4) `src` or `dst` odd |

Previous bus-error vector and SR are restored afterwards. Not hookable
(decoded in the dispatcher).

## 12. DISKRED ($FFF3) / DISKWRT ($FFF4)
In: long `buf`, word `drive` (0 = current, 1 = A:, …, mapped through
DRVXCHG), then `sector` and `count`:
* `buf` bit 31 = 0 ("short form"): word `sector`, word `count`;
* `buf` bit 31 = 1 ("long form"): long `sector`, long `count`; the
  pointer is passed on unchanged (the address bus ignores the top byte on
  24-bit machines).
Out: d0.l = 0 or negative error. **[verified unless noted]**

* The drive must be a local block device (its current-directory/drive
  table entry has type $40); otherwise −15. Drive-number errors from the
  usual drive validation are returned as is.
* Short form is accepted only if the drive's DPB bytes-per-sector word
  (DPB +$0A, 20-filesystem) equals 1024; otherwise −15.
* Long form, DPB +$0A ≠ 0: same path as short form with 32-bit values.
* Long form, DPB +$0A = 0: one direct driver request: command $53 (read)
  or $54 (write; $D4 when VERIFY is on), +1 unit (DPB +1), +13 media byte
  (DPB +$1A), +14 buffer, +18 count, +22 start sector; device errors go
  through the abort/retry/ignore handler; returns the count field (+18)
  after the call.
* Otherwise the transfer goes through the kernel's sector-I/O module
  (OS_PATCH slot 1, entries at offsets $4E (read) / $54 (write)); short-
  form DISKWRT first runs the kernel's per-drive buffer-invalidate step
  (long-form DISKWRT does not — quirk) [verified that the step is skipped;
  its exact semantics belong to 20-filesystem].

## 13. FFLUSH mode ($FFAA, alias $FF7A)
In: word `mode`. Out: d0.l = previous mode (byte at $1CBA, zero-
extended). If `mode` ≠ $FFFF, the low byte is stored at $1CBA.
**[verified]** $1CBA ≠ 0 enables FFLUSH ($FF0D) (flush all buffers,
discard pending cooked console input, per-drive media handling — see
21-file-io); $1CBA = 0 makes FFLUSH a no-op returning 0. Initial value 1,
CONFIG `FFLUSH=` overrides.

## 14. OS_PATCH ($FFAB)
In: word `w`, long `addr`. Out: d0.l. **[verified]** Undocumented
interface for replacing internal kernel modules.

Low byte of `w` selects a slot (1–4, else −14); high byte is a sub-
function. Each slot holds a pointer to a **module**: a table of 6-byte
`JMP abs.l` entries (entry k at offset 6k). Kernel calls into a module
pass a4 = module base and a5 = a slot-specific table of kernel service
entry points.

| Slot | Used for [inferred from call sites] | Per-file reset when replaced |
|------|---------------------------------------|------------------------------|
| 1 | disk sector I/O and buffer cache (DISKRED/DISKWRT, buffer flush) | long at file-object +$18 cleared |
| 2 | file-object level cache | longs at file-object +$44…+$5C set to −1 |
| 3 | file-system operation hooks (create/delete/rename/directory paths) | none |
| 4 | name/device resolution (open, device lookup) | none |

Behaviour:
* If `addr` = 0 or the high byte of `w` ≠ 0: call entry +0 of the current
  module of that slot with d1.w = `w` − slot (i.e. high byte unchanged,
  low byte 0) and d2 = `addr`; return its d0. (The built-in modules'
  entry +0 returns −1.)
* Otherwise: for slots 1 and 2 apply the per-file reset to every file
  object (the internal one and all FILES= entries); call entry +$0C of the
  old module (shutdown/flush); if `addr` = −1 re-install the old module,
  else install `addr`; call entry +$06 of the (new) module (initialise);
  return the **old module pointer**.

The CON driver's CTRL+F5 calls OS_PATCH($0F03,0), ($0F02,0), ($0F01,0)
(sub-function $0F of slots 3, 2, 1) after FFLUSH.

The module entry lists are kernel-internal; a compatible kernel needs to
support OS_PATCH only if it wants to run third-party modules written for
it (see QUESTIONS).
