# Plan

## Now
- [ ] Clean side milestone 1 (agent running): build system, own boot sector, `tools/mkxfile.py`, `tools/mkxdf.py`, kernel core (init, dispatcher, devices, memory, char I/O, misc)

## Next
- Clean side milestone 2 (parallel): filesystem/FAT + file I/O; EXEC/process + CONFIG.SYS; then background processing
- Goal: boot own image to `COMMAND.X` prompt, run `DIR`
- Black-box tests in XEiJ to resolve `spec/QUESTIONS.md` items marked as needing them
- Tooling: rebuild floppy image with new kernel; headless XEiJ run; differential tests vs original

## Done
- XEiJ (model EXPERT) boots `.xeij/HUMAN302.XDF` cleanly to `A>` with COMMAND.X 3.00; it is the oracle boot disk (its HUMAN.SYS is byte-identical to the analysed one, SHA1 fc1cb687…)
- XEiJ 0.26.10.08 in `.xeij/` with Temurin 26 JRE in `.jre/`; `$XEIJ` from `tools/env.sh` (English UI). The `.dim` boots the kernel but `WINDRV.SYS` (WinX68k host-share driver) bus-errors under XEiJ
- Free Sharp IPL-ROMs v1.0/1.1/1.2/1.3 installed in `roms/x68000/` (checksums match MAME); MAME still lacks `cgrom.dat` and `rh-ix0897/0898`
- Dirty side: `spec/00`–`04`, `10`–`12`, `20`–`21`, `30`, `40` written (~4.6k lines); hygiene-scanned for kernel addresses/labels/code; evidence in `dirty/evidence/`; open items in `spec/QUESTIONS.md`
- MAME 0.276 unpacked user-locally in `.mame/` (`$MAME` via `tools/env.sh`; accepts .xdf and .dim)
- m68k cross toolchain unpacked user-locally in `.toolchain/` (no sudo); `source tools/env.sh`
- Oracle binaries (COMMAND.X, BIN/, original HUMAN.SYS) staged in `tests/oracle/` (git-ignored) for black-box runs only
- Extracted disk image to `original/disk/` (99 files)
- `HUMAN.SYS` triage: X-file, base/entry 0x6800, text 0xA890, data 0x33EA, bss 0, 995 relocs (pre-applied for base 0x6800)
- Dirty tooling: `dirty/tools/` (X-file parser, recursive-descent disassembler with DOS F-line decoding, label annotator, `run.sh`); listing covers 94.6% of text
- Located DOS dispatch table (256 entries; $FF50–$FF5F alias $FF80–$FF8F; one shared stub for unimplemented calls) and built-in device chain (CON → AUX → PRN → … → CLOCK)
- Project skeleton, `CLEANROOM.md`, MIT `LICENSE`, seed template, `spec/README.md` conventions, `dirty/BRIEF.md`

## Notes
- CONFIG.SYS keywords seen in kernel: files buffers lastdrive title key uskcg bell device process share common envset program verify newfat scsidev exconfig fflush dirsch
- capstone (venv `dirty/.venv`) decodes $FFxx as FPU ops; the disassembler pre-decodes $FExx/$FFxx as FPACK/DOS calls
