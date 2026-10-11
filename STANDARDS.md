# Standards

## Language / framework
- C (m68k gcc cross, freestanding, `-m68000`) plus 68000 assembly only where required (trap entry, boot, context switch).
- Output must be loadable where `HUMAN.SYS` is loaded on an X68000 boot floppy.

## Testing
- XEiJ is the primary emulator (`$XEIJ`, IPL-ROM from `roms/x68000/iplrom.dat`); MAME `x68000` is secondary, pending a complete ROM set.
- Original `COMMAND.X` and utilities are black-box conformance oracles; compare behaviour against the original `HUMAN.SYS`.

## Style
- Spec files (`spec/`) describe behaviour and data layouts only.

## Things to avoid
- Clean side: never read `original/` or `dirty/`; never disassemble the original.
- Never put disassembly, original-mirroring pseudo-code, or copied code/text into `spec/` or `src/`.
- Never commit `original/`, `dirty/`, `.dim`, or `.zip` files.
