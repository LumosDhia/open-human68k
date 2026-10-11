# Decisions

Log of non-obvious technical/architectural calls, newest first. One entry per decision.

### 2026-10-11 — XEiJ replaces MAME as the primary test emulator
**What:** Run conformance and boot tests in XEiJ (Java, user-local in `.xeij/`, `$XEIJ` via `tools/env.sh`). MAME stays installed as a secondary target once a complete ROM set is available.
**Why:** The freely released Sharp IPL-ROMs (X68000 LIBRARY, `X68BIOS*.LZH`) match MAME's checksums, but MAME's `x68000` set also requires `cgrom.dat` and two `rh-ix089x` ROMs that were never freely released. XEiJ bundles the free IPL-ROMs and its own font ROM (`CGROM_XEiJ.DAT`), so the test setup needs no non-free files. XEiJ 0.26.10.08 requires Java 26, provided by a user-local Temurin JRE in `.jre/`.
**Alternatives considered:** Generating `cgrom.dat` for MAME (checksum mismatch, and the `rh-ix` ROMs would still be missing); dumping ROMs from real hardware (none available).

### 2026-10-10 — User-local toolchain and own boot sector
**What:** Unpack Debian m68k cross packages with `dpkg-deb -x` into `.toolchain/` (git-ignored), wrapped by `tools/env.sh`. The clean side writes its own boot sector from `spec/04` and emits raw `.xdf` images.
**Why:** No sudo available. Own boot sector keeps the release free of Sharp code. `.xdf` (raw image) avoids depending on the undocumented DIM header and is accepted by MAME.
**Alternatives considered:** Waiting for `sudo apt install`; reusing the original boot sector (fine for local tests, not distributable).

### 2026-10-10 — Dirty-side disassembly with capstone, not binutils
**What:** Custom recursive-descent disassembler on capstone (Python venv), seeded from entry, relocation pointer tables, jmp-vector tables and validated immediate code pointers.
**Why:** No sudo for m68k binutils; capstone is installable per-user and scriptable. HUMAN.SYS uses F-line $FFxx DOS calls that generic disassemblers mis-decode as FPU ops.
**Alternatives considered:** m68k-linux-gnu-objdump linear sweep (no data/code separation), Ghidra (heavier, not installed).

### 2026-10-10 — Spec split into four subsystem areas analysed in parallel
**What:** Boot/dispatch/config/devices; memory/process/background; filesystem/file I/O; char I/O/misc. Each writes its own `spec/` files and `dirty/evidence/` notes.
**Why:** Listing is ~19k lines; parallel agents keep each context focused. Evidence (addresses) stays on the dirty side.
**Alternatives considered:** One sequential analyst (slower, context overflow risk).

### 2026-10-10 — Two-agent clean-room split
**What:** Dirty agent analyses `HUMAN.SYS` and writes behavioural specs to `spec/`; a separate fresh agent implements `src/` from `spec/` only.
**Why:** Gives auditable clean-room provenance for an MIT release.
**Alternatives considered:** Single-pass reverse-and-reimplement (faster but not clean-room).

### 2026-10-10 — C + 68k asm, MAME, MIT
**What:** Implement in C with minimal 68000 asm; test under MAME x68000; license MIT.
**Why:** Readable and maintainable; MAME is scriptable and has a debugger; permissive license.
**Alternatives considered:** Pure asm (harder to maintain), Rust no_std (tier-3 m68k target), XEiJ or a Musashi harness, GPL/BSD.

## Template

### YYYY-MM-DD — Decision title
**What:**
**Why:**
**Alternatives considered:**
