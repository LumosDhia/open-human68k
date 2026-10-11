# 12 — Background processing (threads), $FFF8–$FFFF

Scope: the `process` CONFIG.SYS setting, the thread table, the scheduler, and
the calls OPEN_PR $FFF8, KILL_PR $FFF9, GET_PR $FFFA, SUSPEND_PR $FFFB,
SLEEP_PR $FFFC, SEND_PR $FFFD, TIME_PR $FFFE, CHANGE_PR $FFFF. The related
memory calls S_MALLOC/S_MFREE/S_PROCESS are in `10-memory.md` §7.

Tags: **[verified]**, **[inferred]**, **[public]** as in the other files.

---

## 1. Dispatch of $FFF5–$FFFF [verified]

DOS calls numbered $FFF5 and above do **not** go through the normal
DOS-call table. They are handled by a separate path:

* $FFF5–$FFF7 (INDOSFLG, SUPER_JSR, BUS_ERR) — not background calls; see
  `40-misc-calls.md`.
* $FFF8–$FFFF: if background processing is disabled (no `process` line or an
  invalid one), every call returns **d0 = −1** immediately.

They do not increment the InDOS counter. Arguments are on the caller's stack
as for other DOS calls.

The DOS-call table slots for $F8, $F9 and $FF (addresses `$1BE0`, `$1BE4`,
`$1BFC`) are **not** the handlers; they are *notification hooks* (default: a
bare return), changeable with INTVCS($FFF8/$FFF9/$FFFF) [inferred from slot
addressing]:

| Slot | Called | d0 on call |
|---|---|---|
| $FFF8 (`$1BE0`) | at the end of a successful OPEN_PR | new thread id |
| $FFF9 (`$1BE4`) | by KILL_PR, once per thread released | see quirk in §5.2 |
| $FFFF (`$1BFC`) | every time a thread is switched in | id of thread being resumed |

Hooks are called in supervisor mode with interrupts masked (level 7) during
the switch; they must preserve registers other than d0/a0. [inferred]

---

## 2. CONFIG.SYS `process` [verified]

```
process = N LEVEL TICK
```

Three decimal numbers separated by single spaces (leading spaces before each
number are skipped; the character after the 1st and 2nd number must be a
space).

| Field | Accepted | Meaning |
|---|---|---|
| N | 2–32 | Number of thread slots including the main thread. |
| LEVEL | 0–255; values < 2 become 2 | Priority of the main thread (stored as LEVEL − 1). |
| TICK | 1–100 | Scheduling time slice in milliseconds. |

If the keyword is absent, or any field is out of range or malformed, built-in
defaults stored in the kernel image header are used; in v3.02 these are all
zero, meaning **background processing disabled**. N outside 2–32 also disables
it.

When enabled at boot:

1. A thread table of N entries × `$7C` bytes is allocated from kernel
   memory (below the user memory area), cleared, and linked into a ring.
2. Thread 0 (the **main thread**) is initialised: state runnable, priority
   LEVEL−1, process = current process, comm buffer = a kernel-internal 16-byte
   buffer (capacity 16, data pointer 0, "busy"), name `"Human68k system"`,
   memory chain = the global one.
3. MFP Timer-D is programmed through IOCS `$6B` (TIMERDST) for a 1 ms
   interrupt (value `$0714`); the interrupt handler implements the tick
   counter and the time slice. If TIMERDST fails, processing stays disabled.
4. If the NMI autovector (`$7C`) points into ROM (`$00FFxxxx`), it is
   replaced by a handler that only acknowledges the NMI (writes `$0C` to
   `$E8E007`) and returns.
5. IOCS call `$6B` is hooked so that later TIMERDST calls by programs always
   fail (return non-zero), reserving Timer-D for the kernel.

---

## 3. Thread table

### 3.1 System variables [verified]

| Address | Size | Meaning |
|---|---|---|
| `$1C50` | long | Address of thread 0's entry (table base); 0 = disabled. |
| `$1C54` | long | Address of the running thread's entry; 0 = disabled. |
| `$1C58` | word | Highest thread id (N − 1); 0 = disabled. |
| `$1C5A` | word | Number of background threads in use (excluding thread 0). |
| `$1C14` | byte | "Switch pending" flag (time slice expired while in supervisor mode). |

Thread id = (entry address − `$1C50`) / `$7C`.

### 3.2 Thread entry layout (`$7C` bytes) [verified]

The first `$74` bytes are exactly what GET_PR returns.

| Off | Size | Field | Meaning |
|---|---|---|---|
| `$00` | long | next | Next entry in the ring (table order; last → first). |
| `$04` | byte | state | `$00` runnable, `$FF` sleeping/waiting, `$FE` suspended. Free slot: `$04..$07` = `$FFFFFFFF`. |
| `$05` | byte | counter | Current priority countdown. |
| `$06` | byte | priority | Reload value for `$05` (smaller = scheduled more often). |
| `$07` | byte | DOS call | Number of the DOS call in progress when switched out. |
| `$08` | long | process | Process block of the process this thread belongs to; **0 = slot free**. |
| `$0C` | long | usp | Saved USP. |
| `$10` | 8 longs | d0–d7 | Saved data registers. |
| `$30` | 7 longs | a0–a6 | Saved address registers. |
| `$4C` | word | sr | Saved SR. |
| `$4E` | long | pc | Saved PC. |
| `$52` | long | ssp | Saved SSP (above the exception frame). |
| `$56` | word | indos | Saved InDOS counter (`$1C08`). |
| `$58` | long | dosframe | Saved outermost-DOS-entry frame pointer. |
| `$5C` | long | buffer | Pointer to this thread's communication buffer (§3.3). |
| `$60` | 16 bytes | name | NUL-terminated name, max 15 characters. |
| `$70` | long | wait time | Remaining sleep time in ms (0 = none / infinite). |
| `$74` | long | mem start | This thread's memory chain head (`$1C04` while it runs). |
| `$78` | long | mem end | This thread's memory end (`$1C00` while it runs). |

### 3.3 Communication buffer [verified]

| Off | Size | Meaning |
|---|---|---|
| `+$00` | long | Capacity in bytes; on delivery replaced by the received length. |
| `+$04` | long | Pointer to the data area. |
| `+$08` | word | Sender's id (first argument of SEND_PR). |
| `+$0A` | word | Command; **`$FFFF` = buffer empty / ready to receive**. Any other value = a message is pending (buffer busy). |

The receiver sets `+$0A` back to `$FFFF` (and restores the capacity) to accept
the next message; the kernel never does. [inferred]

---

## 4. Scheduling [verified]

* **Tick**: Timer-D interrupts every 1 ms; each interrupt increments the
  32-bit millisecond counter returned by TIME_PR. Every TICK interrupts the
  slice ends: sleep timers are updated (§4.2), and
  * if the interrupted code was in user mode, a switch happens immediately;
  * otherwise the pending flag `$1C14` is set and the switch happens at the
    end of the next DOS call that returns to nesting level 0 (InDOS = 0).
* **Switch**: the running thread's registers, USP, SR/PC/SSP, InDOS counter,
  outermost DOS frame and current DOS call number are saved in its entry;
  for thread 0 the current `$1C04`/`$1C00` are also saved to `$74/$78`. The
  live EXITVC/CTRLVC/ERRJVC, abort SR/SSP and trap #10–#14 vectors are saved
  into the PSP of the thread's process.
* If no background thread exists (`$1C5A` = 0), the same thread continues
  (its counter is reloaded).
* **Selection** (scanning the ring once, starting with the thread after the
  current one and ending with the current one; consider the word
  `state<<8 | counter`):
  1. The first thread whose word is 0 (runnable, counter 0) is chosen.
  2. Otherwise the runnable thread with the smallest counter is chosen (on a
     tie, the first encountered); that minimum is subtracted from the counter
     byte of **every** entry (bytes wrap; non-runnable ones too).
  3. If no thread is runnable, **thread 0 is chosen** even if it is sleeping
     or suspended.
* The chosen thread's counter is reloaded from its priority; `$1C04/$1C00`
  := its `$74/$78`; current process := its `$08`; the process's vectors are
  loaded from its PSP; USP/registers/stack/InDOS/DOS frame restored; the
  $FFFF hook is called with d0 = its id; it resumes.
* While a switch is in progress an NMI is deferred and delivered afterwards.

All threads of a process share its PSP, open files and current-process
identity; each thread has its own stacks.

### 4.1 Threads and DOS calls

Preemption never interrupts supervisor-mode code: a slice that expires in
supervisor mode only sets `$1C14`, and the deferred switch is taken when a DOS
call (other than $FFF5–$FFFF) returns with the InDOS counter back at 0.
[verified] The InDOS counter and DOS frame are nevertheless saved per thread
because SLEEP_PR/CHANGE_PR/KILL_PR switch unconditionally and may be issued
from code already running inside a DOS call (e.g. a device driver or a
resident hook). [inferred]

### 4.2 Sleep timers [verified]

At each slice end, elapsed ms since the previous update is subtracted from
every non-zero `$70`. When a timer reaches ≤ 0: `$70` := 0; the thread's saved
d0 := `$FFFFFF00 | state` (−1 for a sleeping thread); and unless the state is
`$FE` (suspended), the state/counter word is cleared (runnable).

---

## 5. Calls

Error convention for "bad thread id": when the id is greater than N−1 or the
slot is free, these calls return **d0 = `$FFFF0000 + (N−1)`** (negative);
with processing disabled they return −1 (§1). [verified]

### 5.1 OPEN_PR — $FFF8 [verified]

```
stack: long name, word priority, long usp, long ssp, word sr, long pc,
       long buffer, long sleeptime                       -> d0
```

Creates a thread in the current process.

* High byte of `priority` non-zero → **−14**.
* All N−1 background slots in use → **−29**.
* A used slot already has the same name (compared up to 16 chars) → **−27**.
* Otherwise the first free slot (lowest id) is filled:
  * `$74/$78` = the creator's current `$1C04/$1C00` (shares its memory view);
  * name = first 15 chars of `name` + NUL;
  * `$70` = `sleeptime`;
  * state = `$FF` (waiting), counter = `$FF`;
  * priority byte = `priority − 1`, but at least 1 (0 and 1 both give 1);
  * DOS call = 0; process = current process; usp = `usp`;
  * d0–d7, a0–a6 = 0; sr = `sr & $201F` (S bit and condition codes only);
    pc = `pc`; ssp = `ssp`; InDOS = 0; DOS frame = 0; buffer = `buffer`.
* `$1C5A` += 1; the $FFF8 hook is called; d0 = new thread id.

The new thread does not run until woken: after `sleeptime` ms (if non-zero;
it then starts with d0 = −1) or by a SEND_PR to it (d0 = remaining time).

### 5.2 KILL_PR — $FFF9 [verified]

No arguments. Terminates the **calling thread's process**; does not return.

1. Every slot other than thread 0 whose process equals the current process is
   released: state word := `$FFFF`, `$04..$07` = −1, `$70` := 0, `$08` := 0,
   `$1C5A` −= 1, and the $FFF9 hook is called. Quirk: the d0 given to the hook
   is 0 for the first released slot and then counts slots scanned after it,
   so it is not the real thread id.
2. The process's files are closed and its memory freed exactly as by EXIT
   (`11-process.md` §5.1 steps 2–3; current process := parent).
3. The scheduler selects another thread starting after the calling thread
   (§4) without saving the caller's context.

Calling it from thread 0 is not meaningful (thread 0 is never released, but
its context is discarded). [inferred]

### 5.3 GET_PR — $FFFA [verified]

```
stack: word id, long buffer        -> d0 = thread id
```

Copies the first `$74` bytes of a thread entry to `buffer` (layout §3.2).

* `id` = `$FFFF`: search by name — `buffer+$60` must hold the name; the first
  used slot whose name matches exactly (case-sensitive) is copied. Not found →
  −1.
* `id` = `$FFFE`: the calling thread.
* otherwise thread `id` (bad id → `$FFFF0000+(N−1)`).

### 5.4 SUSPEND_PR — $FFFB [verified]

```
stack: word id       -> d0
```

Bad id → `$FFFF0000+(N−1)`. `id` = the calling thread → −1. Otherwise the
state byte := `$FE` (even if it was sleeping; a running sleep timer keeps
counting) and d0 = 0. There is no resume call: a suspended thread is made
runnable again only by SEND_PR to it.

### 5.5 SLEEP_PR — $FFFC [verified]

```
stack: long ms       -> d0
```

* If the caller's comm buffer has a pending message (`+$0A` ≠ `$FFFF`):
  returns immediately with d0 = `ms`.
* Otherwise: state := `$FF`, `$70` := `ms` (0 = sleep until a message), and
  the thread is switched out. On wake-up d0 is:
  * −1 if the time expired;
  * the remaining ms (0 for an infinite sleep) if woken by SEND_PR.

### 5.6 SEND_PR — $FFFD [verified]

```
stack: word from_id, word to_id, word command, long data, long length -> d0
```

* Bad `to_id` → `$FFFF0000+(N−1)`.
* `command` = `$FFFB`: no data transfer; just wake the target (below).
* Otherwise, with B = target's comm buffer:
  * B `+$0A` ≠ `$FFFF` (busy) → **−28**.
  * B `+$00` (capacity) < `length` → d0 = capacity with bit 31 set.
  * else B `+$00` := `length`; `length` bytes are copied from `data` to
    B `+$04`; B `+$08` := `from_id`, B `+$0A` := `command`.
* Wake: if the target's state is `$FF` its saved d0 := its `$70` (remaining
  time); for any non-zero state (`$FF` or `$FE`) `$70` := 0 and the state word
  := 0 (runnable). d0 = 0.

`from_id` is not validated. The sender keeps running (no immediate switch).

### 5.7 TIME_PR — $FFFE [verified]

No arguments. d0 = millisecond counter (incremented by every Timer-D
interrupt since processing was enabled at boot; wraps at 2³²).

### 5.8 CHANGE_PR — $FFFF [verified]

No arguments. Gives up the rest of the time slice: the caller's context is
saved and the scheduler selects a thread (§4) immediately (the caller may be
selected again). On return d0 holds `$FFFF` in its low word and the caller's
original d0 high word (not a meaningful result).

---

## 6. Error codes

| d0 | Meaning |
|---|---|
| −1 | Background processing disabled; SUSPEND_PR of self; GET_PR name not found. |
| −14 | OPEN_PR priority ≥ 256. |
| −27 ($FFFFFFE5) | OPEN_PR: thread name already exists. |
| −28 ($FFFFFFE4) | SEND_PR: target buffer busy. |
| −29 ($FFFFFFE3) | OPEN_PR: no free thread slot. |
| `$FFFF0000+(N−1)` | Bad / unused thread id. |
| `$80000000+capacity` | SEND_PR: message longer than target buffer. |
