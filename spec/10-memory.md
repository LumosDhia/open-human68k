# 10 — Memory management (memory blocks, MALLOC family)

Scope: the memory-block chain ("arena"), and the DOS calls MALLOC ($FF48),
MFREE ($FF49), SETBLOCK ($FF4A), MALLOC2 ($FF88, alias $FF58), S_MALLOC
($FFAD, alias $FF7D), S_MFREE ($FFAE, alias $FF7E), S_PROCESS ($FFAF, alias
$FF7F), and the freeing of memory when a process terminates.

All DOS calls take their arguments on the caller's stack (first argument at the
lowest address) and return a 32-bit result in d0; see `01-dos-dispatch.md`.

Confidence tags: **[verified]** = read from the binary's behaviour,
**[inferred]** = deduced, **[public]** = public documentation only.

---

## 1. System variables

| Address (abs.w) | Size | Meaning |
|---|---|---|
| `$1C00` | long | **Memory end**: first address past the memory managed by the allocator (the "top"). Set at boot to the end of installed main RAM. [verified] |
| `$1C04` | long | **Chain head**: address of the first memory block header. [verified] |
| `$1C20` | long | Address of the root (kernel) process's memory block. Constant after boot. [verified] |
| `$1C28` | long | Address of the kernel variable that holds the **current process** (its memory-block address, see `11-process.md`). [verified] |

When background processing is enabled (`12-background.md`), `$1C04`/`$1C00`
are per-thread: they are swapped on every thread switch, so a background
thread may be working in a private sub-arena. [verified]

---

## 2. Memory block header (16 bytes) [verified]

Every block, including the kernel's own block and every process's block,
starts with a 16-byte header. The address handed to programs ("memory pointer",
returned by MALLOC) is **header + $10**.

| Offset | Size | Name | Meaning |
|---|---|---|---|
| `+$00` | long | prev | Address of the previous block header in the chain; **0 for the first block only**. |
| `+$04` | long | owner | Address of the memory block (header) of the process that owns this block (the "parent"). See flag bytes below. |
| `+$08` | long | end | First address past the in-use part of this block (= header + $10 + size requested). Not necessarily 16-aligned. |
| `+$0C` | long | next | Address of the next block header; **0 for the last block**. |

Owner high-byte flags (the high byte of `+$04` is otherwise 0 on a 24-bit
machine):

| High byte | Meaning |
|---|---|
| `$00` | Normal. |
| `$FF` | Block belongs to a process that terminated with KEEPPR (resident). Set by KEEPPR. Because the owner no longer compares equal to the parent's address, it survives the parent's termination. [verified] |
| `$FD` | Block is hosting a background thread's sub-arena (set by S_PROCESS on the block whose user area begins at the sub-arena start). Cleared again by S_MFREE. [verified] |

### 2.1 Chain rules [verified]

* Blocks form a doubly-linked list sorted by ascending address, starting at
  `[$1C04]`. The first block is the root (kernel) process's block, whose
  `prev` is 0. No other block ever has `prev = 0`; the kernel relies on this
  (a block with `prev = 0` can never be freed).
* There is no explicit "free block" record. **Free space is the gap** between
  `roundup16(block.end)` and `block.next` (or, for the last block, between
  `roundup16(block.end)` and `[$1C00]`).
* New headers are always placed on a 16-byte boundary (allocation from the
  low end of a gap uses `roundup16(prev.end)`; allocation from the high end
  rounds down to 16).
* Blocks have no type field. "Process" blocks are ordinary blocks whose first
  $100 bytes are a process management block (PSP), see `11-process.md`.
* Ownership is a tree: every block's `owner` points at the header of the
  process block that allocated it (or the one given explicitly to MALLOC2).

---

## 3. MALLOC — $FF48 [verified]

```
stack: long size          -> d0
```

Equivalent to MALLOC2 mode 0 with the current process as owner (§4).

## 4. MALLOC2 — $FF88 (alias $FF58) [verified]

```
stack: word mode, long size [, long owner]   -> d0
```

* `mode` low byte = strategy:
  * `0` — first fit: the lowest-address gap large enough.
  * `1` — best fit: the smallest gap large enough (on ties, the
    lowest-address one).
  * `2` — highest: the highest-address gap large enough; the block is placed at
    the **top** of that gap (header at `rounddown16(gap_top − (size+$10))`).
* `mode` bit 15 set: an extra long argument `owner` follows `size`; it is stored
  verbatim in the new block's `owner` field. Otherwise owner = current process
  block address. Bits 8–14 are ignored.
* If the low byte of `mode` is ≥ 3: return **−14** ($FFFFFFF2).

Size handling:

1. If `size ≥ $01000000` (as an unsigned long, e.g. −1), it is treated as
   `$00FFFFFF`. This is the conventional way to ask "how much is free?": the
   request will fail and report the largest possible size. Otherwise the size
   is used as is (0 is legal and yields a header-only block).
2. The space needed in a gap is `size + $10`.

Gaps are examined in chain order; the gap after the last block extends to
`[$1C00]`.

Success: a header is written (`prev` = the block before the gap, `owner`,
`end` = header + $10 + size, `next` = the block after the gap or 0), the
neighbours are relinked, and d0 = header + $10 (the memory pointer). The new
memory is not cleared.

Failure: d0 encodes the largest allocatable size:

| d0 | Meaning |
|---|---|
| `$81000000 + n` | Not enough memory. `n` (low 24 bits) = the largest size that **would** succeed now = (largest gap − $10). |
| `$82000000 + g` | No gap even large enough for a header (largest gap `g` < 16; in practice `$82000000`). |

Both values are negative. Callers typically test `d0 < 0`, then use
`d0 & $FFFFFF` as the maximum size. Note the "largest gap" figure is only
computed over gaps that were too small for the request, which is all of them
when the request fails. [verified]

## 5. MFREE — $FF49 [verified]

```
stack: long ptr           -> d0
```

* `ptr = 0`: free **every block owned by the current process** (the
  process's own block is *not* freed), using the recursive rule of §8.
  Returns 0.
* Otherwise the header address is `ptr − $10`. The chain is searched from
  `[$1C04]` for a header at exactly that address.
  * Not found → **−9** ($FFFFFFF7).
  * Found but it is the first block (`prev = 0`) → **−9**.
  * Otherwise the block is unlinked (neighbours' `next`/`prev` patched) and
    d0 = 0.
* No ownership check is made: any block may be freed by anyone.
* Freeing a block with MFREE does **not** free the blocks that it owns (e.g.
  freeing a process block with MFREE leaves its children allocated). Only the
  `ptr = 0` form and process termination recurse.

## 6. SETBLOCK — $FF4A [verified]

```
stack: long ptr, long newsize   -> d0
```

* `newsize ≥ $01000000` is treated as `$00FFFFFF` (as in MALLOC).
* Header = `ptr − $10`, which must be found in the chain (same search as MFREE)
  else **−9**. The first block is not rejected here.
* Available room = (next block header, or `[$1C00]` if last) − header.
* If `newsize + $10 >` room: fail with **`$81000000 + (room − $10)`** (i.e.
  the maximum size this block can currently be set to); the block is
  unchanged. (If room < $10, `$82000000 + room`.)
* Otherwise `end = header + $10 + newsize`; d0 = 0. The block can grow into the
  gap after it or shrink; it never moves. No ownership check.

---

## 7. Background-thread memory calls

These only differ from MALLOC2/MFREE when called from a background thread
(see `12-background.md` for the thread table; `main thread` = thread 0, the
thread running the foreground process).

### 7.1 S_MALLOC — $FFAD (alias $FF7D) [verified]

```
stack: word mode, long size [, long owner]   -> d0
```

* If the current thread is the main thread (or background processing is
  disabled): exactly MALLOC2.
* Otherwise: mode low byte ≥ 3 → −14. Else MALLOC2 semantics, but the search
  uses the **main thread's** memory chain (the chain head and memory end saved
  in thread 0's entry, offsets `+$74`/`+$78`) instead of the current
  thread's `$1C04`/`$1C00`. Owner is the current process (or the explicit one).

### 7.2 S_MFREE — $FFAE (alias $FF7E) [verified]

```
stack: long ptr           -> d0 (may not return)
```

* Current thread is the main thread (or processing disabled): exactly MFREE.
* Otherwise, if `ptr` ≠ the current thread's sub-arena start (thread entry
  `+$74`): MFREE semantics, but the block is looked up in the **main
  thread's** chain (search starts at thread 0's `+$74`). (`ptr = 0` frees the
  blocks owned by the current process in the *current* chain.)
* If `ptr` equals the current thread's sub-arena start (the address that was
  passed to S_PROCESS as `start`), the sub-arena is dissolved and the thread is
  terminated; **the call does not return**:
  1. `$1C04`/`$1C00` are set back to the main thread's chain bounds.
  2. The sub-arena's root header (at `start`) gets `prev` = the host block's
     `prev`, and `owner` = the host block's owner with the `$FD` flag byte
     cleared; the host block's `$FD` flag is cleared. The last block of the
     sub-chain gets `next` = the host block's `next`. (This splices the
     sub-arena's blocks into the main chain in place of the host block.)
  3. Then exactly the KILL_PR termination sequence runs (`12-background.md`):
     all threads of the current process are released, its files are closed,
     its memory block and everything it owns is freed, and the scheduler
     switches to another thread. [verified sequence; intended use inferred]

### 7.3 S_PROCESS — $FFAF (alias $FF7F) [verified]

```
stack: word id, long start, long length, long size   -> d0
```

Creates a private memory arena for background thread `id`.

* Background processing disabled → d0 = `$FFFF0000`.
* `id` > highest thread index, or thread slot `id` unused → d0 =
  `$FFFF0000 + highest_index` (negative).
* `size + $10 ≥ length` (unsigned) → **−14**.
* Otherwise:
  * Thread `id`'s chain head (`+$74`) := `start`; memory end (`+$78`) :=
    `start + length`. These take effect the next time that thread is switched
    in.
  * The byte at `start − $0C` is set to `$FD` (this is the owner high byte of
    the block header immediately before `start`; `start` is expected to be a
    memory pointer returned by MALLOC, so that block becomes the "host").
  * A root header is written at `start`: `prev = 0`, `owner = 0`,
    `end = start + $10 + size`, `next = 0`.
  * d0 = `start + $10` (the root block's user area, `size` bytes; it is
    intended to become the thread's process block [inferred]).

---

## 8. Freeing on process termination [verified]

When a process terminates (EXIT/EXIT2, abort, KILL_PR — not KEEPPR) the kernel
does, for process block P:

1. Unlink P from the chain (unless P is the first block, in which case nothing
   at all happens in this step and steps 2–3 are skipped).
2. The current process becomes `P.owner` (its parent).
3. **Free all blocks owned by P, recursively**: scan the chain from
   `[$1C04]`; for the first block B with `B.owner = P` (full 32-bit compare),
   unlink B, then (recursively) free all blocks owned by B, then restart the
   scan from the chain head. Stop when the scan reaches the end without a
   match. (If the first block of the chain were owned by P, the scan stops
   immediately; this cannot happen in practice.)

Consequences a compatible kernel must reproduce:

* Grandchildren (blocks owned by blocks owned by P) are freed too.
* Blocks whose owner has a flag byte (`$FF` resident, `$FD` arena host) never
  compare equal and are **not** freed.
* Blocks owned by P that the parent handed out via MALLOC2-with-owner are freed
  with P only if the owner value stored equals P's header address exactly.

MFREE(0) uses step 3 alone with P = current process.

---

## 9. Error codes used here

| d0 | Name | When |
|---|---|---|
| −9 ($FFFFFFF7) | invalid memory block | MFREE/SETBLOCK pointer not a block in the chain, or MFREE of the first block. |
| −14 ($FFFFFFF2) | invalid parameter | MALLOC2/S_MALLOC mode ≥ 3; S_PROCESS size too large. |
| `$81xxxxxx` | insufficient memory (with max size) | MALLOC family, SETBLOCK. |
| `$82000000`+ | no memory at all | MALLOC family. |
| `$FFFF00nn` | (no name) | S_PROCESS bad thread id / processing disabled. |

There is **no** check for a corrupted chain (no −7 is produced by these calls).
[verified]
