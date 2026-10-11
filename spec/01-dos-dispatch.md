# 01 — DOS call dispatch

How a `$FFxx` F-line DOS call is entered, executed and returned from; register and stack
conventions; error codes; the complete call-number table.

Confidence tags: **[verified]**, **[inferred]**, **[public]**.

---

## 1. Calling convention (caller's view)

```
        move.w  #arg2,-(sp)      ; arguments pushed right-to-left (last pushed = first arg)
        pea     arg1
        dc.w    $FFnn            ; DOS call nn
        addq.l  #N,sp            ; caller pops its own arguments
        tst.l   d0               ; d0.l = result (negative = error)
```

| Item | Rule |
|---|---|
| Opcode | One word `$FF00-$FFFF` (68000 F-line). Execution continues at the word after it. [verified] |
| Arguments | On the caller's **current** stack: USP if the caller was in user mode, SSP (above the exception frame) if in supervisor mode. The handler sees them at increasing addresses starting with the last-pushed item. [verified] |
| Result | d0.l. Negative values are error codes (§6). [verified] |
| Preserved | **d1-d7, a0-a6 are preserved** (restored from the saved frame), except where a call is documented to return extra values in registers (those calls write into the saved frame, §2.2). [verified] |
| Condition codes | **Not** set from d0: the caller's SR (incl. CCR) is restored by `rte`. Callers must test d0 themselves. [verified] |
| Mode | The call returns in the caller's original mode, unless the call itself changes the saved SR (e.g. SUPER, EXEC). [verified] |
| Re-entrancy | DOS calls may be issued from inside DOS handlers, drivers, hooks (nesting counted in INDOS). [verified] |

---

## 2. Entry and exit (kernel side)

### 2.1 Entry sequence

[verified]

1. The F-line exception enters the kernel dispatcher (also entered on privilege violation
   on 68010+, see §2.4). The kernel saves d0, a5, a6 and reads the opcode word at the
   stacked PC.
2. Opcode `< $FF00` → not a DOS call (§2.4).
3. Stacked PC += 2. The argument pointer is computed as "address just above the exception
   frame" (frame = SR + PC on 68000; SR + PC + format word when `$0CBC` ≠ 0).
4. Opcode `>= $FFF5` → special path without INDOS accounting (§4).
5. Otherwise the saved d0 is discarded, d1-d7/a0-a4 are pushed (so the frame of §2.2 is
   formed). If the saved SR has S = 0, the argument pointer := USP.
6. n = opcode & `$FF`; handler := long at `$1800 + 4n` (the RAM table, so it may have been
   replaced by INTVCS).
7. If INDOS (`$1C08`) = 0: `$1C5C` := current SP (the saved-register frame) and `$1C0A` := n.
8. INDOS += 1; `$1C98` := 0.
9. Handler called (subroutine call) with: **a6 = argument pointer, d0.l = n**
   (zero-extended), other registers = caller's values except a5 (scratch) and a6, running
   in supervisor mode on the SSP, interrupt mask unchanged.
10. On handler return: `$1C98` := 0; INDOS −= 1; if INDOS became 0, `$1C0A` := 0.
11. Deferred-event processing (§5).
12. All registers except d0 restored from the frame; d0 = handler's d0.
13. If `$1C14` (task-switch request) ≠ 0 and INDOS = 0 → background scheduler switch (12).
14. Return with `rte`. **Trace quirk**: if the restored SR has the T (trace) bit set, the
    kernel sets T in the current SR immediately before `rte`, so a trace exception occurs
    right after returning to the caller (single-stepping a DOS call works as one step).

### 2.2 Saved-register frame

`$1C5C` points to this frame for the **outermost** DOS call (nested calls do not update it):

| Offset | Content |
|---|---|
| +$00 | d1 |
| +$04 … +$18 | d2 … d7 |
| +$1C | a0 |
| +$20 | a1 |
| +$24 | a2 |
| +$28 | a3 |
| +$2C | a4 |
| +$30 | a5 |
| +$34 | a6 |
| +$38 | SR (exception frame) |
| +$3A | PC (return address, already past the opcode) |
| +$3E | (68010+: format/vector word, then) caller's stack |

Calls that return values in registers other than d0 (e.g. EXEC load-only returning
a0-a4) write them into this frame, and calls that change the mode or return address
(SUPER, EXEC, ctrl-C/abort handling) modify +$38/+$3A. [verified]
Quirk: because the frame pointer is only recorded at the outermost level, a nested call
that returns extra registers writes into the outermost caller's frame. [inferred]

### 2.3 Handlers installed by programs (hook mechanism)

The only hook mechanism is replacement of table entries with INTVCS
(`$FF25`, vector number `$FF00+n` or any value ≥ `$200` whose low byte is n), which returns
the old address so it can be chained. A replacement handler receives exactly the
environment of §2.1 step 9, returns its result in d0 via `rts`, and may freely use all
registers (they are restored by the dispatcher). To chain, a hook can jump to the old
handler with a6/d0 intact. [verified]
Note the alias pairs (§7) are independent table entries: hooking `$FF80` does not hook
`$FF50`. [verified]

### 2.4 F-line opcodes that are not DOS calls; privilege violation

[verified]

| Opcode | Behaviour |
|---|---|
| `MOVE SR,<ea>` (`$40C0-$40FF`), only reachable via the privilege-violation vector on 68010+ | The instruction word in the caller's code is rewritten to `MOVE CCR,<ea>` (`opcode | $0200`), the instruction cache is invalidated (CACR bit 3), and the instruction is restarted. (On a 68010 the CACR access itself would fault — a latent bug.) |
| `$FE00-$FEFF` (floating-point package calls, normally intercepted by FLOAT*.X before reaching the kernel) | trap #14 is raised with d7 = the opcode (error class `$FE`: "floating-point package not installed", abort only); if it ever returns, IOCS `$FF` (_ABORTJOB) then trap #14 again. |
| Any other F-line, any other privileged instruction | Registers restored and control transferred to the address in vector 4 (`$000010`, illegal instruction) with the original exception frame left on the stack. |

---

## 3. Unimplemented calls

Every unassigned table entry points to a stub that returns **d0 = −1** (`$FFFFFFFF`,
"invalid function"). It runs through the normal dispatch path (INDOS incremented). [verified]

---

## 4. Calls `$FFF5-$FFFF` (special path)

These never consult the table and never touch INDOS, `$1C5C`, or deferred events. They
preserve all registers except d0 (and except SUPER_JSR, below). Trace quirk of §2.1 applies. [verified]

| Call | Behaviour |
|---|---|
| `$FFF5` INDOSFLG | d0 = `$00001C08` (address of the INDOS word; the call-number byte is at +2). |
| `$FFF6` SUPER_JSR | Arg: long = routine address. The routine is called in supervisor mode with **all of the caller's registers** (d0 = caller's original d0, a5/a6 = caller's values). Its `rts` returns directly to the caller via `rte`; the registers it leaves are the caller's results. |
| `$FFF7` BUS_ERR | Args: long src, long dst, word size (1, 2 or 4). Copies one item src → dst with interrupts masked and bus errors trapped. d0 = 0 success; 2 = bus error on read; 1 = bus error on write; −1 = invalid size or odd address for size 2/4. |
| `$FFF8-$FFFF` | Background-process calls (12). If background processing is disabled (`$1C50`/`$1C54` = 0) every one returns d0 = −1. |

---

## 5. Deferred events and ctrl-C checking points

[verified]

* The dispatcher itself does not poll the keyboard. After **every** table-dispatched DOS
  call (any nesting depth) it:
  1. processes a pending BREAK (`$1C16` ≠ 0) — see 00 §5.4;
  2. if INDOS is now 0 and a power-switch event is pending (`$1C17`), processes it.
* ^C detection (break key code `$1CBC`) is done inside the console-input calls (30) and,
  only when `$1C12` = 1 (BREAK ON), at the end of READ/WRITE by peeking standard input.
  With `$1C12` = 2 (KILL) console input never aborts on ^C. 
* **Ctrl-C abort**: if an EXEC is in progress it is cleaned up (11); SSP := `$1C5C` (the
  outermost frame), standard input is flushed, `^C` CR LF is echoed, the frame's return PC
  is replaced by the CTRLVC vector (`$1BC4`); if that address lies inside the kernel's own
  memory block the frame's S bit is set (kernel routines run supervisor). INDOS := 0,
  `$1C0A` := 0, registers d1-d7/a0-a6 restored from the frame, **d0 = `$00002000`**, `rte`
  to the vector.
* **Abort (from Abort-Retry-Ignore)**: see 00 §5.3 (d0 = `$00004000`, to ERRJVC).

---

## 6. Error codes

Negative d0 values returned by DOS calls. "Seen" = the literal is produced somewhere in the
kernel [verified]; meanings are [public] (and consistent with the contexts observed).

| d0 | Hex (long) | Meaning | Seen |
|---|---|---|---|
| −1 | `$FFFFFFFF` | Invalid function code / general failure | yes |
| −2 | `$FFFFFFFE` | File not found | yes |
| −3 | `$FFFFFFFD` | Directory (path) not found | yes |
| −4 | `$FFFFFFFC` | Too many open files (no free handle) | yes |
| −5 | `$FFFFFFFB` | Cannot access directory or volume label as a file | yes |
| −6 | `$FFFFFFFA` | Handle not open | yes |
| −7 | `$FFFFFFF9` | Memory control blocks destroyed | no (public only) |
| −8 | `$FFFFFFF8` | Not enough memory | yes |
| −9 | `$FFFFFFF7` | Invalid memory block address | yes |
| −10 | `$FFFFFFF6` | Invalid environment | no (public only) |
| −11 | `$FFFFFFF5` | Invalid executable format | yes |
| −12 | `$FFFFFFF4` | Invalid access mode | yes |
| −13 | `$FFFFFFF3` | Invalid file name | yes |
| −14 | `$FFFFFFF2` | Invalid parameter | yes |
| −15 | `$FFFFFFF1` | Invalid drive | yes |
| −16 | `$FFFFFFF0` | Cannot remove current directory | yes |
| −17 | `$FFFFFFEF` | Device cannot do IOCTRL | yes |
| −18 | `$FFFFFFEE` | No more files | yes |
| −19 | `$FFFFFFED` | Cannot write (write-protected / read-only) | yes |
| −20 | `$FFFFFFEC` | Directory already exists | yes |
| −21 | `$FFFFFFEB` | Directory not empty | yes |
| −22 | `$FFFFFFEA` | Cannot rename | yes |
| −23 | `$FFFFFFE9` | Disk full | yes |
| −24 | `$FFFFFFE8` | Directory full | yes |
| −25 | `$FFFFFFE7` | Cannot seek | yes |
| −26 | `$FFFFFFE6` | Already in supervisor mode (SUPER) | yes |
| −27 | `$FFFFFFE5` | Thread/process name already exists | yes |
| −28 | `$FFFFFFE4` | Cannot send (receive buffer busy) | yes |
| −29 | `$FFFFFFE3` | Cannot create more background processes | yes |
| −32 | `$FFFFFFE0` | Lock table full | yes |
| −33 | `$FFFFFFDF` | File is locked | yes |
| −34 | `$FFFFFFDE` | Drive has open handles / busy | yes |
| −80 | `$FFFFFFB0` | File already exists | yes |

Values −30, −31, −35 … −79 are not produced by this kernel. [verified: no literal]
Device-driver error statuses are not DOS error codes; they go to trap #14 (00 §5.2).

---

## 7. Call-number table

Name column = public name. "Unimpl" = returns −1 via the stub (§3). Handlers shared between
two numbers are the *same* code (aliases kept for compatibility with older numbering).
All [verified] for implemented/unimplemented status; names [public].

| No. | Name | Notes |
|---|---|---|
| `$FF00` | EXIT | |
| `$FF01` | GETCHAR | |
| `$FF02` | PUTCHAR | |
| `$FF03` | COMINP | |
| `$FF04` | COMOUT | |
| `$FF05` | PRNOUT | |
| `$FF06` | INPOUT | |
| `$FF07` | INKEY | |
| `$FF08` | GETC | |
| `$FF09` | PRINT | |
| `$FF0A` | GETS | |
| `$FF0B` | KEYSNS | |
| `$FF0C` | KFLUSH | |
| `$FF0D` | FFLUSH | |
| `$FF0E` | CHGDRV | |
| `$FF0F` | DRVCTRL | |
| `$FF10` | CONSNS | |
| `$FF11` | PRNSNS | |
| `$FF12` | CINSNS | |
| `$FF13` | COUTSNS | |
| `$FF14-$FF16` | — | Unimpl |
| `$FF17` | FATCHK | |
| `$FF18` | HENDSP | |
| `$FF19` | CURDRV | |
| `$FF1A` | GETSS | |
| `$FF1B` | FGETC | |
| `$FF1C` | FGETS | |
| `$FF1D` | FPUTC | |
| `$FF1E` | FPUTS | |
| `$FF1F` | ALLCLOSE | |
| `$FF20` | SUPER | |
| `$FF21` | FNCKEY | |
| `$FF22` | KNJCTRL | |
| `$FF23` | CONCTRL | |
| `$FF24` | KEYCTRL | |
| `$FF25` | INTVCS | |
| `$FF26` | PSPSET | |
| `$FF27` | GETTIM2 | |
| `$FF28` | SETTIM2 | |
| `$FF29` | NAMESTS | |
| `$FF2A` | GETDATE | |
| `$FF2B` | SETDATE | |
| `$FF2C` | GETTIME | |
| `$FF2D` | SETTIME | |
| `$FF2E` | VERIFY | |
| `$FF2F` | DUP0 | |
| `$FF30` | VERNUM | |
| `$FF31` | KEEPPR | |
| `$FF32` | GETDPB | |
| `$FF33` | BREAKCK | |
| `$FF34` | DRVXCHG | |
| `$FF35` | INTVCG | |
| `$FF36` | DSKFRE | |
| `$FF37` | NAMECK | |
| `$FF38` | — | Unimpl |
| `$FF39` | MKDIR | |
| `$FF3A` | RMDIR | |
| `$FF3B` | CHDIR | |
| `$FF3C` | CREATE | |
| `$FF3D` | OPEN | |
| `$FF3E` | CLOSE | |
| `$FF3F` | READ | |
| `$FF40` | WRITE | |
| `$FF41` | DELETE | |
| `$FF42` | SEEK | |
| `$FF43` | CHMOD | |
| `$FF44` | IOCTRL | |
| `$FF45` | DUP | |
| `$FF46` | DUP2 | |
| `$FF47` | CURDIR | |
| `$FF48` | MALLOC | |
| `$FF49` | MFREE | |
| `$FF4A` | SETBLOCK | |
| `$FF4B` | EXEC | |
| `$FF4C` | EXIT2 | |
| `$FF4D` | WAIT | |
| `$FF4E` | FILES | |
| `$FF4F` | NFILES | |
| `$FF50-$FF58` | (old numbers) | Alias of `$FF80-$FF88` |
| `$FF59` | — | Unimpl (alias of unimplemented `$FF89`) |
| `$FF5A-$FF5C` | (old numbers) | Alias of `$FF8A-$FF8C` |
| `$FF5D-$FF5E` | — | Unimpl |
| `$FF5F` | (old number) | Alias of `$FF8F` |
| `$FF60-$FF79` | — | Unimpl |
| `$FF7A-$FF7F` | (old numbers) | Alias of `$FFAA-$FFAF` |
| `$FF80` | SETPDB | |
| `$FF81` | GETPDB | |
| `$FF82` | SETENV | |
| `$FF83` | GETENV | |
| `$FF84` | VERIFYG | |
| `$FF85` | COMMON | |
| `$FF86` | RENAME | |
| `$FF87` | FILEDATE | |
| `$FF88` | MALLOC2 | |
| `$FF89` | — | Unimpl |
| `$FF8A` | MAKETMP | |
| `$FF8B` | NEWFILE | |
| `$FF8C` | LOCK | |
| `$FF8D-$FF8E` | — | Unimpl |
| `$FF8F` | ASSIGN | |
| `$FF90-$FFA9` | — | Unimpl |
| `$FFAA` | FFLUSH_SET | Arg word: −1 = query; otherwise new fflush mode (stored as a byte in `$1CBA`). d0 = previous mode. [verified behaviour] |
| `$FFAB` | OS_PATCH | |
| `$FFAC` | GETFCB | |
| `$FFAD` | S_MALLOC | |
| `$FFAE` | S_MFREE | |
| `$FFAF` | S_PROCESS | |
| `$FFB0-$FFEF` | — | Unimpl |
| `$FFF0` | EXITVC | **Not a function**: the table entry holds the current exit vector. Issuing the call jumps into that routine as if it were a handler (unspecified; do not use). |
| `$FFF1` | CTRLVC | Same — holds the ctrl-C vector. |
| `$FFF2` | ERRJVC | Same — holds the error-abort vector. |
| `$FFF3` | DISKRED | |
| `$FFF4` | DISKWRT | |
| `$FFF5` | INDOSFLG | Special path (§4) |
| `$FFF6` | SUPER_JSR | Special path (§4) |
| `$FFF7` | BUS_ERR | Special path (§4) |
| `$FFF8` | OPEN_PR | Background (12); table entry `$F8` is a scheduler hook, not the handler |
| `$FFF9` | KILL_PR | Background (12); table entry `$F9` is a scheduler hook |
| `$FFFA` | GET_PR | Background (12) |
| `$FFFB` | SUSPEND_PR | Background (12) |
| `$FFFC` | SLEEP_PR | Background (12) |
| `$FFFD` | SEND_PR | Background (12) |
| `$FFFE` | TIME_PR | Background (12) |
| `$FFFF` | CHANGE_PR | Background (12); table entry `$FF` is a scheduler hook |

Initial table contents for entries that are not handlers: `$F0-$F2` = the kernel's
default exit routine (00 §4); `$F5-$F7` = unimplemented stub; `$F8`, `$F9`, `$FF` = a
routine that just returns; `$FA-$FE` = unimplemented stub. [verified]
