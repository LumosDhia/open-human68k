# 30 — Character I/O, console control, line editing, break handling

Scope: DOS calls $FF01–$FF13, $FF0A GETS, $FF1A GETSS, $FF18 HENDSP,
$FF21 FNCKEY, $FF22 KNJCTRL, $FF23 CONCTRL, $FF24 KEYCTRL, and the
Ctrl-C / Ctrl-P / Ctrl-S machinery. BREAKCK ($FF33) is specified in
`40-misc-calls.md` §BREAKCK; its effect on character I/O is described here.

General DOS-call conventions (see `01-dos-dispatch.md`): arguments are
pushed on the caller's stack (word arguments as words, pointers/longs as
longs, first argument at the lowest address); the result is returned in
`d0.l`; every other register is preserved. When a handler below "does not
set d0", the caller sees whatever value the dispatcher left in d0, which is
the low byte of the call number zero-extended (e.g. `$00000009` for PRINT)
**[verified]**. Programs must not rely on that, but a compatible kernel
should reproduce it for the calls named as such.

---------------------------------------------------------------------------

## 1. Architecture: handles, devices and IOCS

### 1.1 Standard handles used

| Handle | Name   | Used by |
|--------|--------|---------|
| 0 | stdin  | GETCHAR, INPOUT(input), INKEY, GETC, GETS, GETSS, KEYSNS, KFLUSH, all Ctrl-C/S/P peeks |
| 1 | stdout | GETCHAR echo, PUTCHAR, INPOUT(output), PRINT, GETS/GETSS echo, "^C" message |
| 2 | stderr | not used by any call in this file |
| 3 | stdaux | COMINP, COMOUT, CINSNS, COUTSNS |
| 4 | stdprn | PRNOUT, PRNSNS, printer echo (Ctrl-P) |

**[verified]** All DOS character calls go through these *handles*, i.e.
through whatever file or device each handle currently refers to. None of
$FF01–$FF13, GETS, GETSS calls IOCS directly. Redirecting a handle
(DUP2, EXEC with redirected handles, CTTY) therefore redirects these calls.

### 1.2 Primitive operations on a handle

The calls are built from five primitives. "Char device" means the handle's
device-information byte has bit 7 set (see `21-file-io.md`); a request
packet is the standard 26-byte ($1A) request header of
`03-device-drivers.md` (+0 length=$1A, +2 command, +3 status low byte,
+4 status high byte, +13 one-byte data, +14 buffer pointer, +18 count).

| Primitive | If handle is a char device | If handle is a file/block device |
|-----------|----------------------------|----------------------------------|
| **peek(h)** | Issue command 5 (non-destructive read). If the driver returns a non-zero status, the kernel's device-error (abort/retry/ignore) handler is invoked and the command retried per its answer. Result = byte at +13, zero-extended; **0 means "nothing available"**. | Result = $20 (i.e. "something available") without touching the file. |
| **read1(h)** | NUL device (info bit 2): result 0. Otherwise one driver call, command 4, count 1 — **always raw**: the cooked-mode processing of the READ call (§6.3) is *not* applied. Device errors go through the abort/retry/ignore handler. | Read 1 byte from the file. |
| **write1(h,c)** | NUL device: nothing. Otherwise one driver call, command 8 (never 9), count 1 — raw, without the §5.3 cooked-write checks. | Write 1 byte to the file. |
| **flushin(h)** | Issue command 7 (input flush) to the device; status ignored. | No-op. |
| **status(h,cmd)** | Issue *cmd* (5 = input status via non-destructive read, 10 = output status) directly to the driver, **without** the device-error handler. Result $FF if request byte +3 is 0 after the call, else $00. | Result $FF. |

read1 returns the byte zero-extended; if the read transferred 0 bytes the
result is 0; if it failed the (negative) error code is returned as the
"character" **[verified]**. write1 returns the byte count reported by the
driver/file layer (normally 1) or a negative error.

### 1.3 The console device and IOCS

The built-in CON driver (see `03-device-drivers.md`) is the only place
where ordinary console traffic meets IOCS:

* Output (commands 8/9): every byte is passed to IOCS `_B_PUTC` ($20).
  Output status (command 10) always reports ready.
* Input: the driver keeps a small "key expansion buffer". When empty it
  polls IOCS `_B_KEYSNS` ($01); when a key is present it fetches it with
  `_B_KEYINP` ($00) and translates it (§8) into 0, 1 or more bytes in the
  buffer (function-key strings, kana conversions, code input…). Command 4
  (read) blocks until it has delivered the requested count (busy-waits,
  does not call CHANGE_PR); command 5 returns the next buffered byte at +13
  or 0 if nothing; command 6 always reports ready; command 7 discards
  every pending key (drains both the expansion buffer and the IOCS
  buffer). **[verified]** Consequently a NUL byte can never be delivered
  by CON.

The following calls bypass handles and talk to IOCS or to the CON
driver's internal state directly: CONCTRL, KEYCTRL, FNCKEY, HENDSP.
KEYCTRL modes 0/1 read the *same* expansion buffer as CON's read command.

---------------------------------------------------------------------------

## 2. Control-key variables (system work area) **[verified]**

| Address | Size | Meaning | Default |
|---------|------|---------|---------|
| $1C12 | byte | Break-check mode: 0 = OFF, 1 = ON, 2 = KILL (see §4). Held at 2 during boot, then set from CONFIG `BREAK=` (default OFF). | 0 after boot |
| $1C13 | byte | Printer-echo flag: non-zero ⇒ every echoed/console-output byte is also written to handle 4. Toggled by Ctrl-P (`not.b`, so values are $00/$FF), cleared by Ctrl-N. | 0 |
| $1CBC | word | Break key code (Ctrl-C) | $0003 |
| $1CBE | word | Printer-echo-off key (Ctrl-N) | $000E |
| $1CC0 | word | Printer-echo-toggle key (Ctrl-P) | $0010 |
| $1CC2 | word | Resume key (Ctrl-Q) — stored but never compared by the kernel | $0011 |
| $1CC4 | word | Pause key (Ctrl-S) | $0013 |

Key comparisons are made between the **word** stored here and the input
byte zero-extended to a word. A key is "disabled" by setting the high byte
of its word to 1 (e.g. $0103): it then never matches. BREAKCK sub-modes
$01xx–$05xx and a CONFIG.SYS directive (see `02-config-sys.md`) do this.
GETSS additionally forces a mismatch by OR-ing $8000 into the input before
comparing (§6.1).

---------------------------------------------------------------------------

## 3. The individual calls

Notation: `peek`, `read1`, `write1`, `flushin`, `status` as in §1.2;
`echo(c)` = `write1(1,c)` then, if $1C13≠0, `write1(4,c)`;
`brk(c)` = the break test of §4.2; `wait-key` = repeat {peek(0); if
non-zero → read1(0); if the result is non-zero return it; otherwise call
DOS $FFFF CHANGE_PR and retry} (§4.4).

### $FF01 GETCHAR — read stdin with echo
In: none. Out: d0.l = character (zero-extended).
1. c = wait-key.
2. If c = Ctrl-P key: toggle $1C13, go to 1 (key swallowed).
   If c = Ctrl-N key: clear $1C13, go to 1.
3. brk(c) (Ctrl-C ⇒ abort unless mode 2).
4. echo(c) — raw byte, control characters are *not* expanded.
5. Return c. **[verified]**

### $FF02 PUTCHAR — write to stdout
In: word `code` (low byte output). Out: d0.l = 0.
1. echo(code low byte).
2. k = peek(0) (key is **not** consumed).
3. If k = Ctrl-S key: consume it (peek+read1), then k = wait-key
   (the resume key is consumed whatever it is), continue with step 4 using
   that k. If k = Ctrl-P key: perform one non-blocking read of stdin
   (peek; if non-zero read1) — normally this consumes the Ctrl-P — and
   toggle $1C13. If k = Ctrl-N key: same non-blocking read, clear $1C13.
4. Otherwise brk(k): if k is the Ctrl-C key and mode ≠ 2, abort (§4.3).
   Any other key stays in the input buffer.
5. Return 0. **[verified]**

Quirk: after a Ctrl-S pause, if the resuming key is Ctrl-P/Ctrl-N the
"consume" step of 3 reads one *additional* pending key (if any) and
discards it. Any key, not only Ctrl-Q, resumes output; the resume key is
discarded unless it is Ctrl-C (abort), Ctrl-P or Ctrl-N.

### $FF03 COMINP — read stdaux
In: none. Out: d0.l = byte (or negative error from the read).
Loop: if status(3, cmd 5) = $FF → return read1(3). Else k = peek(0),
brk(k), repeat. (No CHANGE_PR in this loop.) **[verified]**

### $FF04 COMOUT — write stdaux
In: word `code`. Out: d0.l = result of write1 (1 on success, negative
error code on failure).
Loop until status(3, cmd 10) = $FF, doing peek(0)+brk between polls; then
write1(3, code). **[verified]**

### $FF05 PRNOUT — write stdprn
Same as COMOUT using handle 4 and PRNSNS readiness. **[verified]**

### $FF06 INPOUT — raw console I/O
In: word `code`. Out: d0.l.
* low byte of `code` = $FF: non-blocking input. k = peek(0); if k≠0,
  return read1(0); else return 0.
* low byte = $FE: return peek(0) (key **not** consumed; 0 if none).
* otherwise: echo(low byte); return 0.
No Ctrl-C/Ctrl-P/Ctrl-S processing at all. **[verified]**
Note: because only the low byte is tested, $00FF, $01FF, … all mean
"input". A character value of $FE/$FF cannot be output with INPOUT.

### $FF07 INKEY — wait for a key, no echo, no checks
In: none. Out: d0.l = wait-key result. Pending BREAK-key and power-switch
events are processed (§4.5) but the key value itself is never interpreted.
**[verified]**

### $FF08 GETC — wait for a key, no echo, with break check
In: none. Out: d0.l.
c = wait-key; if c = Ctrl-C key: abort if mode ≠ 2, otherwise *discard*
the key and read again. If c = Ctrl-P/Ctrl-N: update $1C13 and read
again. Else return c. **[verified]** (GETC therefore never returns the
Ctrl-C code, unlike GETCHAR in KILL mode.)

### $FF09 PRINT — write NUL-terminated string
In: long `ptr`. Out: d0.l = 0 (or call-number residue $00000009 if the
string is empty — the handler does not set d0 then).
For each byte until NUL: PUTCHAR semantics (echo + peek/Ctrl-S/Ctrl-C
check **per character**). **[verified]**

### $FF0A GETS / $FF1A GETSS — line input
See §6.

### $FF0B KEYSNS — key available?
In: none. Out: d0.l = 0 (no key) or $FFFFFFFF (key available).
k = peek(0). If k = 0 → 0. If k = Ctrl-P key: consume it (non-blocking
read), toggle $1C13, return 0. If Ctrl-N: consume, clear $1C13, return 0.
Otherwise brk(k) (Ctrl-C ⇒ abort unless mode 2) and return −1; the key is
left in the buffer. **[verified]**

### $FF0C KFLUSH — flush stdin, then optionally read
In: word `mode`, followed (for some modes) by the argument of the
target call. Out: as below.
First flushin(0). Then by `mode`:

| mode | Action | Further argument (immediately after `mode` on the stack) |
|------|--------|-------------------------------------------|
| 1 | as GETCHAR | — |
| 6 | as INPOUT | word `code` |
| 7 | as INKEY | — |
| 8 | as GETC | — |
| $0A | as GETS (not GETSS) | long buffer pointer |
| other | return 0 | — |
**[verified]**

### $FF10 CONSNS / $FF11 PRNSNS / $FF12 CINSNS / $FF13 COUTSNS
In: none. Out: d0.l = $FF (ready) or 0 (not ready).

| Call | = |
|------|---|
| CONSNS | status(1, cmd 10) — stdout output status |
| PRNSNS | status(4, cmd 10) |
| CINSNS | status(3, cmd 5) — stdaux input status |
| COUTSNS | status(3, cmd 10) |

Non-character-device handles (files) always report $FF. **[verified]**

---------------------------------------------------------------------------

## 4. Break (Ctrl-C) handling

### 4.1 Break-check mode ($1C12)

| Mode | Name | Effect |
|------|------|--------|
| 0 | OFF  | Ctrl-C is checked only by the character calls listed in §4.2. |
| 1 | ON   | As OFF, **plus** after every READ ($FF3F) or WRITE ($FF40) on a *file or block device* (not on a char device), and after internal file reads/writes that use the same path, the kernel does peek(0) and aborts if the key is the Ctrl-C key. |
| 2 | KILL | Ctrl-C never aborts anything. GETCHAR/KEYSNS/PUTCHAR treat it as an ordinary key; GETC discards it; GETS enters it as a control character "^C". |
**[verified]**

### 4.2 Where the break key is tested

| Call | What is compared | Consumed? |
|------|------------------|-----------|
| GETCHAR, GETC, GETS (typed keys and the argument key of ESC T/W/F) | the key just read | yes |
| PUTCHAR, PRINT (each char), cooked WRITE to a char device (each byte), KEYSNS, COMINP/COMOUT/PRNOUT wait loops | peek(0) | no (but the abort flushes stdin) |
| READ/WRITE on files, mode 1 only | peek(0) | no |
| INKEY, INPOUT, GETSS, CONCTRL, KEYCTRL | never | — |

### 4.3 Abort sequence ("^C")
When a break is taken **[verified]**:
1. If an EXEC load is in progress (child being loaded but not started),
   its file handle is closed and the partially-built child is released;
   if that cleanup itself fails, the outer DOS call simply returns to its
   caller with d0 = $00002000 and no further action. (Details: 11-process.)
2. The supervisor stack is reset to the frame of the **outermost** active
   DOS call (nested calls are unwound).
3. flushin(0).
4. The string `^C` CR LF (bytes $5E $43 $0D $0A) is written with echo()
   (stdout, plus printer if echo is on).
5. The return PC of that outermost frame is replaced by the contents of
   the CTRLVC vector ($1BC4, i.e. the $FFF1 entry of the DOS vector
   table). If that address is lower than the end of the kernel's resident
   image, the S bit is forced on in the returned SR (so the kernel's own
   default handler runs in supervisor mode); otherwise the SR of the
   original call is used unchanged. ("End of the resident image" is the
   boundary of the supervisor-protected system area: the end of the
   kernel's static allocations rounded up to a multiple of 8 KB, the same
   value the kernel programs into the hardware area-set register at boot.)
6. INDOS count ($1C08) and current-call byte ($1C0A) are cleared.
7. Return-from-exception to that address with d1–d7/a0–a6 restored to the
   values they had when the outermost DOS call was made and
   **d0 = $00002000**.

The default CTRLVC handler terminates the current process (EXIT) — see
`11-process.md`.

### 4.4 Waiting and the background scheduler
Every blocking key wait in GETCHAR, INKEY, GETC, GETS/GETSS (and KFLUSH
modes mapping to them) calls DOS $FFFF (CHANGE_PR) once per unsuccessful
poll, letting background tasks run; when the background system is not
enabled that call returns immediately, so the wait is a busy poll.
**[verified]**

Quirk **[verified]**: a byte value 0 read from stdin is treated as "no key
yet". If stdin is redirected to a file, peek always says "available", and
at end-of-file read1 returns 0, so GETCHAR/INKEY/GETC/GETS **loop forever
at EOF** of a redirected file, and NUL bytes in the file are skipped.

### 4.5 BREAK key and power switch (asynchronous events)
The kernel hooks two exception vectors at boot **[verified]**:

* **trap #11 (BREAK key, vector $AC)**: records the event code (d0 at
  the trap, with bit 7 set) unless one is already pending. If no DOS call
  is in progress it is processed immediately, otherwise when the
  outermost DOS call returns, or at the next peek(0). Processing: if bit 0
  of the code is 0 the disk buffers are flushed; if bit 0 is 1 the input
  of stdin and stdaux is flushed (command 7 to handles 0 and 3). Then
  control is passed to the previous trap #11 handler (as if the trap had
  been taken there), whatever it does next is the ROM's behaviour.
* **trap #10 (power switch / reset request, vector $A8)**: records d0 and
  sets a pending flag. If no DOS call is active, or as soon as a waiting
  character call notices the flag (GETCHAR, INKEY, GETS loops, PUTCHAR and
  the other break-check points test it first), the kernel waits briefly,
  closes every open handle, flushes all disk buffers and passes control to
  the previous trap #10 handler with the recorded d0. The interrupted
  call does not return.

---------------------------------------------------------------------------

## 5. Echo and output rules

### 5.1 echo()
Writes the byte to handle 1, then to handle 4 if $1C13 ≠ 0. Bytes are
written raw (GETCHAR echoes a control character as itself).

### 5.2 Line editor echo (GETS/GETSS, cooked console READ)
Output goes to handle 1 (GETS/GETSS) or directly to the device of the
input handle (cooked READ, §6.3), plus handle 4 if printer echo is on.
Control characters (< $20) entered into the line are displayed as `^`
followed by (char + $40); everything else is displayed raw.

### 5.3 Cooked WRITE to a character device
WRITE ($FF40) of n bytes to a char-device handle whose device-info byte
has neither bit 2 (NUL device: returns n without doing anything) nor bit 5
(raw/binary: one driver call for all n bytes) set, is performed byte by
byte: write the byte to that handle's device, then to handle 4 if $1C13 ≠
0, then the PUTCHAR check (step 2–4 of PUTCHAR: Ctrl-S pause, Ctrl-P/N,
Ctrl-C). Returns n. **[verified]** Note the printer echo happens even if
the handle itself is PRN (the byte is printed twice).

---------------------------------------------------------------------------

## 6. Line input: GETS ($FF0A), GETSS ($FF1A)

### 6.1 Call interface **[verified]**
In: long `buf`. Out: d0.l = number of bytes in the entered line (0–255).

Buffer layout:

| Offset | Size | Direction | Meaning |
|--------|------|-----------|---------|
| +0 | byte | in | `max`: maximum number of bytes accepted (0–255). |
| +1 | byte | out | number of bytes entered (= d0). |
| +2 | … | in/out | in: **template** — the previous line, NUL-terminated; out: the entered line followed by a NUL byte. |

The caller should provide **max + 3 bytes at least, and 258 bytes to be
safe**: on entry the kernel reads 256 bytes starting at +2, and the ESC J
and ESC F commands write 256 bytes starting at +2 regardless of `max`
**[verified]**. The template is the byte string at +2 up to its first NUL;
an uninitialised buffer gives a garbage template.

GETS vs GETSS:

| | GETS | GETSS |
|-|------|-------|
| Ctrl-C | aborts (unless KILL; in KILL it is entered as "^C") | entered as a control character, never aborts |
| Ctrl-P / Ctrl-N | toggle / clear printer echo, not entered | entered as control characters |
| ESC J | "@" style new template (§6.2) | erase-style new template |

(GETSS ORs $8000 into each key before comparing with the control-key
words, so no control key ever matches.)

Input is taken byte-by-byte from handle 0 (peek + read1, with CHANGE_PR
while waiting; NUL bytes are ignored). Echo goes to handle 1 (+printer).

### 6.2 Editing state and keys
State: the line being built (≤ `max` bytes), a **template pointer** into
the user buffer's template (starts at +2), and an **insert flag**
(starts OFF). On entry, and on every editing command except ESC P, the
insert flag is turned OFF and KEYCTRL(4, flag) is issued so the INS LED
shows the state (ESC P passes $FF when turning it on).

| Key received | Action |
|--------------|--------|
| CR ($0D) | Echo CR only (no LF). Store NUL after the line, length at +1, copy line+NUL to +2. Return length. |
| LF ($0A) | Ignored. |
| BS ($08) | Insert OFF. If the line is not empty, delete its last character (1 or 2 bytes, §6.4), output BS SP BS once per display column of that character, and move the template pointer back by the same number of bytes (never before +2). |
| ESC ($1B) | Read one more key **without** any Ctrl-C/P/N processing, then see the ESC table below. |
| any other byte | "Normal character" rules below. |

Normal character c:
1. If the line already holds `max` bytes, or c is a Shift-JIS lead byte
   ($80–$9F, $E0–$FF) and only one byte of room is left: output BEL ($07)
   to the echo destination, flush pending input of the input handle
   (command 7 — type-ahead is lost), and ignore c.
2. If insert is OFF and the template pointer is not at the template's NUL:
   advance the template pointer by one byte; if the template byte skipped
   was a lead byte, **overwrite the following template byte (its trail
   byte) in the user buffer with a space ($20)** so the template stays
   character-aligned (quirk, modifies the caller's buffer).
   If insert is ON the template pointer does not move.
3. Append c to the line and echo it (control chars as ^X).
A trail byte of a double-byte character arrives as a separate key and is
handled by the same rules (step 1 may wrongly treat a trail byte in
$80–$9F/$E0–$FC as a lead byte) **[verified]**.

ESC + key (key is upper-cased by clearing bit 5 first):

| ESC + | Default key (§7) | Action |
|-------|------------------|--------|
| S | F1, → | Copy one template character (1 or 2 bytes) to the line, if it fits (line length + its byte count ≤ max). |
| T | F2 | Read an argument key (with Ctrl-C/P/N processing; a lead byte reads a second byte). Search the template *starting after the current template character* for it; if found, copy everything from the template pointer up to (not including) it. **No max check** (quirk). Not found: nothing. |
| U | F3, ↓ | Copy template characters byte by byte until the template NUL or the line is full (may split a double-byte character at the limit). |
| V | F4, DEL | Skip one template character (no output). |
| W | F5 | Read argument key as for T; skip template up to (not including) its next occurrence after the current character. |
| E | F6, HOME | Erase the displayed line (BS SP BS per column), empty the line, reset the template pointer to the start. Template unchanged. |
| J | F7, ↑ | GETS: output `@`, BS, then BS once per display column of the line, then LF (cursor ends one line down, at the column where input started; the old text stays visible followed by `@`). GETSS: erase the displayed line instead. In both: the current line (NUL-terminated, plus whatever followed it in the 256-byte work area) becomes the new template by copying 256 bytes to buf+2; line emptied; template pointer reset. |
| P | F8, INS | Toggle insert flag; KEYCTRL(4, 0 or $FF). |
| F | F9 | Read argument key; erase displayed line; current line becomes the new template (256-byte copy as for J); line emptied; then copy from the template up to (not including) the first occurrence of the key after its first character (**no max check**). If not found the line stays empty. |
| other byte $40–$5F (after upper-casing, so also $60–$7F) | e.g. F10 = ESC Z | Enter (byte AND $1F) as a control character (ESC Z ⇒ Ctrl-Z, ESC [ ⇒ ESC). |
| byte < $20 | — | Enter that control byte literally (ESC Ctrl-C enters ^C without aborting). |
| anything else | — | Ignored (both bytes swallowed). |

Ctrl-S has no special meaning inside GETS/GETSS (entered as ^S).

### 6.3 Line editor used by READ on the console
READ ($FF3F) from a char-device handle whose device-info byte has bit 0
(console input) set and bit 5 (raw) clear does **not** call the driver
for the requested count. Instead **[verified]**:
* The kernel keeps one internal line buffer (max 255) shared by all
  handles. If it holds no pending bytes, the line editor of §6.2 is run on
  it with GETS rules (Ctrl-C active, "@" style ESC J), input from *that
  handle*, echo to *that handle's device* (+ printer). The previous line
  stays in the buffer and serves as the template. CR LF is appended to
  the entered line.
* READ then returns bytes from that pending line, one at a time into the
  caller's buffer, stopping after the last byte of the line (the LF) or
  when the requested count is satisfied. The remainder stays pending for
  the next READ.
* If a delivered byte is Ctrl-Z ($1A), it is stored and counted, the rest
  of the pending line is discarded and READ returns.
* Quirk: the kernel tracks "bytes still pending" in a way that only looks
  at its low 8 bits when deciding to stop, so when exactly 256 bytes are
  pending after a byte is delivered (a 255-byte line: 257 bytes with CR
  LF) READ returns after that single byte; the rest is delivered by the
  next READ **[verified]**.
* FFLUSH ($FF0D) with fflush mode on also discards the pending remainder.
READ on other char devices in cooked mode reads one byte at a time until
the count is reached, a read returns 0 bytes, or the byte just stored is
$1A or $0A (both stored and counted). Raw mode (bit 5) reads the full
count in one driver call. NUL device (bit 2) returns 0.

### 6.4 Character width table used by the editor **[verified]**

| First byte | Bytes | Display columns |
|------------|-------|-----------------|
| $00–$1F | 1 | 2 (shown as ^X) |
| $20–$7F | 1 | 1 |
| $80 | 2 | 1 |
| $81–$9F | 2 | 2 |
| $A0–$DF | 1 | 1 |
| $E0–$EF | 2 | 2 |
| $F0–$FF | 2 | 1 |

To delete "the last character" the editor rescans the line from its
start, treating $80–$9F and $E0–$FF as lead bytes.

---------------------------------------------------------------------------

## 7. FNCKEY ($FF21) and the function-key table

### 7.1 Call
In: word `mode_key` (high byte = mode, low byte = key number), long `buf`.
(The word is read as two bytes: byte at the lower address = mode.)
Out: d0.l = 0, or −1 ($FFFFFFFF) if the key number is invalid.

* mode = 0: copy the definition of key *n* from the table into `buf`.
* mode ≠ 0: copy from `buf` into the table. Afterwards, unless the key is
  one of the 6-byte editing keys (21–32), the kernel calls KNJCTRL(1,0)
  and redraws the function-key line (if display mode is 0 or 1).
Exactly the entry size is copied in both directions; no terminator
check **[verified]**.

| n | Keys | Entry size | Bytes copied |
|---|------|-----------|--------------|
| 0 | whole table | — | 712 ($2C8) bytes: entries 1–32 in order |
| 1–10 | F1–F10 | 32 | 32 |
| 11–20 | SHIFT+F1–F10 | 32 | 32 |
| 21–32 | ROLLUP, ROLLDOWN, INS, DEL, ↑, ←, →, ↓, CLR, HELP, HOME, UNDO | 6 | 6 |
| ≥33 | — | — | returns −1 |

### 7.2 Entry format
* 32-byte entries (F-keys): if byte 0 is $FE, bytes 1–7 are a display
  label and the string sent by the key starts at byte 8 (up to 24 bytes,
  NUL-terminated or ending at the entry end). Otherwise the whole entry is
  the string (up to 32 bytes, NUL-terminated or ending at the entry end).
* 6-byte entries: string only (no label convention).
* The function-key line (screen line 31) shows, for each F-key, the
  **first 8 bytes of the entry** (5 bytes in 512-dot-wide screen modes)
  printed literally with IOCS `_B_PUTMES`, including the $FE byte.

### 7.3 Default table **[verified]** (data observable via FNCKEY mode 0)

| Key | Contents |
|-----|----------|
| F1 | $FE, " C1    ", ESC "S" |
| F2 | $FE, " CU    ", ESC "T" |
| F3 | $FE, " CA    ", ESC "U" |
| F4 | $FE, " S1    ", ESC "V" |
| F5 | $FE, " SU    ", ESC "W" |
| F6 | $FE, "VOID   ", ESC "E" |
| F7 | $FE, "NWL    ", ESC "J" |
| F8 | $FE, "INS    ", ESC "P" |
| F9 | $FE, "N&CU   ", ESC "F" |
| F10 | $FE, "EOF    ", ESC "Z" |
| SHIFT+F1 | "DIR A:*.*" CR |
| SHIFT+F2 | "DIR B:*.*" CR |
| SHIFT+F3 | "COPY " |
| SHIFT+F4 | "DEL " |
| SHIFT+F5 | "REN " |
| SHIFT+F6 | "DIR A:*.*/W" CR |
| SHIFT+F7 | "DIR B:*.*/W" CR |
| SHIFT+F8 | "TYPE " |
| SHIFT+F9 | "DATE" CR |
| SHIFT+F10 | "TIME" CR |
| ROLLUP | ESC "E+" CR |
| ROLLDOWN | ESC "E-" CR |
| INS | ESC "P" |
| DEL | ESC "V" |
| ↑ | ESC "J" |
| ← | BS ($08) |
| → | ESC "S" |
| ↓ | ESC "U" |
| CLR | "CLS" CR |
| HELP | "HIS" CR |
| HOME | ESC "E" |
| UNDO | ESC "U" CR |

(Labels are exactly 7 bytes, space padded; unused bytes are $00.)

---------------------------------------------------------------------------

## 8. Console keyboard translation (CON input) **[verified unless noted]**

This is CON driver behaviour (owned by `03-device-drivers.md`), summarised
because it determines what the character calls return.

On each key from `_B_KEYINP` (d0 = scan code << 8 | ASCII) the shift
status (`_B_SFTSNS`) is sampled and:

1. **Code-input mode** (shift-status bit 6 set; meaning of the bit
   [inferred]): control bytes (< $20, $7F) pass through; 0–9 and A–F
   (upper case only) are accumulated as hex digits; after the 4th digit
   the value v is emitted: v < $100 → 1 byte; $8000–$80FF and
   $F000–$F5FF → 2 bytes as-is; $0100–$7FFF → treated as JIS, converted
   with IOCS `_JISSFT` ($A1); $8100–$EFFF and ≥ $F600 → `_SFTJIS` ($A0)
   then `_JISSFT`. Any other key resets the accumulator; a key with ASCII
   0 is looked up as a function key (step 5).
2. **Full-width mode** (bit 14): printable characters are converted with
   IOCS $A2 to 2-byte full-width codes; a following half-width dakuten
   ($DE) / handakuten ($DF) modifies a preceding convertible kana (or emits
   a stand-alone full-width mark $814A/$814B). With romaji (bit 5) active
   input goes through IOCS $A3 first.
3. **Hiragana mode** (bit 13): half-width katakana $A6–$AF and $B1–$DD
   become the 2-byte sequence $80, byte.
4. Otherwise (optionally through romaji conversion, IOCS $A3) the ASCII
   byte is emitted.
5. A key whose ASCII code is 0 is a candidate function/editing key: its
   scan code is mapped (F1–F10 = $63–$6C; ROLLUP $38, ROLLDOWN $39,
   INS $5E, DEL $37, ↑ $3C, ← $3B, → $3D, ↓ $3E, CLR $3F, HELP $54,
   HOME $36, UNDO $3A → FNCKEY numbers 21–32). For F1–F10:
   * CTRL held: CTRL+F1…F4 → DRVCTRL($0100 + n) for drive n (1 = A:,
     eject); CTRL+F5 → FFLUSH then OS_PATCH($0F03,0), ($0F02,0),
     ($0F01,0); CTRL+F7 → cycle function-key display mode 0→1→2→0 (3→0);
     other CTRL+F-keys do nothing. Nothing is put in the buffer.
   * SHIFT held: use entry n+10.
   The entry's string (skipping a $FE label) is placed in the expansion
   buffer.
6. Escape-sequence extensions registered with IOCS for console output:
   `ESC [ 6 n` (device status report) places `ESC [ row ; col R`
   (1-based decimal, no leading zeros) into the expansion buffer;
   `ESC [ > 1 h` sets function-key display mode 3 and `ESC [ > 1 l` sets
   mode 0 (as CONCTRL 14).

---------------------------------------------------------------------------

## 9. CONCTRL ($FF23)

In: word `mode`, then mode-specific arguments (the kernel always reads a
long after `mode`; word arguments are its high and low halves).
Out: d0.l. Mode ≥ $13 → −1. **[verified]**

| mode | Arguments | Action | Return |
|------|-----------|--------|--------|
| 0 | word code | IOCS `_B_PUTC` ($20), d1.w = code | IOCS d0 |
| 1 | long str | IOCS `_B_PRINT` ($21), a1 = str | IOCS d0 |
| 2 | word attr | IOCS `_B_COLOR` ($22) | IOCS d0 |
| 3 | word x, word y | IOCS `_B_LOCATE` ($23), d1 = x, d2 = y | IOCS d0 |
| 4 | — | IOCS `_B_DOWN_S` ($24) | IOCS d0 |
| 5 | — | IOCS `_B_UP_S` ($25) | IOCS d0 |
| 6 | word n | IOCS `_B_UP` ($26) | IOCS d0 |
| 7 | word n | IOCS `_B_DOWN` ($27) | IOCS d0 |
| 8 | word n | IOCS `_B_RIGHT` ($28) | IOCS d0 |
| 9 | word n | IOCS `_B_LEFT` ($29) | IOCS d0 |
| 10 | word m | IOCS `_B_CLR_ST` ($2A) | IOCS d0 |
| 11 | word m | IOCS `_B_ERA_ST` ($2B) | IOCS d0 |
| 12 | word n | IOCS `_B_INS` ($2C) | IOCS d0 |
| 13 | word n | IOCS `_B_DEL` ($2D) | IOCS d0 |
| 14 | word m | Function-key display mode (below) | previous mode |
| 15 | word top, word lines | Scroll region (below) | IOCS d0 or −1 |
| 16 | word m | Screen mode (below) | previous mode |
| 17 | — | IOCS `_OS_CURON` ($AE) | IOCS d0 |
| 18 | — | IOCS `_OS_CUROF` ($AF) | IOCS d0 |

For modes 0–13 the first word argument is passed in d1.w and the second
in d2.w, the long in d2/a1, so the IOCS call sees exactly the documented
registers.

**Mode 14 — function-key line.** Kernel variable "fnkey mode" (initially
0). If m (as a byte) ≥ 4: query only. Otherwise KNJCTRL(1,0) is called
first, then:

| m | Meaning |
|---|---------|
| 0 | Show F1–F10 labels on line 31; text console limited to lines 0–30. |
| 1 | Show SHIFT+F1–F10 labels (with a `*` in column 0); console lines 0–30. |
| 2 | Line 31 blank, still reserved; console lines 0–30. |
| 3 | Line 31 released; console lines 0–31. |

Switching to 0/1/2 from 3: if the cursor is on line 31 the screen is
scrolled up one line and the cursor moved up. The console window is set
with IOCS `_B_CONSOL` ($2E) keeping its column extent. Line 31 is cleared
(128 spaces with attribute 3) on every change; labels are drawn with
attribute 3 for the marker, $0B for labels: five labels from column 2 and
five from column 50 (768-dot mode, 8 chars each) or column 33 (512-dot
mode, 5 chars each). Setting m equal to the current mode 3 does nothing.

**Mode 15 — scroll region.** top+lines must be ≤ 32, and ≤ 31 unless the
fnkey mode is 3; otherwise −1. Sets the console window to start at text
line `top` (y = top×16 dots, x = 0) with `lines` lines, keeping the
current column count, via `_B_CONSOL`.

**Mode 16 — screen mode.** Kernel variable "screen mode" (initially 0).
m ≥ 6 (word compare): query only. Else KNJCTRL(1,0), store m, and:

| m | IOCS `_CRTMOD` ($10) d1 | Graphics on (IOCS $90 `_G_CLR_ON`) | Meaning [public] |
|---|----|----|----|
| 0 | 16 | no | 768×512, text only |
| 1 | 16 | yes | 768×512, 16-colour graphics |
| 2 | 4 | no | 512×512, text only |
| 3 | 4 | yes | 512×512, 16 colours |
| 4 | 8 | yes | 512×512, 256 colours |
| 5 | 12 | yes | 512×512, 65536 colours |

Then the console window is re-applied (31 or 32 lines per fnkey mode) and
the labels redrawn if fnkey mode < 2.

"768-dot mode" throughout means CRTC register R20's low byte reads $16
(address $E80029) **[verified]**.

---------------------------------------------------------------------------

## 10. KEYCTRL ($FF24)
In: word `mode`, word `arg`. Out: d0.l. mode ≥ 5 → −1. **[verified]**

| mode | Action | Return |
|------|--------|--------|
| 0 | Take the next byte from the CON expansion buffer, refilling it from IOCS (with full §8 translation) if empty. **Does not wait.** | byte, or 0 if no key |
| 1 | As 0 but does not consume. | byte or 0 |
| 2 | IOCS `_B_SFTSNS` ($02), result r | low word = (r bits 15–12 moved to bits 11–8) + (r bits 7–0); bits 15–12 = 0; high word as returned by IOCS |
| 3 | IOCS `_BITSNS` ($04), d1 = arg (key-matrix group) | IOCS d0 |
| 4 | IOCS `_LEDMOD` ($0D), d1 = 4 (INS LED), d2 = arg (0 off, else on) | IOCS d0 |

KEYCTRL 0/1 bypass handles and redirection entirely and skip Ctrl-C
processing.

---------------------------------------------------------------------------

## 11. KNJCTRL ($FF22)
The kernel's own handler ignores its arguments and returns −1
**[verified]** ("no kana-kanji front end installed"). It exists as a hook
point: a front-end processor replaces DOS vector $FF22 (INTVCS) and the
kernel calls it as KNJCTRL with two long arguments (1, 0) — i.e. stack
`(long 1, long 0)` — whenever it is about to change the screen or end a
program: on process exit (EXIT/EXIT2/KEEPPR), on EXEC, on FNCKEY set
(F-key entries), on CONCTRL 14/16 mode changes, and before the boot-time
function-key line draw **[verified]**. The meaning of mode 1 for a FEP is
[inferred]: "close/flush any conversion in progress".

---------------------------------------------------------------------------

## 12. HENDSP ($FF18) — conversion-window display helpers
Used by kana-kanji front ends to draw on text line 31. All drawing uses
IOCS `_B_PUTMES` ($2F) with y = 31; save/restore use IOCS $17 / $18 on
text-VRAM planes 0 and 1 (line 31 = raster 496, VRAM offset $F800 in each
plane). "W" = 80 columns in 768-dot mode, 48 in 512-dot mode.
In: word `mode`, then arguments. mode ≥ 12 → −1. **[verified]**

| mode | Arguments | Action | Return |
|------|-----------|--------|--------|
| 0 | — | Main window open: save the whole of line 31 (96 bytes × 16 rasters, both planes) into a kernel buffer and clear it. | 16 (main-window width) |
| 1 | word pos, long str | Main window put, attribute 3 | see below |
| 2 | word pos, long str | Main window put, attribute $0B (reverse) | see below |
| 3 | — | Main window close: restore line 31 saved by mode 0 | IOCS d0 |
| 4 | — | Input window open (nothing drawn) | W |
| 5 | word pos, long str | Input window put, attribute 3 | see below |
| 6 | word pos, long str | Input window put, attribute $0B | see below |
| 7 | word pos | Input window clear from column pos to column W−1 (both planes, 16 rasters); nothing if pos ≥ W | undefined (handler leaves mode×4 in d0) |
| 8 | — | Select window open: save columns 0..W−1 of line 31 into a second buffer, clear those columns (whole longwords: 80 or 48 bytes) | W |
| 9 | word pos, long str | Select window put, attribute 1 | see below |
| 10 | word pos, long str | Select window put, attribute 9 | see below |
| 11 | — | Select window close: restore what mode 8 saved | IOCS d0 |

Put modes: window base column B and width N are: main B = W (80/48),
N = 16; input and select B = 0, N = W. If pos > N nothing is drawn.
Otherwise n = min(strlen(str), N − pos) characters are drawn at column
B + pos (nothing if n = 0). Return value: (d2 after the `_B_PUTMES` call)
− B, where d2 was B+pos on entry to IOCS — i.e. pos unless IOCS modifies
d2 **[verified computation; IOCS d2 behaviour inferred]**.

---------------------------------------------------------------------------

## 13. Summary of quirks to reproduce

1. Handlers that do not set d0 return the call-number residue (PRINT of an
   empty string returns 9).
2. NUL from stdin = "no key"; redirected-stdin EOF hangs blocking reads.
3. GETC discards Ctrl-C in KILL mode; GETCHAR returns it.
4. Ctrl-S pause: any key resumes and is discarded; Ctrl-P/N as resume key
   eat one extra pending key.
5. GETS: only CR is echoed (no LF); 256-byte read/write of buf+2; ESC T/F
   ignore `max`; overwriting a double-byte template char stores a space
   into the caller's template; BEL also flushes type-ahead.
6. Cooked console READ shares one 255-byte line buffer among all handles.
7. Printer echo applies to cooked writes on any char device, including PRN.
8. KEYCTRL 0 does not wait.
