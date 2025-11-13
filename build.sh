#!/usr/bin/env bash
# Zelda3 Unified Build System
# Supports: Linux native, Windows cross-compile (clang-cl + lld-link), asset extraction
set -Eeuo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Color & Emoji Support ------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  COLOR_RESET="\033[0m"
  COLOR_BOLD="\033[1m"
  COLOR_DIM="\033[2m"
  COLOR_RED="\033[31m"
  COLOR_GREEN="\033[32m"
  COLOR_YELLOW="\033[33m"
  COLOR_CYAN="\033[36m"
  COLOR_MAGENTA="\033[35m"
else
  COLOR_RESET="" COLOR_BOLD="" COLOR_DIM="" COLOR_RED="" COLOR_GREEN="" COLOR_YELLOW="" COLOR_CYAN="" COLOR_MAGENTA=""
fi

if [[ "${LANG:-}" =~ UTF-8 ]] || [[ "${LC_ALL:-}" =~ UTF-8 ]]; then
  EMOJI_SUCCESS="✅" EMOJI_CACHED="⚡" EMOJI_FAILED="❌" EMOJI_WARNING="⚠️" EMOJI_ROCKET="🚀" EMOJI_WRENCH="🔧" EMOJI_PACKAGE="📦" EMOJI_FIRE="🔥"
else
  EMOJI_SUCCESS="[OK]" EMOJI_CACHED="[==]" EMOJI_FAILED="[!!]" EMOJI_WARNING="[!]" EMOJI_ROCKET=">>>" EMOJI_WRENCH="[*]" EMOJI_PACKAGE="[+]" EMOJI_FIRE="[X]"
fi

# --- Configuration --------------------------------------------------------
BUILD_DIR="$PROJECT_ROOT/build"
OBJ_DIR="$BUILD_DIR/obj"
ASSETS_FILE="$PROJECT_ROOT/zelda3_assets.dat"
ROM_FILE_SFC="$PROJECT_ROOT/zelda3.sfc"
ROM_FILE_SMC="$PROJECT_ROOT/zelda3.smc"

# Windows SDK for cross-compilation (via xwin)
WINSDK_BASE="/opt/winsdk"

# Auto-detect target platform
TARGET_OS="${TARGET_OS:-native}"  # native, windows
TARGET_TRIPLE="x86_64-pc-windows-msvc"

# Compiler detection
CC="${CC:-}"
if [[ -z "$CC" ]]; then
  if [[ "$TARGET_OS" == "windows" ]]; then
    CC="clang-cl"
  else
    CC="gcc"
  fi
fi

# Parallel jobs
MAX_JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
JOBS="${JOBS:-$MAX_JOBS}"
BUILD_LOG="$BUILD_DIR/build.log"

# --- Helper Functions -----------------------------------------------------
banner() {
  local w=78 line; line="$(printf '%*s' "$w" | tr ' ' '=')"
  printf "\n${COLOR_BOLD}${COLOR_CYAN}%s\n  %s\n%s${COLOR_RESET}\n\n" "$line" "$1" "$line"
}

die() { 
  echo -e "${COLOR_RED}${EMOJI_FAILED} ERROR: $*${COLOR_RESET}" >&2
  exit 1
}

need_cmd() { 
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

info() {
  echo -e "${COLOR_GREEN}${EMOJI_SUCCESS} $*${COLOR_RESET}"
}

warn() {
  echo -e "${COLOR_YELLOW}${EMOJI_WARNING} $*${COLOR_RESET}"
}

# Initialize build log
init_log() {
  rm -f "$BUILD_LOG"
  touch "$BUILD_LOG"
}

# Log warnings and errors only
log_output() {
  local tmp_file="$1"
  if [[ -f "$tmp_file" ]]; then
    if grep -qiE '(warning|error):' "$tmp_file"; then
      cat "$tmp_file" >> "$BUILD_LOG"
    fi
    rm -f "$tmp_file"
  fi
}

# --- Windows SDK Setup (for clang-cl cross-compilation) ------------------
setup_winsdk() {
  banner "${EMOJI_WRENCH} Setting up Windows SDK"
  
  if [[ ! -d "$WINSDK_BASE" ]]; then
    echo "Windows SDK not found at $WINSDK_BASE"
    echo ""
    echo "Installing Windows SDK using xwin..."
    
    # Check if xwin is installed
    if ! command -v xwin &> /dev/null; then
      echo "Installing xwin..."
      cargo install xwin || die "Failed to install xwin. Install Rust/Cargo first: https://rustup.rs"
    fi
    
    # Create the directory and install SDK
    sudo mkdir -p "$WINSDK_BASE"
    sudo chown $USER:$USER "$WINSDK_BASE"
    
    xwin --accept-license splat --output "$WINSDK_BASE" || die "Failed to install Windows SDK"
  fi
  
  # Detect SDK structure
  echo "Detecting Windows SDK structure..."
  
  local sdk_include_base="" sdk_lib_base="" ucrt_include_base="" ucrt_lib_base=""
  
  # Look for SDK includes
  [[ -d "$WINSDK_BASE/sdk/include" ]] && sdk_include_base="$WINSDK_BASE/sdk/include"
  [[ -d "$WINSDK_BASE/Include" ]] && sdk_include_base="$WINSDK_BASE/Include"
  
  # Look for SDK libs
  [[ -d "$WINSDK_BASE/sdk/lib" ]] && sdk_lib_base="$WINSDK_BASE/sdk/lib"
  [[ -d "$WINSDK_BASE/Lib" ]] && sdk_lib_base="$WINSDK_BASE/Lib"
  
  # Look for CRT includes/libs
  [[ -d "$WINSDK_BASE/crt/include" ]] && ucrt_include_base="$WINSDK_BASE/crt/include"
  [[ -d "$WINSDK_BASE/crt/lib" ]] && ucrt_lib_base="$WINSDK_BASE/crt/lib"
  
  # Find SDK version
  local actual_sdk_version=""
  if [[ -d "$sdk_include_base" ]]; then
    for version_dir in "$sdk_include_base"/*/; do
      [[ -d "$version_dir" ]] && actual_sdk_version=$(basename "$version_dir") && break
    done
  fi
  
  # Export detected paths
  export DETECTED_SDK_INCLUDE="${sdk_include_base}"
  export DETECTED_SDK_LIB="${sdk_lib_base}"
  export DETECTED_CRT_INCLUDE="${ucrt_include_base}"
  export DETECTED_CRT_LIB="${ucrt_lib_base}"
  export DETECTED_SDK_VERSION="${actual_sdk_version:-10.0.26100}"
  
  # Detect library architecture (xwin uses x86_64, traditional SDK uses x64)
  local detected_lib_arch="x86_64"
  [[ -d "$ucrt_lib_base/x64" ]] && detected_lib_arch="x64"
  export DETECTED_LIB_ARCH="$detected_lib_arch"
  
  info "SDK version: $DETECTED_SDK_VERSION"
  info "Library arch: $detected_lib_arch"
  
  # Verify critical paths
  local critical_paths=()
  if [[ -n "$sdk_include_base" ]]; then
    if [[ -d "$sdk_include_base/$DETECTED_SDK_VERSION" ]]; then
      critical_paths+=("$sdk_include_base/$DETECTED_SDK_VERSION/um" "$sdk_include_base/$DETECTED_SDK_VERSION/shared")
    else
      critical_paths+=("$sdk_include_base/um" "$sdk_include_base/shared" "$sdk_include_base/ucrt")
    fi
  fi
  [[ -n "$ucrt_include_base" ]] && critical_paths+=("$ucrt_include_base")
  
  for path in "${critical_paths[@]}"; do
    [[ ! -d "$path" ]] && die "Critical SDK path missing: $path"
  done
  
  info "All critical SDK paths verified"
}

# --- Python-based Asset Extraction ----------------------------------------
extract_assets_python() {
  banner "${EMOJI_PACKAGE} Extracting Assets (Python)"
  
  # Check for ROM file
  local rom_path=""
  if [[ -f "$ROM_FILE_SFC" ]]; then
    rom_path="$ROM_FILE_SFC"
  elif [[ -f "$ROM_FILE_SMC" ]]; then
    rom_path="$ROM_FILE_SMC"
  else
    die "ROM file not found! Please place zelda3.sfc or zelda3.smc in project root.\n\
       Required: US version with SHA-256: 66871d66be19ad2c34c927d6b14cd8eb6fc3181965b6e517cb361f7316009cfb"
  fi
  
  # Check Python
  local python_cmd=""
  if command -v python3 >/dev/null 2>&1; then
    python_cmd="python3"
  elif command -v python >/dev/null 2>&1; then
    python_cmd="python"
  else
    die "Python not found! Install python3 to extract assets."
  fi
  
  # Check Python dependencies
  echo "Checking Python dependencies..."
  if ! $python_cmd -c "import PIL" 2>/dev/null; then
    warn "Pillow not installed. Installing Python dependencies..."
    $python_cmd -m pip install --user -q Pillow PyYAML || \
      die "Failed to install Python dependencies. Run: $python_cmd -m pip install Pillow PyYAML"
  fi
  
  # Run extraction
  echo "Extracting from ROM: $(basename "$rom_path")"
  cd "$PROJECT_ROOT"
  $python_cmd assets/restool.py --extract-from-rom || die "Asset extraction failed"
  
  if [[ ! -f "$ASSETS_FILE" ]]; then
    die "Asset extraction succeeded but zelda3_assets.dat not created"
  fi
  
  info "Assets extracted successfully: $(du -h "$ASSETS_FILE" | cut -f1)"
}

# --- C-based Asset Extraction (Future Implementation) --------------------
extract_assets_c() {
  banner "${EMOJI_PACKAGE} Extracting Assets (Native C)"
  warn "C-based asset extraction not yet implemented"
  warn "Falling back to Python extraction..."
  extract_assets_python
}

# --- SDL2 Detection -------------------------------------------------------
detect_sdl2() {
  if command -v sdl2-config >/dev/null 2>&1; then
    SDL2_CFLAGS="$(sdl2-config --cflags)"
    SDL2_LIBS="$(sdl2-config --libs)"
    return 0
  fi
  
  # Windows cross-compile fallback
  if [[ "$TARGET_OS" == "windows" ]]; then
    # Try pkg-config for mingw
    if command -v x86_64-w64-mingw32-pkg-config >/dev/null 2>&1; then
      SDL2_CFLAGS="$(x86_64-w64-mingw32-pkg-config --cflags sdl2 2>/dev/null || echo "")"
      SDL2_LIBS="$(x86_64-w64-mingw32-pkg-config --libs sdl2 2>/dev/null || echo "")"
      [[ -n "$SDL2_LIBS" ]] && return 0
    fi
    
    # Hardcoded fallback for Windows
    warn "SDL2 not found via pkg-config, using manual detection"
    local sdl_paths=(
      "/usr/x86_64-w64-mingw32/sys-root/mingw/include/SDL2"
      "/usr/local/x86_64-w64-mingw32/include/SDL2"
    )
    for path in "${sdl_paths[@]}"; do
      if [[ -d "$path" ]]; then
        SDL2_CFLAGS="-I$path -D_THREAD_SAFE"
        SDL2_LIBS="-lmingw32 -lSDL2main -lSDL2 -mwindows"
        return 0
      fi
    done
  fi
  
  die "SDL2 not found! Install with:\n\
    Ubuntu/Debian: sudo apt install libsdl2-dev\n\
    Fedora: sudo dnf install SDL2-devel\n\
    Arch: sudo pacman -S sdl2\n\
    Windows (MinGW): pacman -S mingw-w64-x86_64-SDL2"
}

# --- Compilation ----------------------------------------------------------
compile() {
  banner "${EMOJI_WRENCH} Compiling Zelda3"
  
  mkdir -p "$OBJ_DIR"
  
  # Detect SDL2
  detect_sdl2
  info "SDL2 found: $SDL2_CFLAGS"
  
  # Compiler flags
  local cflags="-O2 -I. -DSYSTEM_VOLUME_MIXER_AVAILABLE=0 $SDL2_CFLAGS"
  local ldflags="$SDL2_LIBS"
  
  # Platform-specific flags
  if [[ "$TARGET_OS" == "windows" ]]; then
    cflags="$cflags -D_WIN32 -DWIN32"
    ldflags="$ldflags -lopengl32 -lwinmm -limm32 -lole32 -loleaut32 -lversion -luuid -lsetupapi"
  else
    ldflags="$ldflags -lm -ldl"
    if [[ "$(uname)" == "Linux" ]]; then
      ldflags="$ldflags -lGL"
    elif [[ "$(uname)" == "Darwin" ]]; then
      ldflags="$ldflags -framework OpenGL -framework CoreAudio -framework AudioToolbox"
    fi
  fi
  
  # Output executable
  local output="$PROJECT_ROOT/zelda3"
  [[ "$TARGET_OS" == "windows" ]] && output="$PROJECT_ROOT/zelda3.exe"
  
  # Source files
  local sources=(
    src/*.c
    snes/*.c
    third_party/gl_core/gl_core_3_1.c
    third_party/opus-1.3.1-stripped/opus_decoder_amalgam.c
  )
  
  # Object files
  local objs=()
  local src_files=()
  for pattern in "${sources[@]}"; do
    for src in $pattern; do
      [[ -f "$src" ]] && src_files+=("$src")
    done
  done
  
  echo "Compiling ${#src_files[@]} source files with $JOBS parallel jobs..."
  
  # Compile in parallel
  local failed=0
  local compiled=0
  local total=${#src_files[@]}
  
  compile_one() {
    local src="$1"
    local obj="$OBJ_DIR/$(echo "$src" | tr '/' '_' | sed 's/\.c$/.o/')"
    
    # Check if recompilation needed
    if [[ -f "$obj" && "$obj" -nt "$src" ]]; then
      return 0
    fi
    
    if $CC $cflags -c "$src" -o "$obj" 2>&1; then
      return 0
    else
      return 1
    fi
  }
  
  export -f compile_one
  export CC cflags OBJ_DIR
  
  if command -v parallel >/dev/null 2>&1; then
    # Use GNU parallel if available
    printf "%s\n" "${src_files[@]}" | parallel -j "$JOBS" compile_one || die "Compilation failed"
  else
    # Fallback: compile sequentially
    for src in "${src_files[@]}"; do
      printf "  [%3d/%3d] %s\n" "$((++compiled))" "$total" "$(basename "$src")"
      compile_one "$src" || die "Failed to compile $src"
    done
  fi
  
  # Collect object files
  for src in "${src_files[@]}"; do
    local obj="$OBJ_DIR/$(echo "$src" | tr '/' '_' | sed 's/\.c$/.o/')"
    objs+=("$obj")
  done
  
  info "Compiled ${#objs[@]} object files"
  
  # Link
  echo "Linking..."
  $CC "${objs[@]}" -o "$output" $ldflags || die "Linking failed"
  
  info "Built: $output ($(du -h "$output" | cut -f1))"
}

# --- Clean ----------------------------------------------------------------
clean() {
  banner "🧹 Cleaning"
  rm -rf "$BUILD_DIR"
  rm -f "$PROJECT_ROOT/zelda3" "$PROJECT_ROOT/zelda3.exe"
  info "Cleaned build artifacts"
}

clean_all() {
  clean
  rm -f "$ASSETS_FILE"
  rm -rf "$PROJECT_ROOT/tables/__pycache__"
  rm -rf "$PROJECT_ROOT/tables"/*.txt
  rm -rf "$PROJECT_ROOT/tables"/*.png
  rm -rf "$PROJECT_ROOT/tables"/*.yaml
  rm -rf "$PROJECT_ROOT/tables"/sprites/*.png
  rm -rf "$PROJECT_ROOT/tables"/dungeon
  rm -rf "$PROJECT_ROOT/tables"/img
  rm -rf "$PROJECT_ROOT/tables"/overworld
  rm -rf "$PROJECT_ROOT/tables"/sound
  info "Cleaned all generated files"
}

# --- Main -----------------------------------------------------------------
show_help() {
  cat <<EOF
${COLOR_BOLD}Zelda3 Unified Build System${COLOR_RESET}

${COLOR_CYAN}USAGE:${COLOR_RESET}
  ./build.sh [COMMAND] [OPTIONS]

${COLOR_CYAN}COMMANDS:${COLOR_RESET}
  all              Extract assets and compile (default)
  assets           Extract assets from ROM only
  compile          Compile only (requires existing assets)
  clean            Remove build artifacts
  clean-all        Remove all generated files including assets
  help             Show this help

${COLOR_CYAN}OPTIONS:${COLOR_RESET}
  TARGET_OS        Target OS: native (default), windows, linux
  TARGET_ARCH      Target architecture: x86_64 (default), i686
  CC               C compiler to use
  JOBS             Number of parallel jobs (default: CPU count)
  USE_C_EXTRACTOR  Use C-based asset extraction (default: 0)

${COLOR_CYAN}EXAMPLES:${COLOR_RESET}
  ./build.sh                           # Build for native platform
  ./build.sh assets                    # Extract assets only
  TARGET_OS=windows ./build.sh         # Cross-compile for Windows
  CC=clang JOBS=8 ./build.sh           # Use clang with 8 jobs
  ./build.sh clean && ./build.sh all   # Clean rebuild

${COLOR_CYAN}REQUIREMENTS:${COLOR_RESET}
  - ROM: zelda3.sfc (US version) in project root
  - Python 3 with Pillow and PyYAML (for asset extraction)
  - SDL2 development libraries
  - GCC or Clang compiler

${COLOR_CYAN}WINDOWS CROSS-COMPILE:${COLOR_RESET}
  Install MinGW-w64:
    Ubuntu: sudo apt install mingw-w64
    Fedora: sudo dnf install mingw64-gcc mingw64-SDL2
  Then run: TARGET_OS=windows ./build.sh

EOF
}

# --- Entry Point ----------------------------------------------------------
main() {
  local cmd="${1:-all}"
  
  case "$cmd" in
    all)
      if [[ ! -f "$ASSETS_FILE" ]]; then
        if [[ "${USE_C_EXTRACTOR:-0}" == "1" ]]; then
          extract_assets_c
        else
          extract_assets_python
        fi
      else
        info "Assets already extracted: $ASSETS_FILE"
      fi
      compile
      info "${EMOJI_ROCKET} Build complete! Run with: ./zelda3"
      ;;
    assets)
      if [[ "${USE_C_EXTRACTOR:-0}" == "1" ]]; then
        extract_assets_c
      else
        extract_assets_python
      fi
      ;;
    compile)
      [[ -f "$ASSETS_FILE" ]] || die "Assets not found! Run './build.sh assets' first"
      compile
      ;;
    clean)
      clean
      ;;
    clean-all)
      clean_all
      ;;
    help|--help|-h)
      show_help
      ;;
    *)
      die "Unknown command: $cmd\nRun './build.sh help' for usage"
      ;;
  esac
}

main "$@"
