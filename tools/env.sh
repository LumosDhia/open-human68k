# Source this to put the m68k cross toolchain on PATH.
# Uses the system toolchain if installed, else a user-local copy in .toolchain/
# (Debian packages unpacked with dpkg-deb -x; no root needed).
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v m68k-linux-gnu-gcc >/dev/null 2>&1 && [ -d "$_root/.toolchain" ]; then
    export PATH="$_root/.toolchain/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$_root/.toolchain/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export M68K_GCC_FLAGS="-B$_root/.toolchain/usr/lib/gcc-cross/m68k-linux-gnu/14/ -B$_root/.toolchain/usr/libexec/gcc-cross/m68k-linux-gnu/14/ -B$_root/.toolchain/usr/bin/m68k-linux-gnu-"
    export CC="m68k-linux-gnu-gcc-14 $M68K_GCC_FLAGS"
else
    export CC="m68k-linux-gnu-gcc"
fi
export AS=m68k-linux-gnu-as LD=m68k-linux-gnu-ld OBJCOPY=m68k-linux-gnu-objcopy OBJDUMP=m68k-linux-gnu-objdump
unset _root

# MAME: system install if present, else user-local unpack in .mame/
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v mame >/dev/null 2>&1; then
    export MAME=mame
elif [ -x "$_root/.mame/usr/games/mame" ]; then
    export LD_LIBRARY_PATH="$_root/.mame/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export MAME="$_root/.mame/usr/games/mame"
fi
# ROMs are user-supplied (not distributable); put x68000.zip in roms/ (git-ignored).
export MAME_ROMPATH="$_root/roms"
unset _root

# XEiJ (Java X68000 emulator, primary test target): user-local unpack in .xeij/.
# Bundles the freely released IPL-ROMs and its own CGROM, so roms/ is not needed.
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_root/.xeij/XEiJ.jar" ]; then
    # XEiJ needs Java 26+; prefer the user-local JRE in .jre/.
    _java=java; [ -x "$_root/.jre/bin/java" ] && _java="$_root/.jre/bin/java"
    export XEIJ="$_java -jar $_root/.xeij/XEiJ.jar -lang=en"
    unset _java
fi
unset _root
