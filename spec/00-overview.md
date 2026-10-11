# 00 — Overview: boot sequence, memory map, system work area, vectors

Scope: what the kernel does from the moment the boot loader jumps into it until the
command shell is running, the memory layout that results, the low-memory variables the
kernel owns, and the exception/trap vectors it installs.

Related files: `01-dos-dispatch.md` (F-line entry), `02-config-sys.md` (CONFIG.SYS),
`03-device-drivers.md` (driver chain), `11-process.md` (EXEC/PSP), `12-background.md`.

Confidence tags: **[verified]** read from the binary's behaviour, **[inferred]** deduced,
**[public]** from public documentation only.

---

## 1. Hand-off from the boot loader

| Item | Behaviour |
|------|-----------|
| Load address | The kernel file is an X-file whose image is linked for, and loaded at, absolute address `$006800`. The first instruction (image offset 0) is a branch to the real entry. [verified] |
| CPU mode | Entered in supervisor mode with interrupts in whatever state the loader left. [inferred] |
| Registers | No register contents from the loader are used. The kernel immediately sets SSP = `$006800` (stack grows down into the area below the kernel). [verified] |
| Memory the kernel trusts from ROM/IPL | IOCS (trap #15) fully initialised, IOCS call table at `$000400-$0007FF`, byte `$000CBC` = MPU type (0 = 68000, 1 = 68010, 2 = 68020, 3 = 68030; set by ROM IOCS). SRAM at `$ED0000`: `$ED0008.l` = installed main-memory size, `$ED001A.w` = RS-232C settings, `$ED001D.b` = power-on screen mode. [verified] |
| Boot device | Obtained from IOCS `$8E` (_BOOTINF). Values `< $100`: `$8x` = SASI hard disk unit x, `$9x` = floppy unit x; values `>= $100` = address of the ROM (SCSI) the system booted from. [verified for the decision logic; meaning of codes public] |

### 1.1 Default-parameter block (compatibility)

Bytes at image offsets `+$04..+$18` hold the defaults that CONFIG.SYS can override. A
reimplementation only needs this if it wants to support tools that patch the kernel file.
[verified]

| Image offset | Size | Default | Meaning |
|---|---|---|---|
| +$04 | byte | 15 | `files` |
| +$05 | byte | 20 | `buffers` count |
| +$06 | word | 1024 | `buffers` sector-buffer size (bytes) |
| +$08 | byte | 25 | `lastdrive` (0 = A … 25 = Z) |
| +$09 | byte | 25 | absolute maximum drive index (copied to `$1C74`) |
| +$0A | byte | 0 | `break` (0 off / 1 on / 2 kill) — note: CONFIG.SYS processing always overwrites it, see 02 |
| +$0B | byte | 0 | `verify` |
| +$0C | word | 0 | `share` first value |
| +$0E | word | 0 | `share` second value |
| +$10 | long | 0 | `common` size in bytes |
| +$14 | byte | 0 | `process` first value |
| +$15 | byte | 0 | `process` second value |
| +$16 | byte | 0 | `process` third value |
| +$17 | byte | 0 | `newfat` |
| +$18 | byte | 1 | `scsidev` (1 = on) |
| +$19 | string | — | built-in title text (NUL-terminated), printed when no TITLE file |

---

## 2. Boot sequence (in order)

Each step is [verified] unless tagged otherwise.

1. **SSP := `$006800`.**
2. **MPU detection fallback.** If `$0CBC` is 0, the kernel temporarily points the trap #14
   vector (`$0000B8`) at a probe handler, pushes a long magic value and executes `trap #14`.
   The probe looks at the stacked data: if the magic is found 6 bytes above SP (68000 frame:
   SR+PC only) it reports 0, otherwise 3. The result is stored in `$0CBC`. (So an
   unidentified non-68000 is treated as a 68030.) The trap #14 vector is overwritten again
   in step 4.
3. **Cursor off** (IOCS `$AF` _OS_CUROF).
4. **Work area and vector initialisation.**
   - Copy the initial DOS call table (256 longs) to `$001800-$001BFF`.
   - Clear `$001C00-$001FFF`.
   - Vector `$2C` (F-line, vector 11) := DOS dispatcher. If MPU type ≠ 0, vector `$20`
     (privilege violation) := the same entry (it patches user `MOVE SR,<ea>`; see 01 §2.4).
   - Vector `$B8` (trap #14) := kernel error-display handler (§5.2).
   - IOCS call vector `$FF` (`$0007FC`, _ABORTJOB) := kernel abort-job handler (§5.3).
   - Trap #11 (`$0000AC`, BREAK) and trap #10 (`$0000A8`, power switch / reset) are
     **chained**: the old vectors are saved in `$1C66` and `$1C6A`, kernel handlers installed (§5.4).
   - The "EXEC file handle" variable := −1 (no executable file open; see 11).
   - **Memory size probe:** starting at `$100000`, in 1 MB steps, up to the size recorded in
     SRAM `$ED0008`: write a test long, read it back (bus errors caught by temporarily
     replacing the bus-error vector), restore the original contents. The first failing
     address (or the SRAM value) becomes the memory end → `$1C00`.
   - `$1C24` (init-time allocation pointer) := end of the kernel's resident image.
   - `$1C04` (memory-chain head) and `$1C20` := the kernel's own memory block (header inside
     the kernel image; the kernel acts as the root process, see 11).
   - Kernel process block initialised from the current exit/ctrl-C/error vectors.
   - CTRLVC (`$1BC4`) := "fatal boot error" routine (step 25 replaces it).
   - Control-key codes `$1CBC..$1CC4` := `$0003,$000E,$0010,$0011,$0013`.
   - Sector-buffer size `$1C70`, break, verify from the default block; `$1C12` (break mode)
     := 2 during boot; `$1CBA` (fflush) := 1; `$1C28` := address of the kernel variable
     holding the current process; `$1C0C` := 3, `$1C0E` := 100; `$1C74` := max drive index;
     `newfat` value → `$1C0B`; directory-search caching (dirsch) := on.
   - Drive-assignment table `$1C7E..$1C97` := identity (0,1,…,25).
   - If the byte at `$000160` is non-zero, the word at `$000160` is set to `$00FF`. [verified; purpose inferred: normalises an unused vector whose top byte holds a ROM "unhandled" marker]
5. **Drive (current-directory) table**: `$1C74+1` (normally 26) entries of `$4E` bytes are
   carved from `$1C24`; pointer in `$1C38`. Entry layout is owned by `20-filesystem.md`;
   initial contents: `+$00` = `"A:"`,TAB,NUL (drive letter incremented per entry), rest
   zero, `+$45` flags = 0, `+$46` long DPB pointer, `+$4A` word `$FFFF`, `+$4C` word 2. When
   a drive is attached `+$46` = its DPB and `+$45` = `$40` (valid). [verified]
6. **Built-in device initialisation** (see 03): walk the built-in chain NUL → CON → AUX →
   PRN → LPT → CLOCK issuing INIT (command 0) to each; then append the built-in block
   drivers in boot-device order and INIT them:
   - boot from ROM address (`>= $100`): the ROM's Human68k driver(s) (ROM driver protocol, 02 §4.3), then floppy, then SASI hard disk;
   - boot from SASI HD (`$8x`): hard-disk driver first, then floppy;
   - otherwise (floppy): floppy first, then hard disk.
   Each block driver's units become consecutive drives (A:, B:, …). The **boot drive**
   (`$1C15`, also the initial current drive) is the drive number the booting driver
   reports back in its INIT packet (`+$16` − 1). The device-chain tail is recorded in `$1C1C`.
7. If no drive at all was created (`$1C75` = 0) → **fatal boot error** (§2.1).
8. The kernel process's path field is patched to the boot drive letter (`"A:\"` + boot drive).
9. **CLOCK binding:** the character device named `CLOCK` (last match in the chain at this
   moment) is recorded in `$1CB6`; all date/time DOS calls use it (03 §6.6). Drivers named
   CLOCK installed later by `device=` are *not* bound. [verified]
10. **Temporary file tables**: 3 sector buffers and FILES-equivalent of 5 entries are built
    so that CONFIG.SYS can be read. [verified]
11. **CONFIG.SYS pass 1** (02 §3): files, buffers, lastdrive, scsidev, exconfig, ctty,
    romdb. Followed by a memory feasibility check (fatal if it fails).
12. **Real buffers and file tables** built from the pass-1 values (overwriting the temporary ones).
13. **scsidev** (if on): install drivers from the SCSI ROM (02 §2 scsidev).
14. **Bound driver modules**: the kernel loads module 1, 2, 3, … of its own file
    (`Human.sys`, EXEC mode 3 with module number) as device drivers until a load fails
    (02 §4.4). [verified]
15. **exconfig** program (02 §2) — may switch the CONFIG file name to `CONFIG.TMP`.
16. **CONFIG.SYS pass 2** (02 §3): title, key, uskcg, fflush, off, break, verify, newfat,
    dirsch, bell, share, common, process.
17. **USKCG** font file (if a name is set; default `USKCG.SYS`).
18. **TITLE** display (default `TITLE.SYS`; built-in text if missing). See 02 §2 title.
19. **KEY** file (default `KEY.SYS`) loaded into the function-key table.
20. **CONFIG.SYS pass 3**: every `device=` line in file order (02 §4).
21. **Supervisor area protection**: kernel end := (`$1C24` + `$1FFF`) rounded down to an 8 KB
    boundary. This becomes the end of the kernel's own memory block (start of user memory)
    and `(end / 8192) − 1` (clamped to 255) is written to the area-set register `$E86001`.
22. CTRLVC (`$1BC4`) := shell-restart routine (§4), set through INTVCS. Note that INTVCS
    on CTRLVC also stores the same address into ERRJVC (`$1BC8`) and records the current
    SR/SSP into `$1C60/$1C62` (see 40-misc-calls); the same happened for the fatal routine
    in step 4. [verified]
23. Trap vectors `$A8-$BB` (traps #10-#14) are saved into the kernel process block (restored when a process exits, see 11).
24. **CONFIG.SYS pass 4**: `envset`, every `program=` (in order), `shell` (02 §2). From
    here on the kernel allocates with MALLOC (user memory, owned by the kernel process).
25. CONCTRL mode 2 with value 3 (console attribute 3). [verified call; effect per 30-char-io]
26. Break mode `$1C12` := CONFIG value.
27. **Shell launch loop** (§4).

### 2.1 Fatal boot error

Reached on: no drives, out of memory while building tables, bad driver end address, too
many drives, sector size larger than the buffer size, ctrl-C during boot (CTRLVC points
here until step 22), or a resident exconfig program. Behaviour: SSP := `$006800`, cursor on
(IOCS `$AE`), print a "system could not be started, please reset" message via IOCS `$21`,
wait for a key (IOCS `$00`), then loop forever executing `trap #10` with
`d0 = $58363800` (`'X68',0`). [verified]

---

## 3. Final memory map

| Range | Owner / contents |
|---|---|
| `$000000-$0003FF` | 68000 exception vectors (kernel installs those in §5). |
| `$000400-$0007FF` | IOCS call vectors (kernel replaces `$FF` _ABORTJOB). [verified] |
| `$000800-$0017FF` | ROM IOCS work area (kernel reads `$0CBC` MPU type). [public] |
| `$001800-$001BFF` | **DOS call vector table**: 256 longs, entry n = handler for `$FFnn` (01 §3). Entries `$F0-$F2` are the current EXIT/CTRL-C/ERROR vectors (`$1BC0/$1BC4/$1BC8`); entries `$F8`, `$F9`, `$FF` are background-scheduler hooks (12). [verified] |
| `$001C00-$001FFF` | **DOS work area** (§6). Cleared at boot. [verified] |
| `$002000-$0067FF` | Used as supervisor stack during boot only. [inferred: not referenced afterwards] |
| `$006800-…` | Kernel image. The boot-code region at its start is reused, after boot, as the **system supervisor stack**: it is filled with `$FF` and the stack top is the kernel's own memory-block header, which immediately follows it. [verified] |
| … | Resident kernel code and data. |
| … | Dynamic tables carved at boot, in this order: drive table; DPBs of built-in drives; sector buffers + extra file-table entries; drivers from SCSI ROM / bound modules; `bell` sound data; `share` table; `common` area; background task table; USKCG font buffers; `device=` drivers (each driver occupies load address … reported end address). |
| … up to 8 KB boundary | Padding; this boundary is the end of the kernel memory block and of the supervisor-protected area. |
| boundary … `[$1C00]` | User memory managed by MALLOC (10-memory). The first user blocks are the kernel-owned command-line buffer (`$F0` bytes, also the kernel's user stack) and the `envset` environment, then the shell. |
| `$C00000-` | Video, I/O, ROM (hardware). |

---

## 4. Shell launch loop

[verified]

1. Fill the reused boot-code region with `$FF`; SSP := top of the system stack.
2. Command line = the shell buffer (default `COMMAND /P`, replaced by `shell=` or by a
   graphic TITLE file, see 02). Environment = the kernel's environment (from `envset`;
   none otherwise).
3. EXEC mode 2 (split file name / command line, path search) → EXEC mode 1 (load) → set
   one field in the new process block to −1 (see 11 for its meaning) → EXEC mode 4 (run).
4. If any step returns an error: console attribute reset (CONCTRL 2,3), print CR-LF, the
   command text and "could not be started".
   If the shell returns (exits normally): print CR-LF and "terminated".
5. Print "enter a command" prompt ending in CR-LF and `#`, read a line with GETSS into the
   same shell buffer (`max` byte, `length` byte, text), print CR-LF. Empty input → print
   `#` again and re-read. Otherwise go to step 2 with the typed command line.

**Default EXIT/CTRL-C/ERROR vector** (installed in CTRLVC at step 22 and present in the
initial `$1BC0-$1BC8` entries): when control arrives here and the current process is the
kernel itself (i.e. the shell was aborted), it resets SSP and the kernel user stack,
switches to supervisor, prints CR-LF and "stopped", and enters the prompt of step 5.
Otherwise it performs DOS EXIT. [verified]

---

## 5. Vectors installed by the kernel

| Vector | Address | Kernel use | |
|---|---|---|---|
| 8 privilege violation | `$000020` | Only on MPU ≠ 68000: same entry as F-line; rewrites user `MOVE SR,<ea>` into `MOVE CCR,<ea>` (01 §2.4) | [verified] |
| 11 F-line | `$00002C` | DOS call dispatcher (01) | [verified] |
| trap #10 | `$0000A8` | Power-switch/reset hook, chained (§5.4) | [verified] |
| trap #11 | `$0000AC` | BREAK hook, chained (§5.4) | [verified] |
| trap #14 | `$0000B8` | Error display / Abort-Retry-Ignore (§5.2) | [verified] |
| IOCS `$FF` | `$0007FC` | _ABORTJOB → jump to ERRJVC (§5.3) | [verified] |
| DOS `$F1` CTRLVC | `$001BC4` | Boot: fatal error; afterwards: shell restart | [verified] |

INTVCS/INTVCG (`$FF25/$FF35`) address these as: vector number `< $200` → `4*n` (exception
vectors `$000-$0FF`, IOCS vectors `$100-$1FF`); `>= $200` → `$1800 + 4*(n & $FF)` (so
`$FFxx` selects DOS table entry xx). [verified]

### 5.1 Vectors used by background processing
Timer-D interrupt vector (`$00007C`) is temporarily taken by the scheduler; see 12.

### 5.2 trap #14 — error display

Called by the kernel (and by drivers / FLOAT packages) with **d7.w = error code**, a6 =
pointer to an exception-style frame (SR at +0, PC at +2) used for the display; returns
d7 = 1 (retry) or 2 (ignore); "abort" does not return normally. [verified]

- High byte of d7 = allowed-answer bits: bit 4 (`$10`) Abort, bit 5 (`$20`) Retry,
  bit 6 (`$40`) Ignore. A high byte `< $10` or `>= $80` is treated as `$10` (abort only).
- Messages chosen by d7: `$001F`/`$301F` "interrupt switch pressed"; high byte `$FE`
  "floating-point package not installed"; `2..8` = CPU exception (bus error, address error,
  illegal instruction, zero divide, CHK, TRAPV, privilege violation); `$1000-$7FFF` =
  device error, low byte 1..15 = (1) invalid unit, (2) not ready / no disk, (3) invalid
  command, (4) CRC error, (5) disk control area destroyed / bad request, (6) seek error,
  (7) invalid media, (8) sector not found, (9) printer not connected, (10) write error,
  (11) read error, (12) general error, (13) write-protected (insert same disk),
  (14) write not possible, (15) file-sharing violation; **low byte 0 = message text is
  taken from the string pointed to by a5**; anything else = "error ($xxxx) at SR/PC".
- The user answers with A / R / I (case-insensitive); keys for disallowed answers are
  ignored. A → d7 = 0 and IOCS `$FF` (_ABORTJOB) is invoked; R → 1; I → 2.

### 5.3 _ABORTJOB (IOCS `$FF`)
If a file operation was in progress (work-area `$1C98` non-zero) it is cleaned up; if an
EXEC was in progress it is cleaned up (11). Then SSP := the value saved for ERRJVC
(`$1C62`), IOCS `$FD` (_ABORTRST), INDOS cleared, and an exception frame is built with
PC = ERRJVC (`$1BC8`), SR = saved SR (`$1C60`); `rte` with **d0 = `$00004000`**. [verified]

### 5.4 Chained trap #10 / trap #11
- **trap #11 (BREAK)**: if no break is already pending, record `d0.b | $80` in `$1C16`. If
  INDOS = 0 process it now, else it is processed when the current DOS call returns
  (01 §5). Processing: if bit 0 of the recorded value is 0, flush disk buffers; if 1, flush
  standard input and AUX input. Then the *previous* trap #11 handler is entered with
  d0 = recorded value & `$7F` and a synthesised exception frame. [verified]
- **trap #10 (power switch/reset)**: save d0 in `$1C18`, set `$1C17` = 1. If INDOS = 0 (or
  later, when the outermost DOS call returns, or while a character-input call is waiting):
  fade the screen contrast (IOCS `$11`), close/flush all file handles, flush disk buffers,
  then enter the previous trap #10 handler with the saved d0. [verified]

---

## 6. System work area (`$001C00-$001FFF`)

Long/word/byte as listed; all big-endian. "R" = external programs are known/expected to
read it ([public]/[inferred]); kernel behaviour is [verified] unless tagged.

| Addr | Size | Meaning |
|---|---|---|
| `$1C00` | L | End of main memory (first non-existent address); upper limit for MALLOC. R |
| `$1C04` | L | Head of the memory-block chain (= kernel's own block). R |
| `$1C08` | W | **INDOS count**: nesting depth of DOS calls currently executing. Address returned by `$FFF5` INDOSFLG. R |
| `$1C0A` | B | Low byte of the outermost DOS call number in progress (0 when idle). R |
| `$1C0B` | B | `newfat` setting. |
| `$1C0C` | W | Retry count for sharing/lock conflicts (default 3; IOCTRL sets it). [inferred meaning] |
| `$1C0E` | W | Retry wait time (default 100; IOCTRL sets it). [inferred meaning] |
| `$1C10` | W | VERIFY flag (0 off, non-zero on): block writes use command 9 instead of 8. R |
| `$1C12` | B | Break mode: 0 OFF, 1 ON, 2 KILL (BREAKCK). R |
| `$1C13` | B | Printer echo flag (toggled by ^P, cleared by ^N). |
| `$1C14` | B | Task-switch request flag (background scheduler; 12). |
| `$1C15` | B | Current drive (0 = A:). Boot drive at startup. R |
| `$1C16` | B | Pending BREAK code (bit 7 set) — §5.4. |
| `$1C17` | B | Pending power-switch flag — §5.4. |
| `$1C18` | L | d0 value saved from the power-switch trap. |
| `$1C1C` | L | Address of the last device header in the driver chain (new drivers are linked after it). R [inferred] |
| `$1C20` | L | Address of the kernel's own memory block. |
| `$1C24` | L | Boot-time allocation pointer (next free byte); after boot only background-init uses it. |
| `$1C28` | L | Address of the kernel variable that holds the current process's memory-block address (i.e. `**$1C28` = current process). R [inferred] |
| `$1C2C` | L | Handle table for handles beyond the first standard ones (word per handle, `$FFFF` = free). See 21. |
| `$1C30` | L | File-table (FCB) array for those handles, `$60` bytes per entry. See 21. |
| `$1C34` | L | Start of the sector-buffer area. See 20. |
| `$1C38` | L | Drive (current-directory) table, `$4E` bytes per drive. R |
| `$1C3C` | L | Head of the DPB chain. R |
| `$1C40` | L | `share` table (0 = sharing disabled). |
| `$1C44` | L | `common` area start (0 = none). |
| `$1C48` | L | `common` area current end of used part. |
| `$1C4C` | L | `common` area limit. |
| `$1C50` | L | Background task table (0 = background processing disabled). 12 |
| `$1C54` | L | Current background task entry. 12 |
| `$1C58` | W | Number of task slots − 1. 12 |
| `$1C5A` | W | Background scheduler nesting/lock count. 12 |
| `$1C5C` | L | SSP value at entry of the outermost DOS call (points at the saved-register frame, 01 §2.2). |
| `$1C60` | W | SR to use when jumping to ERRJVC. |
| `$1C62` | L | SSP to use when jumping to ERRJVC. |
| `$1C66` | L | Previous trap #11 vector (chained). |
| `$1C6A` | L | Previous trap #10 vector (chained). |
| `$1C6E` | W | FILES value + 2. |
| `$1C70` | W | Sector-buffer size in bytes (`buffers` second value; default 1024). Block devices with larger sectors are rejected. |
| `$1C72` | B | Number of sector buffers. |
| `$1C73` | B | LASTDRIVE (0 = A). Raised automatically when drivers add drives beyond it. R |
| `$1C74` | B | Absolute maximum drive index (25). |
| `$1C75` | B | Number of drives (DPBs) created so far; next driver's first drive = this + 1. R |
| `$1C76` | W | `share` first value. |
| `$1C78` | W | `share` second value. |
| `$1C7A` | L | `share` entry size (= second × 12 + `$5C`). |
| `$1C7E` | 26 B | Drive-assignment table: logical drive n → physical drive (identity at boot; DRVXCHG). R |
| `$1C98` | L | File-table entry being operated on (for abort clean-up), 0 when none. Cleared on every DOS entry and exit. |
| `$1C9C` | L | Handle associated with `$1C98`. |
| `$1CA0` | B | EXEC-in-progress state (0, `$FF`, `$FE`, `$FD`; see 11). |
| `$1CA1-$1CB5` | — | Console line-input and EXEC scratch (owned by 30/11). |
| `$1CB6` | L | CLOCK device header used for date/time (−1 if none). |
| `$1CBA` | B | fflush mode (1 = on). |
| `$1CBC` | W | Character code treated as ^C (3, or `$0103` = disabled by `off=c`). |
| `$1CBE` | W | Code treated as ^N (`$0E`). |
| `$1CC0` | W | Code treated as ^P (`$10`). |
| `$1CC2` | W | Code treated as ^Q (`$11`). |
| `$1CC4` | W | Code treated as ^S (`$13`). |

Other bytes in `$1C00-$1FFF` are unused/reserved and remain zero. [inferred]

The kernel also reads, but does not own: `$0CBC` (MPU type, set by ROM, may be written by
the kernel's probe), `$ED0008`, `$ED001A`, `$ED001D` (SRAM).
