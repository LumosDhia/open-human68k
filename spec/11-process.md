# 11 — Processes: PSP, EXEC, EXIT, KEEPPR, vectors, environment

Scope: the process management block ("PSP"), EXEC $FF4B (all modes and the
X/R/Z executable formats), EXIT $FF00, EXIT2 $FF4C, KEEPPR $FF31, WAIT $FF4D,
PSPSET $FF26, GETPDB $FF81 / SETPDB $FF80 (aliases $FF51/$FF50), GETENV $FF83 /
SETENV $FF82 (aliases $FF53/$FF52), the EXITVC/CTRLVC/ERRJVC vectors
($FFF0–$FFF2) and what happens to them around child processes.

All DOS calls take arguments on the caller's stack (first argument at the
lowest address) and return d0; see `01-dos-dispatch.md`. Memory-block details
are in `10-memory.md`.

Tags: **[verified]** read from the binary, **[inferred]** deduced,
**[public]** public documentation only.

---

## 1. Concepts and system variables

* A **process** is identified by the address of its memory block header
  (`B`). The **PSP pointer** used by GETPDB/SETPDB/PSPSET and by programs is
  `B + $10`. Internally the kernel keeps a single "current process" variable
  holding `B`. [verified]
* The process management block occupies `B+$00 .. B+$FF`; the first 16 bytes
  are the ordinary memory-block header. A loaded program's code starts at
  `B + $100`. [verified]
* The root process is the kernel itself; its block is the first block of the
  memory chain (`prev = 0`). Its PSP environment field holds the system
  environment allocated from CONFIG.SYS `envset` (see `02-config-sys.md`).
  Its `end` field doubles as the **supervisor-area boundary** used by EXEC and
  Ctrl-C (see §5.6). Its `$80` path is `"<bootdrive>:\"` and `$C4` name is
  `"HUMAN.SYS"`. [verified]

| Address | Size | Meaning |
|---|---|---|
| `$1BC0` | long | Live EXITVC (DOS-call vector slot for $FFF0). [verified] |
| `$1BC4` | long | Live CTRLVC (slot for $FFF1). [verified] |
| `$1BC8` | long | Live ERRJVC (slot for $FFF2). [verified] |
| `$1C08` | word | InDOS nesting counter (cleared by EXIT/KEEPPR/aborts). [verified] |
| `$1C20` | long | Root process block address. [verified] |
| `$1C28` | long | Address of the kernel's "current process" variable (a long holding `B` of the current process). [verified] |
| `$1C60` | word | Live "abort SR" (used by the ERRJVC abort path). [verified] |
| `$1C62` | long | Live "abort SSP". [verified] |
| `$1CAE` | long | Last termination code (returned by WAIT). [verified] |

The DOS-call vector table lives at `$1800 + 4×(call & $FF)`; `$1BC0..$1BC8`
are its entries for $F0..$F2. INTVCS/INTVCG with numbers $FFF0–$FFF2 access
them (see §7). [verified]

---

## 2. Process management block (PSP) layout [verified unless noted]

Offsets from the block header `B`. (Offsets relative to the PSP pointer are
these minus $10.)

| Off | Size | Field | Written by / meaning |
|---|---|---|---|
| `$00` | long | prev block | Memory header (`10-memory.md`). |
| `$04` | long | parent | Owner = parent process block. High byte `$FF` after KEEPPR. |
| `$08` | long | end | End of the block's used area. |
| `$0C` | long | next block | Memory header. |
| `$10` | long | environment | Pointer to environment block (§8), or −1 = none. EXEC: caller's `env` arg, or the parent's `$10` if the arg is 0. PSPSET: parent's `$10`. |
| `$14` | long | EXITVC | Return address used when this process terminates. Set by EXEC/PSPSET to the return address of that call; updated by INTVCS($FFF0) while this process is current. |
| `$18` | long | CTRLVC | Inherited from the live slot at EXEC/PSPSET; updated by INTVCS($FFF1). |
| `$1C` | long | ERRJVC | Inherited; updated by INTVCS($FFF1) and ($FFF2). |
| `$20` | long | command line | Pointer to the command line given to EXEC (not copied). PSPSET: 0. |
| `$24` | 12 bytes | handle bitmap | One bit per file handle 0–95 opened by this process: byte `h>>3`, bit `h&7`. Cleared at creation. Set by handle-creating calls, cleared by CLOSE (see `21-file-io.md`). |
| `$30` | long | BSS start | `B + $100 + text + data` (R: `B+$100+filesize`; PSPSET: `B+$100`). |
| `$34` | long | heap start | Same value as `$30`. |
| `$38` | long | end of image | `$30 + bss` (= value of a1 at program entry). |
| `$3C` | long | parent USP | USP of the EXEC/PSPSET caller at the time of the call. |
| `$40` | long | parent SSP | SSP of the caller **after** removing the DOS-call exception frame (i.e. the SSP the caller had before trapping). |
| `$44` | word | parent SR | SR of the caller at the time of the call. |
| `$46` | word | abort SR | Copy of live `$1C60`. |
| `$48` | long | abort SSP | Copy of live `$1C62`. |
| `$4C` | long | trap #10 vector | Saved copy of vector `$0A8`. |
| `$50` | long | trap #11 vector | Saved `$0AC`. |
| `$54` | long | trap #12 vector | Saved `$0B0`. |
| `$58` | long | trap #13 vector | Saved `$0B4`. |
| `$5C` | long | trap #14 vector | Saved `$0B8`. |
| `$60` | long | shell flag | Cleared at creation. The kernel sets it to −1 on the command shell it starts at boot. [verified write; meaning inferred] |
| `$64` | byte | module number | Bound-module number the program was loaded from (EXEC mode high byte). Mode 0/1 loads only. |
| `$65` | 3 bytes | — | Not written by the kernel. |
| `$68` | long | child | Block of the child currently being run by this process: set in the **parent** by EXEC mode 0/1 and PSPSET; cleared when that child terminates (EXIT/KEEPPR). Cleared at creation. |
| `$6C` | 20 bytes | — | Not written by the kernel. |
| `$80` | 68 bytes | exec path | `"D:\DIR\...\"`: logical drive letter, colon, absolute directory with `\` separators and trailing `\`, NUL. Mode 0/1 loads only. |
| `$C4` | 60 bytes | exec name | File name of the program: base name (spaces dropped, up to 18 chars incl. the extended part) + `"."` + extension (spaces dropped) + NUL. The `.` is always present, even with an empty extension. Mode 0/1 loads only. |
| `$100` | — | — | Start of program text. |

Fields not listed as written are left as whatever was in memory (the block is
not cleared). [verified]

---

## 3. EXEC — $FF4B

```
stack: word mode, long a, long b, long c   -> d0
```

`mode` low byte = function; high byte = **bound module number** (0 = the file
itself). [verified]

| Mode | a | b | c | Action |
|---|---|---|---|---|
| 0 | file name | command line | env | Load and execute; returns child's termination code. |
| 1 | file name | command line | env | Load only; returns entry address, child becomes current process. |
| 2 | command string (in/out) | command-line buffer (out) | env | Path search. |
| 3 | file name | load address | limit address | Overlay load (no process). |
| 4 | entry address | — | — | Execute a program loaded by mode 1. |
| 5 | file name | module name | — | Find a module in a bound file. |
| other | | | | **−14**. |

On an MC68020 or later CPU (MPU type byte at `$0CBC` ≥ 2) every EXEC call
first performs IOCS `$AC` (SYS_STAT) with d1 = 3 (cache flush). [verified]

### 3.1 File type determination (modes 0, 1, 3) [verified]

1. Take the file name string; ignore trailing spaces. If the last character is
   immediately preceded by `.` (i.e. the extension is exactly one character),
   that character, lower-cased (OR $20), selects the type: `x` → X-format,
   `r` → R-format, `z` → Z-format.
2. Otherwise the **high byte of the file name pointer** selects it: 1 = R,
   2 = Z, 3–255 = X, 0 = error **−13**.

The name pointer (including any high byte) is passed unchanged to the file
open, so on a 24-bit-address machine the high byte is ignored by hardware.
[inferred]

The file is opened read-only; open errors (e.g. −2) are returned as is.
While the load is in progress the handle is remembered so an abort can close
it (§5.6).

### 3.2 Executable formats [verified]

**X-format** (64-byte header, big-endian):

| Off | Size | Meaning (fields the kernel uses) |
|---|---|---|
| `$00` | word | `'HU'` ($4855) — otherwise **−11** |
| `$03` | byte | load mode: bit 1 set = load at high memory (see §3.3) |
| `$04` | long | base address the image was linked for |
| `$08` | long | entry (execution start) address, in link-time terms |
| `$0C` | long | text size — 0 is rejected with **−11** |
| `$10` | long | data size |
| `$14` | long | bss size (includes common/stack) |
| `$18` | long | relocation table size in bytes |
| `$3C` | long | bind list file offset (bound files only; 0 = not bound) |

File layout: header, text, data, relocation table (immediately following the
data). Anything after the relocation table is ignored.

*Bound modules*: if the module number (EXEC mode high byte) is non-zero, the
header must have a non-zero `$3C`; the kernel reads the long at file offset
`[$3C] + 32×module + $1C`, seeks to that offset and reads a second 64-byte
header there, which must also start with `'HU'`. Loading then proceeds from
that header (text follows it). Any failure → **−11**.

*Relocation*: delta = actual load address of the text − header base (`$04`).
If delta is 0 the table is **not processed** (not even read). Otherwise a
cursor starts at the text start and the table (a stream of big-endian words,
consumed until `$18` bytes have been read) is processed:

* word `w ≠ 1`: cursor += `w & $FFFE`; if `w` is even, add delta to the
  **long** at cursor; if `w` is odd, add delta to the **word** at cursor.
* word `1`: the next two words form a 32-bit value `v` (high word first);
  cursor += `v & ~1`, and the long/word choice is made from bit 0 of `v` as
  above.
* Premature end of file while reading the table → **−11**.

Entry address = `$08 − $04 +` text load address.

**R-format**: a raw memory image with no header. The whole file is loaded;
entry = load address; no bss, no relocation. A 0-byte file is **−11**.

**Z-format** (28-byte header):

| Off | Size | Meaning |
|---|---|---|
| `$00` | word | `$601A` — otherwise **−11** |
| `$02` | long | text size |
| `$06` | long | data size |
| `$0A` | long | bss size |
| `$16` | long | absolute load address = entry address |
| `$1A` | word | must be non-zero (normally `$FFFF`) — otherwise **−11** |

Text+data follow the header and are loaded at the fixed load address; no
relocation. A short header read is **−11**.

### 3.3 Mode 0 / mode 1 — load (and execute) [verified]

1. Determine the type (§3.1); open the file.
2. Allocate the process block and read the image:
   * **X**: read the header (bound-module redirection if required). Needed
     size = text + data + bss + `$F0` (+ `$10` header = `$100` PSP).
     * If header byte `$03` bit 1 is set: MALLOC2 mode 2 of exactly the needed
       size (block at the top of the highest fitting gap).
     * Otherwise (including load mode value 1 — the "smallest block" mode is
       **not** honoured): query the largest free size (MALLOC of $FFFFFF); if
       it is smaller than needed, fail; else allocate **that largest size**
       (so the program gets the whole largest free gap).
     * Read text+data to `B+$100`; short read → **−11** (block freed). Apply
       relocation. Close the file.
   * **R**: file size = seek to end. Needed = size + `$F0`; allocate the
     largest free block as for X. Read the file to `B+$100`. Close.
     Quirk: a 0-byte R file returns −11 *without freeing the block* (it stays
     owned by the caller).
   * **Z**: read the header. The process block is placed at the fixed address
     `B = loadaddr − $100`. The range `[B, loadaddr + text + data + bss)` must
     lie entirely within one gap: at or above some block's `end` (not
     rounded) and not beyond the next block's header (or memory end).
     Otherwise **−8**. A header is created at `B` with prev/next linked in,
     owner = current process, and **`end` = the next block's header address
     (or memory end)**, i.e. the whole remainder of the gap. Read text+data to
     the load address; short read → −11 (block freed).
   * Allocation failure returns the MALLOC failure value **as is**
     (`$81xxxxxx` / `$82000000`), not −8. [verified]
3. Clear the bss (`bss` bytes after text+data) to zero.
4. Initialise the PSP (§2) exactly as PSPSET does (§6.1) but with: `$30/$34`
   = after text+data, `$38` = after bss, `$10` = env arg (0 → parent's env;
   −1 is stored as −1), `$20` = command-line pointer, EXITVC = return address of
   this EXEC call. Then `$64` = module number, `$80` = path, `$C4` = name
   (derived from the given file name after normal path parsing, with the drive
   shown as its logical letter). The **new process becomes the current
   process** and `parent.$68` = child.
5. Mode 1 stops here and returns to the caller with:

   | Register | Value |
   |---|---|
   | d0 | entry address |
   | a0 | child block `B` |
   | a1 | end of image (`$38`) |
   | a2 | command line pointer |
   | a3 | environment pointer (after the 0 → parent substitution) |
   | a4 | entry address |

   The child remains the current process; it is started with mode 4.

6. Mode 0: call KNJCTRL ($FF22) with long arguments (1, 0), then start the
   program (§3.5). EXEC returns only when the child terminates (§5), with d0 =
   the termination code.

Errors before the process exists (wrong type, open error, bad header,
allocation failure, read error) return a negative d0 with nothing changed
except as noted.

### 3.4 Mode 4 — execute loaded program [verified]

`a` = entry address. The current process (normally the one created by mode 1)
is started:

* EXITVC (live slot and the PSP copy) := return address of this mode-4 call;
  `$3C/$40/$44` := caller's USP/SSP/SR at this call; the live CTRLVC/ERRJVC,
  abort SR/SSP and trap #10–#14 vectors are copied into the PSP (`$18`,
  `$1C`, `$46`, `$48`, `$4C..$5C`).
* Registers a0 = current process block, a1 = its `$38`, a2 = its `$20`,
  a3 = its `$10`, a4 = entry; KNJCTRL(1, 0); start as §3.5.
* No validation of the entry address or of the current process is made.

### 3.5 Program entry state [verified]

The program is entered by returning from the EXEC trap with the following
changes to the caller's saved state:

| Item | Value |
|---|---|
| PC | entry address |
| d0 | entry address `& $00FFFFFF` |
| a0 | process block `B` (PSP pointer − $10) |
| a1 | end of image (= PSP `$38`) |
| a2 | command line pointer (PSP `$20`) |
| a3 | environment pointer (PSP `$10`) |
| a4 | entry address |
| d1–d7, a5, a6 | **unchanged** from the EXEC caller |
| USP | unchanged (the caller's user stack) |
| SSP | the caller's SSP before the trap |
| SR | caller's SR, except the S bit: **set** if the entry address (low 24 bits) is below the supervisor-area boundary (root block `end`) or ≥ `$C00000`; **cleared** otherwise. |

The kernel does not set up a stack for the program; programs set their own.

Command line format (as produced by mode 2 and expected by programs): one
length byte `n`, then `n` characters, then NUL. [verified for mode 2 output]

### 3.6 Mode 3 — overlay load [verified]

`a` = file name, `b` = load address, `c` = limit address (exclusive). No
memory is allocated and no process is created; the module number is honoured
for X files.

* **X**: header checks and bound-module redirection as in §3.2. If
  `b + text + data + bss > c` → **−8**. Read text+data at `b` (short read →
  −11), relocate relative to `b`, close, clear the bss.
  Returns d0 = text + data + bss. (Load mode bit is ignored.)
* **R**: if `b + filesize > c` → −8. Read the whole file at `b`; returns d0 =
  number of bytes read (0 bytes → −11). No bss.
* **Z**: the Z load address must equal `b` exactly, else **−8**; `b + text +
  data + bss > c` → −8. Read text+data, clear bss; returns text+data+bss.

### 3.7 Mode 2 — path search [verified]

`a` = pointer to a command string `"progname args..."` (NUL-terminated);
`b` = buffer to receive the command line; `c` = environment (0 → current
process's env; −1 → a built-in environment whose only entry is `path=` with an
empty value). Nothing is loaded.

1. Leading spaces/tabs are skipped. The program name runs until NUL or a
   character that is not valid in a file name (space, tab, control chars)
   [terminator set inferred]. A `?` or `*` in it → fail. Empty → fail.
2. The name is split at the last `:` or `\` (Shift-JIS aware: second bytes of
   two-byte characters, lead bytes $80–$9F/$E0–$FF, are not separators).
   The file-name part must be 1–22 characters; the directory part 0–64
   characters. If the directory part is ≥ 2 chars and starts with `X:`, drive
   X must exist (else fail).
3. The rest of the command string after the name and following white space is
   copied to `b+1` up to its NUL; `b[0]` = its length. Longer than 255 → fail.
4. Search:
   * If a directory part was given, only that directory is tried.
   * Otherwise the bare name is tried first (current directory), then each
     element of the environment variable `path` (exact, case-sensitive name
     `path`; elements separated by `;`; a `\` is appended to an element unless
     it already ends in one). Quirk: if the environment has **no** `path`
     entry, the search list is taken to be the literal string `path=` (one
     element), so the only extra attempt is in a directory named `path=`.
   * If the name has an extension (contains `.`), a candidate matches if a
     file (FILES attribute $20) of that name exists.
   * If it has no extension, `.*` is appended and all matches in that
     directory are examined: matches whose (lower-cased) extension is exactly
     `r`, `z` or `x` qualify, with priority **r > z > x**. The first directory
     with any qualifying match wins and the name gets `.` + the lower-case
     letter appended.
5. On success the **string at `a` is overwritten** with the resulting file
   name (directory part as given or the PATH element, plus the name) and d0 =
   0. On any failure d0 = **−2** (the buffer at `b` may have been partly
   written).

### 3.8 Mode 5 — bound module lookup [verified]

`a` = bound file name, `b` = module file name. Opens the file, reads the
64-byte header (not `'HU'` → **−11**). If `$3C` = 0 → **−2**. Otherwise the
module name is parsed like a path name, its extension forced to begin with
`X`, and the bind list at file offset `[$3C]` is read as consecutive 32-byte
entries until end of file. Each entry is compared with the name as a
directory entry would be (8-char name + 3-char ext, first byte `$05` treated
as `$E5`). For a matching entry at index `i`, the result is `i << 8`, except
that if the entry's long at `+$1C` is ≥ `$FFFFFF00` the result is
`(~that_long) << 8`. The **last** match wins; no match → −2. The returned
value is meant to be OR-ed into an EXEC mode word as the module number.

---

## 4. EXEC-related error codes

| d0 | Meaning |
|---|---|
| −2 | File not found (open error, mode 2 not found / bad syntax, mode 5 not bound / not found). Other open errors pass through. |
| −8 | Overlay doesn't fit (mode 3), Z region not free (modes 0/1). |
| −11 | Bad X/Z header, text size 0, short read, bad bound module, empty R file. |
| −13 | No recognisable type (no `.x/.r/.z` and pointer high byte 0). |
| −14 | Mode not 0–5. |
| `$81xxxxxx`/`$82000000` | Allocation failure (modes 0/1), passed through from MALLOC. |

---

## 5. Termination

### 5.1 EXIT — $FF00 and EXIT2 — $FF4C [verified]

```
EXIT : no arguments          code = 0
EXIT2: stack: word code      code = code (zero-extended)
```

Sequence:

1. `$1CAE` := code (high word 0).
2. **Close files**: for the current process, every handle 5–95 whose bit is
   set in PSP `$24` is closed. Then, while the process's `$68` (child) is
   non-zero and that child's `$04` equals this process, the same is done for
   that child, and so on down the chain. Handles 0–4 are never closed.
3. **Free memory** (`10-memory.md` §8): unlink the process block, current
   process := its parent (`$04`), free everything owned by it recursively.
4. SSP := PSP `$40`; USP := PSP `$3C`. Build a return frame (68010+: format
   word 0) with PC = PSP **`$14`** (the exiting process's EXITVC — so a
   process that changed EXITVC with INTVCS exits to that address) and SR =
   PSP `$44`.
5. In the parent: `$68` := 0; live EXITVC/CTRLVC/ERRJVC := parent's
   `$14/$18/$1C`; live abort SR/SSP := parent's `$46/$48`; vectors trap
   #10–#14 := parent's `$4C..$5C`.
6. KNJCTRL(1, 0); InDOS counter `$1C08` := 0; return from exception with
   d0 = `$1CAE`. Other registers are **not** restored: d1–d7/a0–a6 hold
   whatever the kernel left (a0 = parent block); callers of EXEC must treat
   them as destroyed.

EXIT from the root process is undefined.

### 5.2 KEEPPR — $FF31 [verified]

```
stack: long keepsize, word code
```

1. `$1CAE` := `$00010000 | code`.
2. Current process := parent; the process's `$04` |= `$FF000000` (resident
   marker; its block will never be freed by the parent).
3. If `B + $100 + keepsize` < the block's `end`, `end` := that value (the
   block is only ever shrunk; `keepsize` counts from the program start
   `B+$100`).
4. **No files are closed and no memory is freed** (blocks owned by the
   resident process stay allocated).
5. Return to PSP `$14` with SSP/USP/SR from `$40/$3C/$44` as for EXIT.
6. In the parent: `$68` := 0; live EXITVC/CTRLVC/ERRJVC and abort SR/SSP
   restored from the parent's PSP. For trap #10–#14: if the live vector
   differs from the parent's saved copy (the resident installed a handler),
   the **live vector is kept** and the new value is written into the saved
   slot of the parent **and of every ancestor** (following `$04` links until
   0); unchanged vectors are left as is.
7. KNJCTRL(1, 0); `$1C08` := 0; d0 = `$1CAE`.

### 5.3 WAIT — $FF4D [verified]

No arguments. Returns d0 = `$1CAE`: the most recent termination code
(high word 0 = EXIT/EXIT2, 1 = KEEPPR; low word = code). It is not reset.

### 5.4 What survives a child

| Resource | EXIT/EXIT2 | KEEPPR |
|---|---|---|
| Child's block | freed | kept (owner flagged `$FF`) |
| Blocks owned by child (recursively) | freed (except flagged ones) | kept |
| Handles 5–95 opened by child | closed | kept open |
| Handles 0–4 | not closed | not closed |
| Environment / command line | belong to the parent; untouched | untouched |
| Trap #10–#14 vectors | restored from parent | changed ones kept & propagated |

### 5.5 Abort (Ctrl-C and error abort) [verified]

These are entered from the console and critical-error code (`30-char-io.md`);
the process-related behaviour is:

* **Ctrl-C**: if an EXEC load is in progress, it is first rescued (§5.6).
  Then the DOS call is abandoned: SSP is reset to the outermost DOS entry
  frame, the frame's PC is replaced by the live **CTRLVC**; if that address is
  below the supervisor-area boundary the S bit is set in the frame SR (it is
  never cleared); `$1C08` := 0; registers d1–d7/a0–a6 are restored to the
  values at DOS entry; d0 = `$00002000`; return from exception (i.e. jump to
  CTRLVC).
* **Error abort**: (rescue as above), SSP := live abort SSP (`$1C62`),
  `$1C08` := 0, and an exception return is made to the live **ERRJVC** with
  SR = live abort SR (`$1C60`) (68010+: format word 0) and d0 = `$00004000`.
* In both cases, if the rescue fails (no memory for the stand-in process),
  no vector is entered: the interrupted outermost DOS call simply returns to
  its caller with d0 = `$00002000` and `$1C08` = 0.

Neither path terminates the process by itself; the handler (normally
inherited from the shell) is expected to call EXIT/EXIT2. [inferred]

### 5.6 Rescue of an interrupted EXEC [verified]

During mode 0/1 the kernel tracks the load state. On an abort:

1. If the executable file is still open it is closed.
2. Depending on progress:
   * before the process block was allocated: the largest free block is
     allocated (as for an R load of size 1) and turned into a process;
   * after allocation but before the PSP was initialised: that block is
     turned into a process;
   * PSP already initialised: nothing more.

   "Turned into a process" = PSPSET semantics (§6.1) with EXITVC = return
   address of the interrupted EXEC call, environment = parent's, command line 0.
3. Thus the abort handler runs with a (partial) child as the current process,
   and EXIT from it returns to the EXEC caller as if the child had run.

---

## 6. Other process calls

### 6.1 PSPSET — $FF26 [verified]

```
stack: long psp      (psp = block + $10, typically a MALLOC result) -> d0 = 0
```

Turns the block at `psp − $10` into a new current process without loading
anything. Writes: `$10` = parent's environment, `$14` = return address of this
call (also put in the live EXITVC slot), `$18/$1C` = live CTRLVC/ERRJVC,
`$20` = 0, `$24..$2F` = 0, `$30 = $34 = $38 = B + $100`, `$3C/$40/$44` =
caller's USP / SSP-before-trap / SR, `$46/$48` = live abort SR/SSP,
`$4C..$5C` = trap #10–#14 vectors, `$60` = 0, `$68` = 0. In the old current
process, `$68` := new block. Current process := new block. The memory header
(`$00..$0F`, including the owner) and `$64`, `$80`, `$C4` are not touched.
No validation of the pointer. The new process later terminates through the
normal EXIT path, returning to the PSPSET caller's return address.

### 6.2 GETPDB — $FF81 (alias $FF51) [verified]

No arguments; d0 = current process block + $10.

### 6.3 SETPDB — $FF80 (alias $FF50) [verified]

```
stack: long psp      -> d0 = previous current process block + $10
```

Current process := `psp − $10` (not validated). Then the live
EXITVC/CTRLVC/ERRJVC, abort SR/SSP and trap #10–#14 vectors are **loaded from
the new process's PSP** (`$14..$1C`, `$46/$48`, `$4C..$5C`). The old process's
live values are *not* saved into its PSP first.

---

## 7. EXITVC / CTRLVC / ERRJVC ($FFF0–$FFF2)

These are not callable functions; they are three slots of the DOS-call vector
table (`$1BC0`, `$1BC4`, `$1BC8`), read with INTVCG and written with INTVCS
using vector numbers $FFF0, $FFF1, $FFF2 (`40-misc-calls.md`). [verified]

| Event | Effect on the slots |
|---|---|
| INTVCS($FFF0, v) | live EXITVC := v; current PSP `$14` := v. |
| INTVCS($FFF1, v) | live CTRLVC := v **and live ERRJVC := v** (quirk); PSP `$18` := v and `$1C` := v; live abort SR := SR of the INTVCS caller, live abort SSP := address just above the INTVCS call's 6-byte frame (SR+PC; the format word on 68010+ is *not* skipped — quirk); same into PSP `$46/$48`. |
| INTVCS($FFF2, v) | live ERRJVC := v; PSP `$1C` := v; abort SR/SSP set as for $FFF1. |
| INTVCS of trap #10–#14 vectors | also stored into the current PSP `$4C..$5C`. |
| EXEC mode 0/1/4, PSPSET | live EXITVC := return address of that call; all three slots, abort SR/SSP and trap #10–#14 copied into the child's PSP. CTRLVC/ERRJVC are thus inherited. |
| EXIT/EXIT2 | child exits to *its own* `$14`; live slots etc. reloaded from parent's PSP. |
| KEEPPR | as EXIT, plus trap-vector propagation (§5.2). |
| SETPDB | live slots loaded from the new process's PSP. |
| Thread switch | live slots saved to the outgoing process's PSP, loaded from the incoming one (`12-background.md`). |

Default at boot: all three slots point at a kernel routine that, if the
current process is the root, reports that the shell terminated and offers to
restart it; otherwise performs EXIT. [verified]

---

## 8. Environment block and GETENV/SETENV

### 8.1 Format [verified]

```
+0  long   total size of the block in bytes (including this long)
+4         "NAME=value\0" strings, one after another
           "\0"  (an empty string terminates the list)
```

The system environment is allocated from `envset` in CONFIG.SYS (size
$200–$FFFF; size long = allocated size; initially empty, i.e. `+4` = 0).
Names are case-sensitive; the kernel itself looks up `path` in lower case.

### 8.2 GETENV — $FF83 (alias $FF53) [verified]

```
stack: long name, long env, long buffer   -> d0
```

`env` = 0 → current process's environment (PSP `$10`). If the environment is
−1 → d0 = −1. Searches for an entry beginning with `name` + `=` (exact,
case-sensitive). Found: the value (text after `=`) is copied with its NUL to
`buffer` (no length limit); d0 = 0. Not found → −1.

### 8.3 SETENV — $FF82 (alias $FF52) [verified]

```
stack: long name, long env, long value   -> d0
```

`env` = 0 → current process's; −1 → d0 = −1. `value` = 0 (NULL) is treated
as an empty string.

1. If an entry `name=` exists:
   * if the new entry `name=value` is longer than the old one and the free
     space (size − bytes used including the terminating empty string) is less
     than the difference → d0 = −1 (nothing changed);
   * otherwise the old entry is removed (following entries move down).
2. If `value` is empty: done, d0 = 0 (deletion; deleting a missing name is
   not an error).
3. Otherwise, if free space < `strlen("name=value")` → d0 = −1 (the old entry
   has already been removed in that case). Else the new entry is appended at
   the end followed by a new terminating NUL; d0 = 0. Quirk: the check allows
   the block to be overrun by one byte (free space equal to the string length
   is accepted although length + 1 bytes are needed).

A replaced variable therefore moves to the end of the environment.

---

## 9. Ordering summary for EXEC mode 0 (for implementers)

1. (68020+) cache flush. 2. Decode mode/module. 3. Type, open. 4. Header,
allocation, read, relocate, close. 5. bss clear. 6. PSP init and process
switch (parent `$68`, EXITVC = return address, vectors copied). 7. module
number, `$80`, `$C4`. 8. KNJCTRL(1,0). 9. S-bit decision and jump to entry.
... child runs ... 10. EXIT: close files, free memory, restore stacks,
reload parent vectors, KNJCTRL(1,0), return d0 = code at EXEC caller.
