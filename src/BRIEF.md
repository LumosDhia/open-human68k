# Clean-side implementation brief

You are on the **clean side** of a clean-room reimplementation of the Human68k v3.02
kernel for the Sharp X680x0. Project root: the repository root.

## Hard rules
- You may read: `spec/`, `src/`, `tests/`, `tools/`, `CLEANROOM.md`, `STANDARDS.md`,
  `PLAN.md`, `DECISIONS.md`, the local project instructions file, and public documentation (books/manuals,
  public web references on X68000 IOCS/Human68k APIs).
- You must **never** read, list, grep, open or disassemble anything under
  `original/` or `dirty/`, and must not disassemble any Sharp/Hudson binary,
  including files staged in `tests/oracle/`. Those may only be *copied onto disk
  images and executed* as black boxes.
- Do not copy code or text from any non-MIT-compatible source. Everything you write is MIT.
- If the spec is unclear or missing something, make a reasonable choice, mark it
  with a `/* SPEC-GAP: ... */` comment, and append a question to `spec/QUESTIONS.md`
  under a "Clean side" heading. Do not guess by looking at the original.

## Toolchain
`source tools/env.sh` gives `$CC` (m68k gcc 14), `$AS`, `$LD`, `$OBJCOPY`, `$OBJDUMP`.
Target the MC68000 (`-m68000`), freestanding, no libc. No sudo is available.

## Conventions
- C for logic, GNU as (`.S`, Motorola-free GAS syntax is fine) for trap/exception
  entry, the boot sector and context switching.
- Layout: `src/boot/` (boot sector), `src/kernel/` (kernel), `src/include/`,
  `tools/` (host-side Python 3 build tools, stdlib only), `tests/`.
- Build with `make` from the project root; outputs under `build/` (git-ignored).
- Keep `PLAN.md` honest: when you finish, update its Now/Next/Done for the clean side,
  and log non-obvious design calls in `DECISIONS.md` (newest first, existing format).
- Do not commit.

Finish with a short report: what builds, what was tested and how, what is stubbed,
spec gaps found.
