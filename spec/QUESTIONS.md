# Open questions (clean side asks, dirty side answers in the spec)

## Memory / process / background (10, 11, 12)

- MALLOC2 with mode bit 15 stores the given owner verbatim, and free-on-exit
  compares the owner with the process's *block* address (PSP − $10). Do real
  callers (e.g. COMMAND.X, resident tools) pass a block address or a PSP
  address? Needs a black-box check; if callers pass PSP addresses those blocks
  are never freed automatically.
- SEND_PR: the kernel stores the first word argument at buffer +$08 and the
  command at +$0A, and treats +$0A = $FFFF as "buffer free". Public naming of
  the buffer fields/argument order was not cross-checked.
- Exact meaning of PSP $60 (kernel only writes −1 for the boot shell) and of
  the d0 values $2000 (Ctrl-C) / $4000 (error abort) passed to CTRLVC/ERRJVC
  handlers: confirm with COMMAND.X behaviour.
- Mode 2 path search: the exact set of characters that end the program name
  (delegated to a file-name character-class routine) is not specified here;
  see 20-filesystem.md once written.
- Behaviour of EXIT from the root process and KILL_PR from thread 0 is
  undefined in the original; no compatible behaviour is specified.

## File system and file I/O (20-filesystem.md, 21-file-io.md) — open points from the dirty side

1. **OS_PATCH module interfaces.** The slot layout and register conventions of the four replaceable
   modules (buffer cache, FAT layer, directory cache, file-name syntax) are not yet specified. Needed
   only if third-party add-ons that call `OS_PATCH` ($FFAB) must work. Is that a goal?
2. **Directory-search hints (DIRSCH).** The hint fields in the DPB from offset `$1E` only speed things
   up. They could still change where a new directory entry lands in rare cases. Not fully traced.
3. **DRVCTRL status bits.** For bits 1, 2 and 3 of the status byte, the spec gives the meanings from
   public documentation; the binary only shows how the kernel reacts to them. Black-box tests with
   the original FD and HD drivers should confirm them.
4. **DUP2 with dst > FILES.** The original does not reject it and writes outside the handle table.
   The clean side should probably return −4. Please confirm whether any compatibility need exists.
5. **Critical-error handler interface.** The FS raises it with codes 5, 7, `$0E` and `$0F`, plus the
   driver status for I/O errors. Its interface and the Abort/Retry/Ignore results are left to
   01-dos-dispatch. The retry-count and retry-wait variables (`$1C0C`/`$1C0E`) are set here, but
   where the retry loop uses them is not traced.
6. **DISKRED/DISKWRT ($FFF3/$FFF4).** These were touched here (remote commands `$53`/`$54`) but not
   specified. Which spec file owns them?
7. **Console line buffer used by cooked READ.** Its maximum length and the editing behaviour belong
   to 30-char-io. The two specs need cross-checking.
8. (Answer, not a question) The 11-process question about the mode-2 program-name character class
   is answered in 20-filesystem.md §9.7. The characters are `/`, `-`, `"` and `'`.

## Character I/O and miscellaneous calls (30-char-io.md, 40-misc-calls.md)

- Q-CIO-1: The meaning of the IOCS `_B_SFTSNS` bits the CON driver tests
  (bit 5 romaji, bit 6 code input, bit 13 hiragana, bit 14 full-width) is
  inferred; confirm against IOCS documentation. Also the exact IOCS
  semantics of calls $A2/$A3 used for full-width and romaji conversion.
- Q-CIO-2: HENDSP put modes return "(d2 after `_B_PUTMES`) − base". Does
  `_B_PUTMES` modify d2 (e.g. return next column)? Needs an IOCS test.
- Q-CIO-3: IOCS $17/$18 register usage in HENDSP (d1 = bytes/raster − 1,
  d2 = rasters − 1, d3 = skip, a1 = buffer, a2 = VRAM) is taken from the
  call sites; confirm these are the documented `_TEXTGET`/`_TEXTPUT`
  conventions.
- Q-CIO-4: trap #11 (BREAK key) event code: the kernel only tests bit 0
  (0 = flush disk buffers, 1 = flush stdin/stdaux). Which codes does the
  ROM pass (BREAK vs SHIFT+BREAK vs CTRL+BREAK)?
- Q-CIO-5: Is the infinite loop of GETCHAR/INKEY/GETC/GETS at EOF of a
  redirected stdin observable on real hardware (black-box test with
  COMMAND.X `prog < file`)?
- Q-MISC-1: The CLOCK device is looked up once, before CONFIG.SYS
  `DEVICE=` lines run, so a replacement CLOCK driver is ignored by the
  date/time calls. Confirm with a black-box test; the device-driver spec
  should say whether anything else re-points it.
- Q-MISC-2: Exact validation done by IOCS `_DATEBCD` / `_TIMEBCD` (year
  range, days per month, leap years) — determines which SETDATE/SETTIME
  values return −1.
- Q-MISC-3: OS_PATCH module entry tables (slots 1–4): number of entries
  and the semantics of each are kernel-internal and not specified. Needed
  only if third-party OS_PATCH modules must run on the reimplementation.
- Q-MISC-4: DISKRED/DISKWRT short form is refused unless DPB +$0A
  (bytes per sector) is 1024, and the long form with DPB +$0A = 0 issues
  driver commands $53/$54/$D4. The file-system spec should define DPB
  +$0A = 0 and the per-drive pre-write step skipped by long-form DISKWRT.

## Boot / dispatch / CONFIG.SYS / device drivers (dirty side, 00-03)

Open points the dirty side could not fully resolve from static analysis:

1. **`newfat = 2`** — the value is stored (work area `$1C0B` and inside the FAT code) but its
   effect on FAT allocation/format was not traced. To be answered in 20-filesystem.
2. **Shell launch**: between EXEC mode 1 and mode 4 the kernel sets one long field of the
   loaded process block (offset +$60 from the address EXEC returns in a0) to −1. Its
   meaning belongs to 11-process.
3. **d0 values on abort paths**: control reaches CTRLVC with d0 = `$00002000` (ctrl-C) and
   ERRJVC with d0 = `$00004000` (Abort from Abort/Retry/Ignore). Presumably these become
   the terminated process's exit code (high byte classes); confirm in 11-process.
4. **IOCS function names** used only by number in the spec (`$38`, `$39`, `$3C`, `$3D`, `$3E`,
   `$3F`, `$47`, `$4E`): the clean side should map them from public IOCS documentation;
   the dirty side only verified the call numbers and register usage.
5. **Graphic TITLE.SYS**: offsets are verified but the visual result depends on the IOCS
   `$1B` (text put) pattern format; an oracle comparison under an emulator is recommended.
6. **`$000160` fix-up at boot** (top word set to `$00FF` when its first byte is non-zero):
   purpose unknown; reproduce literally.
7. **NUL header discovery**: the kernel does not export the NUL header address. If
   third-party tools find it by scanning (as is folklore), the exact search they use
   (start address, pattern) should be checked against real tools before choosing where
   the reimplementation places its NUL header.
8. **trap #11 BREAK code**: bit 0 of the code the IOCS passes in d0 selects "flush disk
   buffers" (0) versus "flush console/AUX input" (1). Which keys produce which code is
   ROM behaviour and was not verified.
9. **Remote-device (attribute bit 13) packets**: the command ↔ DOS call mapping and the
   register→packet-field placement are verified (03 §4.4); the exact contents of each
   argument (name buffer formats, FILES buffer, lock parameters) are to be specified in
   20-filesystem / 21-file-io.

## Boot sector (04)
- Q-BOOT-1: Hard-disk partition IPL requirements on HUMAN.SYS are not analysed (not present on this floppy). Assume same as floppy until checked.
