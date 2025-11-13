# Windows Cross-Compilation Guide (clang-cl Method)

## Overview

Zelda3's `build.sh` uses **clang-cl** with **lld-link** to produce **true native Windows executables** from Linux, without MinGW.

### Why Not MinGW?

- ❌ **MinGW** uses GNU ABI (incompatible with Windows libraries)
- ❌ Requires `-mwindows`, `-lmingw32`, etc.
- ❌ Can't link against MSVC-compiled libraries
- ❌ Different C runtime (msvcrt.dll vs ucrtbase.dll)

### Why clang-cl?

- ✅ **MSVC ABI** compatible (same as Visual Studio)
- ✅ Can link against any Windows library
- ✅ Uses native Windows SDK
- ✅ Produces identical binaries to Visual Studio
- ✅ Static linking with `/MT` flag
- ✅ No runtime dependencies (except SDL2)

---

## Prerequisites

### 1. Install Clang/LLVM

```bash
# Ubuntu/Debian
sudo apt install clang lld llvm

# Fedora
sudo dnf install clang lld llvm

# Arch
sudo pacman -S clang lld llvm
```

### 2. Install Rust (for xwin tool)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

### 3. Install xwin

```bash
cargo install xwin
```

**What is xwin?**
- Downloads Microsoft's Windows SDK
- Extracts headers and libraries
- No Windows installation needed
- Installs to `/opt/winsdk` (auto-created on first build)

---

## Building

### Automatic (build.sh handles everything)

```bash
TARGET_OS=windows ./build.sh
```

On first run, build.sh will:
1. Check for `/opt/winsdk`
2. If missing, install via `xwin --accept-license splat`
3. Detect SDK structure
4. Configure clang-cl with proper paths
5. Compile with MSVC ABI
6. Link with lld-link

### Manual Windows SDK Setup

```bash
# Install SDK manually
sudo mkdir -p /opt/winsdk
sudo chown $USER:$USER /opt/winsdk
xwin --accept-license splat --output /opt/winsdk
```

---

## SDL2 for Windows

You need SDL2 compiled for Windows. Two options:

### Option 1: Download Prebuilt (Easy)

```bash
# Download SDL2-devel-2.26.3-VC.zip from libsdl.org
wget https://github.com/libsdl-org/SDL/releases/download/release-2.26.3/SDL2-devel-2.26.3-VC.zip
unzip SDL2-devel-2.26.3-VC.zip
sudo mkdir -p /opt/windows-libs/SDL2
sudo cp -r SDL2-2.26.3/include /opt/windows-libs/SDL2/
sudo cp -r SDL2-2.26.3/lib/x64 /opt/windows-libs/SDL2/lib
```

### Option 2: Build from Source (Choom-approved)

```bash
# Use the provided helper script
cd examples
./build_windows_libs.sh sdl2

# This builds SDL2 with clang-cl, same as your other libs
```

---

## How It Works

### Compiler Invocation

**Traditional GCC/MinGW:**
```bash
x86_64-w64-mingw32-gcc -mwindows -lmingw32 -lSDL2main -lSDL2
```

**clang-cl (this project):**
```bash
clang-cl --target=x86_64-pc-windows-msvc \
  -fuse-ld=lld-link \
  /MT \
  -imsvc/opt/winsdk/crt/include \
  -imsvc/opt/winsdk/sdk/include/10.0.22621.0/ucrt \
  -imsvc/opt/winsdk/sdk/include/10.0.22621.0/um \
  /link \
  /libpath:/opt/winsdk/crt/lib/x86_64 \
  /libpath:/opt/winsdk/sdk/lib/10.0.22621.0/ucrt/x86_64 \
  /libpath:/opt/winsdk/sdk/lib/10.0.22621.0/um/x86_64 \
  libcmt.lib user32.lib gdi32.lib opengl32.lib
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `--target=x86_64-pc-windows-msvc` | Target Windows with MSVC ABI |
| `-fuse-ld=lld-link` | Use LLVM's Windows-compatible linker |
| `/MT` | Static link CRT (no msvcrt.dll dependency) |
| `-imsvc<path>` | System include (MSVC-style) |
| `/subsystem:windows` | GUI application (no console) |
| `/defaultlib:libcmt` | Use static multithreaded CRT |

---

## SDK Structure

xwin creates this structure:

```
/opt/winsdk/
├── crt/
│   ├── include/          # C runtime headers (stdio.h, stdlib.h)
│   └── lib/
│       └── x86_64/       # libcmt.lib, libucrt.lib
├── sdk/
│   ├── include/
│   │   └── 10.0.XXXXX/   # SDK version
│   │       ├── um/       # Windows headers (windows.h, gl/GL.h)
│   │       ├── shared/   # Shared headers (windef.h, etc.)
│   │       └── ucrt/     # Universal CRT headers
│   └── lib/
│       └── 10.0.XXXXX/
│           ├── um/
│           │   └── x86_64/  # kernel32.lib, user32.lib, gdi32.lib, opengl32.lib
│           └── ucrt/
│               └── x86_64/  # ucrt libraries
```

---

## Troubleshooting

### "xwin not found"

```bash
cargo install xwin
# Make sure ~/.cargo/bin is in PATH
export PATH="$HOME/.cargo/bin:$PATH"
```

### "SDL2 not found"

```bash
# Check expected locations
ls /opt/windows-libs/SDL2/lib
ls third_party/SDL2/lib

# Should contain: SDL2.lib, SDL2main.lib
```

### "Linker errors: unresolved external symbol"

This usually means missing Windows library. Common ones:

```bash
# Add to linker_args in build.sh:
"kernel32.lib"   # Windows kernel
"user32.lib"     # GUI functions
"gdi32.lib"      # Graphics Device Interface
"opengl32.lib"   # OpenGL
"winmm.lib"      # Multimedia (audio/timing)
"shell32.lib"    # Shell functions
```

### "Can't find <windows.h>"

Windows SDK not detected. Check:

```bash
ls /opt/winsdk/sdk/include/*/um/windows.h
ls /opt/winsdk/crt/include/stdio.h
```

If missing, reinstall:

```bash
sudo rm -rf /opt/winsdk
xwin --accept-license splat --output /opt/winsdk
```

---

## Output Binary

**zelda3.exe:**
- Native PE32+ executable
- MSVC ABI (compatible with all Windows libs)
- Static CRT (no msvcrt.dll dependency)
- Requires: `SDL2.dll` (place next to .exe)
- Runs on: Windows 7+ (x64)

---

## Comparison

| Feature | MinGW | clang-cl |
|---------|-------|----------|
| ABI | GNU | MSVC |
| Stdlib | libstdc++ | MSVCRT |
| CRT | msvcrt.dll | Static or ucrtbase.dll |
| Link MSVC libs | ❌ | ✅ |
| Link DX/Win libs | Partial | ✅ |
| Debugger | GDB | WinDbg/VS |
| Toolchain | GCC-based | LLVM-based |

---

## References

- **xwin**: https://github.com/Jake-Shadle/xwin
- **clang-cl**: https://clang.llvm.org/docs/MSVCCompatibility.html
- **lld-link**: https://lld.llvm.org/windows_support.html
- **Example**: See `examples/v64tng.sh` for real-world usage

---

## Summary

**tl;dr:**

```bash
# One-time setup (5 minutes)
sudo apt install clang lld llvm
curl https://sh.rustup.rs -sSf | sh
cargo install xwin

# Build Windows executable
TARGET_OS=windows ./build.sh

# Done - you now have zelda3.exe (native Windows binary)
```

**This is the same technique used in your v64tng.sh and speedboards.sh examples.**

No MinGW. No Wine. No Windows VM. Just pure Linux-to-Windows cross-compilation with LLVM. 🚀
