# Clean-room protocol

This project produces an open-source (MIT) reimplementation of the Human68k
kernel (`HUMAN.SYS`, v3.02) using a two-team clean-room process.

## Directories

| Path        | Side    | Contents                                                    |
|-------------|---------|-------------------------------------------------------------|
| `original/` | dirty   | Original disk image and extracted files. Never committed.   |
| `dirty/`    | dirty   | Disassembly, notes, analysis scripts. Never committed.      |
| `spec/`     | bridge  | Behavioral specifications. The only channel between sides.  |
| `src/`      | clean   | Reimplementation source.                                     |
| `tests/`    | clean   | Conformance tests (may *run* original binaries as oracles). |
| `tools/`    | either  | Build and image tooling that does not embed original code.  |

## Rules

### Dirty side (analysis)
- May read anything in `original/` and `dirty/`.
- Writes findings to `spec/` only as behavior: inputs, outputs, side effects,
  data-structure layouts (offsets/sizes/meaning), error codes, ordering
  constraints, and observable quirks.
- Must not put into `spec/`: disassembly, pseudo-code that mirrors the original
  control flow, original label names, copied strings beyond what is required
  for compatibility (e.g. CONFIG.SYS keywords, magic values), or byte dumps of
  code.
- Each spec file cites the evidence it was derived from by address range in a
  separate `dirty/evidence/` note, not in the spec itself.

### Clean side (implementation)
- May read `spec/`, `src/`, `tests/`, `tools/`, and public documentation
  (published X68000/Human68k programming manuals, public-domain references).
- Must never read `original/` or `dirty/`, and must not disassemble the original.
- Unclear spec points become questions in `spec/QUESTIONS.md`; the dirty side
  answers them in the spec.

### Testing
- Original binaries (e.g. `COMMAND.X`, utilities) may be executed under an
  emulator as black-box oracles against the reimplementation.
- `HUMAN.SYS` itself is used only for differential black-box comparison of
  observable behavior.

## Legal note
Sharp and Hudson made the X68000 system software, including Human68k,
available for free non-commercial distribution in 2000. That permission does
not cover relicensing; therefore no original code or text is copied into
`src/`.
