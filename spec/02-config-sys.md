# 02 — CONFIG.SYS

Every keyword the kernel recognises, its syntax, defaults, limits, error handling and the
order in which the file is processed; how `device=` drivers are loaded and initialised.

Confidence tags: **[verified]**, **[inferred]**, **[public]**. Unless tagged, statements are [verified].

---

## 1. File access and line syntax

* File name: `CONFIG.SYS`, opened with OPEN (read mode) relative to the current drive
  (= boot drive, root directory). If an `exconfig` program exits with code 0 the name used
  for all **later** passes becomes `CONFIG.TMP` (§2 exconfig). If the file cannot be
  opened, a pass is skipped entirely (all its keywords keep their defaults).
* The file is read one byte at a time. A line ends at LF (`$0A`); a CR immediately before
  the LF is removed; byte `$1A` (or end of file) ends the file. There is no line-length
  check in the original (lines are read into a 200-byte buffer) — **a compatible
  implementation should accept at least 199 characters and ignore/truncate the rest**. [verified; recommendation inferred]
* While searching for keywords, TAB characters are converted to spaces.
* **Keyword match**: the keyword must start in the first column (no leading blanks). It is
  compared case-insensitively (each line character is OR-ed with `$20`), then any number of
  spaces may follow, then `=` is required. `files=`, `FILES =`, `Files<TAB>=` match;
  ` files=` and `filesx=` do not.
* **Search model**: for every keyword the kernel rewinds the file and scans from the top;
  the **first** matching line wins and later duplicates are ignored. Exceptions that use
  every matching line in file order: `device`, `program`.
* Lines that match no keyword (including comments, blank lines and unknown keywords) are
  silently ignored. There is no comment syntax as such.

### 1.1 Value syntax helpers

| Helper | Rule |
|---|---|
| number | Leading spaces skipped; decimal digits only; stops at the first non-digit; no digits → 0; no overflow check. |
| next number | After a number, the very next character must be a **single space** (`' '`) for a following number to be parsed (commas are not accepted). |
| on/off | Leading blanks are **not** skipped by the word itself but the separator after `=` is skipped. Case-insensitive: `o`,`n` → on (1); `o`,`f`,`f` → off (0); anything else → error. Characters after the recognised prefix are ignored (`onx` = on). |
| word | Leading spaces skipped; copied up to the next space or end of line. |
| rest-of-line | Leading spaces skipped; copied to end of line, spaces included. |

### 1.2 Error reporting

For every malformed value the kernel prints the keyword followed by a message meaning
"parameter is invalid; using the default" (CR-LF terminated) on the console and continues.
"Default" means the value the setting had before (see each keyword for exceptions). Load
failures print the offending text followed by "could not be registered/started". Fatal
conditions jump to the boot-failure halt (00 §2.1).

---

## 2. Keywords

Defaults come from the kernel's default block (00 §1.1).

| Keyword | Syntax | Default | Limits / behaviour |
|---|---|---|---|
| `files` | `files = n` | 15 | 5 ≤ n ≤ 93. Sets the number of file-table entries (work area `$1C6E` = n + 2). Error → default. |
| `buffers` | `buffers = n [size]` | 20, 1024 | 2 ≤ n ≤ 249. Optional size after **one space**: 1024 ≤ size ≤ 32768 bytes → sector-buffer size (`$1C70`). If n is valid but size is invalid, n is still applied and the size stays default (message printed). A non-space character right after n is an error. Each buffer costs size + 16 bytes. |
| `lastdrive` | `lastdrive = letter` | Z | Only the first non-blank character is used, A-Z case-insensitive. Its index must be ≥ the number of drives already present (built-in drives); otherwise error and LASTDRIVE := number of drives (the first unused letter). Stored in `$1C73`. Drivers loaded later that create drives beyond LASTDRIVE silently raise it; creating more than 26 drives is fatal. |
| `scsidev` | `scsidev = on\|off` | on | When on, after the file tables are built the kernel looks for a SCSI BIOS ROM: external board (signature `SCSIEX` at `$EA0044`) else internal (`SCSIIN` at `$FC0024`). If found and it is not the ROM the system booted from, the ROM driver descriptor at `$EA0020` resp. `$FC0000` is installed (§4.3). |
| `exconfig` | `exconfig = program [args]` | none | Rest-of-line. Run during boot after scsidev and bound modules, before pass 2 (§3). The program gets a 512-byte kernel-allocated block: environment at its start containing only `path=\;\sys;\bin;\basic2;\etc;\shell`, command-line buffer at +128, user stack top at +512. Loaded with EXEC mode 2 then run with EXEC mode 0 (cursor shown while it runs). If it stays resident (exit code ≥ `$10000`, i.e. KEEPPR) → message "exconfig program cannot stay resident, reset" and the system **hangs**. If it exits with low word 0, the kernel switches to `CONFIG.TMP` for the remaining passes. Any other exit code or a load failure → continue with the current file. The block is freed afterwards. |
| `ctty` | `ctty = anything` | — | **Value ignored**: the mere presence of the keyword makes standard handles 0, 1, 2 (in both the active and the default handle tables) refer to the AUX file entry, i.e. console I/O goes to the serial port. |
| `romdb` | `romdb = anything` | — | **Value ignored** (even `off`): if present, the ROM debugger is started at this point. ROM version (IOCS `$8F`) below `$12920101` → call `$FE0000`; otherwise, if the long at `$FF0008` is below `$1000000`, call that address with a6 = `$1000`. Registers are preserved around the call. |
| `title` | `title = file` | `TITLE.SYS` | Word. Empty value → no file (built-in title). See §2.1. |
| `key` | `key = file` | `KEY.SYS` | Word. File is read (up to 712 bytes) into the function-key definition table (same layout as FNCKEY full-table get/set, see 30). Missing file → keys unchanged, no message. |
| `uskcg` | `uskcg = file` | `USKCG.SYS` | Word. **An empty value disables** user-defined characters. When non-empty, external-character font buffers are always reserved (six areas of `$1780`,`$1780`,`$2000`,`$34E0`,`$34E0`,`$6000` bytes, each cleared and registered with IOCS `$38`, d1 = address, d2 = 0..5) — even if the file does not exist — then the file is read (≤ `$126A2` bytes) and glyphs are defined with IOCS `$0F`: after a `$22`-byte header, records `code.w + bitmap`; first section 8-dot font type (bitmap `$10` bytes if code ≥ `$F000`, else `$20`), terminated by code `$FFFF`; second section 12-dot type (bitmap `$30` or `$48` bytes). Codes < `$8000` are byte-swapped before use. Reading stops when the data runs out. [verified; IOCS meanings inferred] |
| `fflush` | `fflush = on\|off` | on | `$1CBA`. Error → unchanged. |
| `off` | `off = letters` | none | Letters separated by space, TAB or comma, case-insensitive: `c` disables ^C (break), `n` ^N, `p` ^P, `q` ^Q, `s` ^S special handling (the stored key code becomes `$01xx`, which no keyboard character matches). Unknown letter → error message; letters before it remain applied, the rest is ignored. |
| `break` | `break = on\|off\|kill` | **off** | `on` → 1, `kill` (`k`,`i`,`l`,`l`) → 2, `off` → 0. **If the keyword is absent or invalid the setting is forced to 0 (off)**, overriding the default block. Becomes active only when the shell is launched (during boot break mode is 2). |
| `verify` | `verify = on\|off` | off | `$1C10`. Error → unchanged. |
| `newfat` | `newfat = 0\|2` | 0 | Only the numbers 0 and 2 are accepted, else error (unchanged). Stored in `$1C0B` and in the FAT code. Effect: see 20-filesystem / QUESTIONS. |
| `dirsch` | `dirsch = on\|off` | on | Enables directory-position caching in DPBs (when on, two DPB cache fields are cleared at DPB creation). Error → unchanged. |
| `bell` | `bell = file` | none | First word. File read (≤ 65535 bytes) into memory permanently reserved at the boot allocation pointer (size rounded up to even) and registered with IOCS `$39` (d1 = address, d2 = length). Open/read failure → error message. [IOCS meaning inferred: bell sound data] |
| `share` | `share = files locks` | 0 0 | 0 ≤ files ≤ 93, then one space, 1 ≤ locks ≤ 266. Reserves `files` entries of (locks × 12 + `$5C`) bytes (first long of each cleared); `$1C40` = table, `$1C76/$1C78/$1C7A` = values/entry size. files = 0 → no table (sharing disabled). Any error → defaults (0 0, no table) + message. |
| `common` | `common = kbytes` | 0 | 0 ≤ k ≤ 1024. Reserves k × 1024 bytes for the COMMON area (`$1C44` start = `$1C48` current, `$1C4C` limit; first long cleared). Error → default + message. |
| `process` | `process = n level tick` | 0 0 0 | n ≤ 32; level: values < 2 become 2, must be < 256; tick: 1..100. Separators: single spaces. Any error → defaults + message. Background processing is enabled only if 2 ≤ n ≤ 32 (n = 0 or 1 silently disables it); it also requires the timer-D interrupt to be free (else disabled silently). Details in 12-background. |
| `envset` | `envset = size [file]` | none | 512 ≤ size ≤ 65535. Allocates (MALLOC) the kernel's environment block of `size` bytes, initialised to an empty environment. If a file name follows (after spaces), each line of the file (TABs preserved) is split at the first `=` and registered with SETENV(name, current process, value). A line without `=` (including an empty line) or a failing SETENV prints that line followed by "could not be registered as an environment variable". Size out of range, MALLOC failure or file-open failure → envset error message (an already-allocated block is kept). |
| `program` | `program = command [args]` | none | Rest-of-line. **Every** `program=` line, in file order, after envset: EXEC mode 2 (split/search), then EXEC mode 0 (run) with the kernel's environment and the kernel's 240-byte command-line buffer. Failure of either step → "<line> could not be started". The program's exit code is otherwise ignored; it may stay resident with KEEPPR. |
| `shell` | `shell = command [args]` | `COMMAND /P` | Rest-of-line, copied into the shell buffer (≤ 253 bytes) used by the shell loop (00 §4). |
| `device` | `device = file [args]` / `device = [ROMn]` / `device = [ROM$hex]` | — | §4. Every line, in file order. |

Keywords not in this table are ignored. Notably, there is no `fcbs`, `stacks`, `country`,
`install`, `rem` or `shell` argument parsing beyond the above.

### 2.1 TITLE file

* If the file cannot be opened: print the built-in title text.
* If the first byte is non-zero (**text title**): the whole file (≤ `$10044` bytes) is
  printed with PRINT, **except its last byte** (expected to be `$1A`) which is replaced by
  NUL. [verified]
* If the first byte is 0 (**graphic title**), offsets: [verified for offsets; visual result inferred]

| Offset | Size | Use |
|---|---|---|
| +$00 | B | 0 = graphic marker |
| +$01 | B | Display mode byte m. When m = 0 the function-key line is hidden first (CONCTRL mode 14, value 3); then CONCTRL mode 2 with value m. m ≠ 0 also causes the cursor to be re-enabled at the end and a key-line refresh after KEY loading. |
| +$02 | W | Colours: low byte = text colour for the first image, high byte = text colour for the second image (0 = no second image). |
| +$04 | W | Text palette entry 4 (IOCS `$13`). |
| +$06 | W | Text palette entry 8 (IOCS `$13`). |
| +$08 | 52 B | NUL-terminated command line that **replaces the shell command** (`shell=` is processed later and overrides it again). |
| +$3C | W,W | x, y for IOCS `$1B` (text put). |
| +$40 | … | Pattern data (IOCS `$1B` format). After the first put, the 64 KB following the pattern header are filled with `$FF` and, if the high colour byte is non-zero, the pattern is put again in that colour. |

  Afterwards: text colour 3, cursor on.

---

## 3. Processing order

The file is opened and closed separately for each pass. [verified]

| Pass | When | Keywords, in this order |
|---|---|---|
| 1 | Before the file tables are built | `files`, `buffers`, `lastdrive`, `scsidev`, `exconfig` (name only), `ctty`, `romdb` (executes immediately) |
| — | | memory check (below), file tables built, scsidev ROM drivers, bound modules, exconfig execution |
| 2 | | `title`, `key`, `uskcg` (names), `fflush`, `off`, `break`, `verify`, `newfat`, `dirsch`, `bell` (loads), `share`, `common`, `process` |
| — | | USKCG load, TITLE display, KEY load |
| 3 | | every `device` line |
| — | | kernel end fixed, CTRLVC set |
| 4 | | `envset`, every `program` line, `shell` |

**Memory check after pass 1** (fatal if violated):
`(bufsize + 16) × buffers + (files − 3) × 98 + 65536 + allocation_pointer < memory_end`.
After every later permanent reservation (bell, share, common, uskcg buffers, each
driver) the kernel requires `allocation_pointer + 65536 < memory_end`, else fatal. [verified]

---

## 4. `device=` driver loading

### 4.1 File drivers: `device = file [args]`

[verified]

1. The value is split into NUL-separated words in place (runs of spaces collapse; the list
   ends with an extra NUL): `file\0arg1\0arg2\0\0`.
2. The driver file is loaded with EXEC mode 3 (load only) at the boot allocation pointer,
   with the memory end as limit, **forcing X-file format** (file-type selector 3 in the
   top byte of the name pointer — so `.SYS` files must be X-format; see 11). Load error →
   "<file> could not be registered", continue with the next line.
3. If the load reports a size of 0 the line is skipped silently. [inferred meaning of 0]
4. An INIT request (03 §4.1) is sent to the **first header** at the load address:
   command 0 (or `$40` if the header's attribute bit 13 is set), parameter pointer =
   the word list of step 1 (it lives in a temporary buffer: drivers must copy what they
   need during INIT), drive number = number of drives + 1.
5. If INIT returns an error (status byte non-zero) → "could not be registered"; nothing
   is linked and the memory is not consumed.
6. The returned end address E (packet `+$0E`) must satisfy E + 65536 < memory end and
   E ≥ header address + 34; otherwise **fatal**.
7. The allocation pointer := E; the driver is linked after the current chain tail.
8. For each header in the file's own chain (following `next` until a negative value):
   * character device: standard-handle rebinding (03 §5);
   * block device with a non-zero unit count in the INIT reply: DPBs are built from the
     BPB pointer array returned at packet `+$12` (03 §4.1) and the units are assigned the
     next drive letters (fatal if a BPB's sector size exceeds the buffer size, or if more
     than 26 drives would exist). **Only the first header receives INIT; additional block
     headers in the same file are set up using the first header's INIT reply.**
9. The chain tail becomes the last header of the file's chain.

### 4.2 Order relative to other drivers

Final chain order: NUL, CON, AUX, PRN, LPT, CLOCK, built-in/ROM boot block drivers,
scsidev ROM drivers, bound modules, `device=` drivers in file order. Name look-ups
(03 §3) return the **last** match, so a later driver with the same name as a built-in one
wins for OPEN by name. [verified for order]

### 4.3 ROM drivers: `device = [ROMn]` / `[ROM$hex]`

`[ROM` is matched case-insensitively. `n` is one decimal digit selecting a descriptor
address, or `$` followed by hex digits gives it directly; the next character must be `]`.
[verified]

| n | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| address | `$BFFFFC` | `$FE4FFC` | `$EE0000` | `$EE4000` | `$EE8000` | `$EEC000` | `$EF0000` | `$EF4000` | `$EF8000` | `$EFC000` |

Descriptor protocol at address A (read with bus-error protection):
* long at A = P; P must be greater than A;
* bytes P−8..P−1 = `Human68k`;
* long at P−16 = driver-install routine R.

The kernel repeatedly calls R with a1 = allocation pointer and d2 = state (0 on the first
call; whatever R left in d2 afterwards). R builds one device driver at a1 and returns; d2 =
−1 means "no (more) drivers". For each driver built: INIT with an empty parameter string;
if INIT fails, R is simply called again; otherwise steps 6-9 of §4.1 apply. The current
drive is not changed by these drivers. Malformed text, bus error, wrong signature or no
driver produced → "could not be registered".
At boot from a SCSI ROM the same protocol is used for the boot ROM, and there the INIT reply's
drive number **does** set the boot drive. [verified]

### 4.4 Bound modules

Before pass 2 the kernel tries to load module 1, 2, 3, … of the file `Human.sys` (EXEC
mode 3 with the module number in bits 8-15 of the mode word, X format forced) and installs
each as a driver (empty parameter string, same steps as §4.1) until a load fails. This
supports drivers attached to the kernel file with BIND. [verified]
