# Human68k v3.02 behavioural specification

This directory is the only channel between the dirty (analysis) side and the
clean (implementation) side. See `../CLEANROOM.md`.

## Rules for spec files
- Describe *what* the kernel does, observable from outside: register/stack
  conventions, inputs, outputs, side effects, error codes, ordering, quirks.
- Data structures: give offset, size, meaning, and who reads/writes them.
- No disassembly, no original addresses or label names, no pseudo-code that
  follows the original control flow, no copied text except what compatibility
  requires (keywords, magic numbers, device names, error message text that
  programs depend on).
- Mark confidence: **[verified]** (read directly from the binary's behaviour),
  **[inferred]** (deduced), **[public]** (from public documentation only).
- Unknowns go in `QUESTIONS.md`.

## Files
| File | Subsystem |
|------|-----------|
| `00-overview.md` | Memory map, boot sequence, system work area, vectors |
| `01-dos-dispatch.md` | DOS call entry, register conventions, error codes, call table |
| `02-config-sys.md` | CONFIG.SYS keywords and processing |
| `03-device-drivers.md` | Driver header, request packets, built-in devices |
| `04-boot-sector.md` | Floppy boot sector, kernel-file load requirements |
| `10-memory.md` | Memory blocks, MALLOC family |
| `11-process.md` | PSP, EXEC (X/R/Z formats), EXIT, KEEPPR, vectors, env |
| `12-background.md` | Background-process calls ($FFF8–$FFFF) |
| `20-filesystem.md` | DPB, FAT, buffers, directories, path parsing |
| `21-file-io.md` | Handles, FCBs, file calls |
| `30-char-io.md` | Console/char I/O, line editing, Ctrl-C |
| `40-misc-calls.md` | Date/time, SUPER, INTVCS/G, VERNUM, etc. |
