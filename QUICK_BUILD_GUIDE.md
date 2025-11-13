# Zelda3 - Quick Build Guide

## TL;DR - Just Build It

```bash
# 1. Get the US ROM (zelda3.sfc) - place in project root
# 2. Build everything:
./build.sh
# 3. Run:
./zelda3
```

---

## ROM File Required

**Filename**: `zelda3.sfc` or `zelda3.smc`  
**Region**: USA  
**SHA-256**: `66871d66be19ad2c34c927d6b14cd8eb6fc3181965b6e517cb361f7316009cfb`

Place ROM in project root directory before building.

---

## Build Commands

```bash
# Full build (assets + compile)
./build.sh

# Extract assets only
./build.sh assets

# Compile only (after assets exist)
./build.sh compile

# Clean build artifacts
./build.sh clean

# Nuclear clean (remove everything)
./build.sh clean-all

# Windows cross-compile from Linux
TARGET_OS=windows ./build.sh

# Use Clang instead of GCC
CC=clang ./build.sh

# Parallel build with 16 jobs
JOBS=16 ./build.sh
```

---

## Dependencies

### Linux (Ubuntu/Debian)
```bash
sudo apt install build-essential libsdl2-dev python3 python3-pip
python3 -m pip install Pillow PyYAML
```

### Linux (Fedora)
```bash
sudo dnf install gcc SDL2-devel python3 python3-pip
python3 -m pip install Pillow PyYAML
```

### Linux (Arch)
```bash
sudo pacman -S base-devel sdl2 python python-pip
python3 -m pip install Pillow PyYAML
```

### macOS
```bash
brew install sdl2 python3
python3 -m pip install Pillow PyYAML
```

### Windows (Cross-compile from Linux using clang-cl)
```bash
# Install Clang/LLVM
sudo apt install clang lld llvm

# Install Rust (for xwin tool)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install xwin (downloads Windows SDK)
cargo install xwin

# xwin will auto-install Windows SDK to /opt/winsdk on first build
# You also need SDL2 built for Windows - see examples/build_windows_libs.sh

# Build for Windows
TARGET_OS=windows ./build.sh

# Output: zelda3.exe (native Windows binary, MSVC ABI compatible)
```

**Note**: This uses clang-cl + lld-link, NOT MinGW. Produces true native Windows executables.

---

## Common Issues

### "ROM not found"
- Place `zelda3.sfc` in project root
- Verify it's the US version (check SHA-256)

### "SDL2 not found"
- Install SDL2 development packages (see Dependencies above)

### "Python module not found"
```bash
python3 -m pip install --user Pillow PyYAML
```

### "Permission denied: build.sh"
```bash
chmod +x build.sh
```

---

## What Gets Built

- **Native**: `zelda3` (Linux/macOS)
- **Windows**: `zelda3.exe`
- **Assets**: `zelda3_assets.dat` (4.2 MB)
- **Build files**: `build/obj/*.o`

---

## Old Build Systems (Still Available)

### Makefile (Linux/macOS)
```bash
make -j$(nproc)
```

### Visual Studio (Windows)
1. Open `Zelda3.sln`
2. Build → Build Solution

### TCC (Windows Minimal)
1. Download TCC + SDL2 (see `run_with_tcc.bat`)
2. Double-click `extract_assets.bat`
3. Double-click `run_with_tcc.bat`

---

## Configuration

Edit `zelda3.ini` to configure:
- Window size
- Fullscreen mode
- Key bindings
- Graphics options
- Audio settings

---

## Controls (Default)

| Button | Key |
|--------|-----|
| D-Pad | Arrow Keys |
| A | X |
| B | Z |
| X | S |
| Y | A |
| L | C |
| R | V |
| Start | Enter |
| Select | Right Shift |

---

## Help & Documentation

- **Full docs**: See `BUILD_SYSTEM_ANALYSIS.md`
- **Original README**: See `README.md`
- **Discord**: https://discord.gg/AJJbJAzNNJ
- **GitHub**: https://github.com/snesrev/zelda3

---

## License

MIT License - See `LICENSE.txt`
