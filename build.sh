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
  local missing_deps=()
  
  if ! $python_cmd -c "import PIL" 2>/dev/null; then
    missing_deps+=("Pillow")
  fi
  
  if ! $python_cmd -c "import yaml" 2>/dev/null; then
    missing_deps+=("PyYAML")
  fi
  
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    warn "Missing Python packages: ${missing_deps[*]}"
    echo "Installing Python dependencies..."
    
    # Check if pip is available
    if ! $python_cmd -m pip --version >/dev/null 2>&1; then
      die "pip not found! Install with: $python_cmd -m ensurepip --default-pip"
    fi
    
    # Install missing packages
    $python_cmd -m pip install --user -q "${missing_deps[@]}" || \
      die "Failed to install Python dependencies. Try manually: $python_cmd -m pip install ${missing_deps[*]}"
    
    info "Python dependencies installed successfully"
  else
    info "All Python dependencies satisfied"
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

# --- SDL2 Build (Windows) ------------------------------------------------
build_sdl2_windows() {
  banner "${EMOJI_PACKAGE} Building SDL2 for Windows"
  
  local sdl2_version="2.28.5"
  local sdl2_install="/opt/windows-libs/SDL2"
  local build_dir="/tmp/sdl2-build"
  
  # Check if already built
  if [[ -d "$sdl2_install/include" && -d "$sdl2_install/lib" ]]; then
    if [[ -f "$sdl2_install/lib/SDL2.lib" && -f "$sdl2_install/lib/SDL2main.lib" ]]; then
      info "SDL2 already built at: $sdl2_install"
      return 0
    fi
  fi
  
  info "Building SDL2 ${sdl2_version} for Windows..."
  
  # Check build dependencies
  need_cmd wget
  need_cmd cmake
  need_cmd clang-cl
  need_cmd lld-link
  need_cmd llvm-lib
  
  # Create directories
  sudo mkdir -p "$sdl2_install"
  sudo chown $USER:$USER "$sdl2_install"
  mkdir -p "$build_dir"
  
  cd "$build_dir"
  
  # Download SDL2 if not present
  if [[ ! -d "SDL2-${sdl2_version}" ]]; then
    echo "Downloading SDL2 ${sdl2_version}..."
    wget "https://github.com/libsdl-org/SDL/releases/download/release-${sdl2_version}/SDL2-${sdl2_version}.tar.gz" || \
      die "Failed to download SDL2"
    tar -xzf "SDL2-${sdl2_version}.tar.gz"
  fi
  
  cd "SDL2-${sdl2_version}"
  rm -rf build_windows
  mkdir build_windows
  cd build_windows
  
  # Create CMake toolchain file
  local sdk_include="${DETECTED_SDK_INCLUDE:-$WINSDK_BASE/sdk/include}"
  local sdk_lib="${DETECTED_SDK_LIB:-$WINSDK_BASE/sdk/lib}"
  local crt_include="${DETECTED_CRT_INCLUDE:-$WINSDK_BASE/crt/include}"
  local crt_lib="${DETECTED_CRT_LIB:-$WINSDK_BASE/crt/lib}"
  local sdk_version="${DETECTED_SDK_VERSION:-10.0.26100}"
  
  # Build include flags for CMake
  local cmake_include_flags=""
  [[ -d "$crt_include" ]] && cmake_include_flags+="-imsvc ${crt_include} "
  [[ -d "$sdk_include/$sdk_version/um" ]] && cmake_include_flags+="-imsvc ${sdk_include}/${sdk_version}/um "
  [[ -d "$sdk_include/$sdk_version/shared" ]] && cmake_include_flags+="-imsvc ${sdk_include}/${sdk_version}/shared "
  [[ -d "$sdk_include/$sdk_version/ucrt" ]] && cmake_include_flags+="-imsvc ${sdk_include}/${sdk_version}/ucrt "
  
  # Build lib flags for CMake
  local cmake_lib_flags=""
  [[ -d "$crt_lib/x86_64" ]] && cmake_lib_flags+="-libpath:${crt_lib}/x86_64 "
  [[ -d "$sdk_lib/um/x86_64" ]] && cmake_lib_flags+="-libpath:${sdk_lib}/um/x86_64 "
  [[ -d "$sdk_lib/ucrt/x86_64" ]] && cmake_lib_flags+="-libpath:${sdk_lib}/ucrt/x86_64 "
  
  # Build Windows library paths
  local cmake_windows_libs="${cmake_lib_flags}"
  [[ -f "$sdk_lib/um/x86_64/kernel32.lib" ]] && cmake_windows_libs+="${sdk_lib}/um/x86_64/kernel32.lib "
  [[ -f "$sdk_lib/um/x86_64/user32.lib" ]] && cmake_windows_libs+="${sdk_lib}/um/x86_64/user32.lib "
  [[ -f "$crt_lib/x86_64/libcmt.lib" ]] && cmake_windows_libs+="${crt_lib}/x86_64/libcmt.lib "
  [[ -f "$sdk_lib/ucrt/x86_64/libucrt.lib" ]] && cmake_windows_libs+="${sdk_lib}/ucrt/x86_64/libucrt.lib "
  
  cat > windows-cross.cmake << EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

set(CMAKE_C_COMPILER clang-cl)
set(CMAKE_CXX_COMPILER clang-cl)

set(CMAKE_C_COMPILER_TARGET x86_64-pc-windows-msvc)
set(CMAKE_CXX_COMPILER_TARGET x86_64-pc-windows-msvc)

set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_CXX_COMPILER_WORKS 1)
set(CMAKE_DETERMINE_C_ABI_COMPILED 1)
set(CMAKE_DETERMINE_CXX_ABI_COMPILED 1)

set(CMAKE_AR llvm-lib)
set(CMAKE_C_ARCHIVE_CREATE "<CMAKE_AR> /OUT:<TARGET> <OBJECTS>")
set(CMAKE_C_ARCHIVE_FINISH "")
set(CMAKE_CXX_ARCHIVE_CREATE "<CMAKE_AR> /OUT:<TARGET> <OBJECTS>")
set(CMAKE_CXX_ARCHIVE_FINISH "")

set(CMAKE_C_FLAGS_INIT "-fuse-ld=lld-link $cmake_include_flags /MT -D_WIN32 -D_WIN64 -fms-compatibility -fms-compatibility-version=19.37")
set(CMAKE_CXX_FLAGS_INIT "-fuse-ld=lld-link $cmake_include_flags /MT -D_WIN32 -D_WIN64 -fms-compatibility -fms-compatibility-version=19.37")

set(CMAKE_C_FLAGS_RELEASE_INIT "-O2 -DNDEBUG -D_MT")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-O2 -DNDEBUG -D_MT")

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

set(CMAKE_EXE_LINKER_FLAGS_INIT "$cmake_windows_libs -DEFAULTLIB:libcmt.lib -NODEFAULTLIB:msvcrt.lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "$cmake_windows_libs -DEFAULTLIB:libcmt.lib -NODEFAULTLIB:msvcrt.lib")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "$cmake_windows_libs -DEFAULTLIB:libcmt.lib -NODEFAULTLIB:msvcrt.lib")

set(CMAKE_C_STANDARD_LIBRARIES "$cmake_windows_libs")
set(CMAKE_CXX_STANDARD_LIBRARIES "$cmake_windows_libs")

set(CMAKE_FIND_ROOT_PATH "$WINSDK_BASE" "$sdl2_install")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
  
  # Set environment variables for clang-cl
  local include_paths=""
  [[ -d "$crt_include" ]] && include_paths+="$crt_include;"
  [[ -d "$sdk_include/$sdk_version/um" ]] && include_paths+="$sdk_include/$sdk_version/um;"
  [[ -d "$sdk_include/$sdk_version/shared" ]] && include_paths+="$sdk_include/$sdk_version/shared;"
  [[ -d "$sdk_include/$sdk_version/ucrt" ]] && include_paths+="$sdk_include/$sdk_version/ucrt;"
  
  local lib_paths=""
  [[ -d "$crt_lib/x86_64" ]] && lib_paths+="$crt_lib/x86_64;"
  [[ -d "$sdk_lib/um/x86_64" ]] && lib_paths+="$sdk_lib/um/x86_64;"
  [[ -d "$sdk_lib/ucrt/x86_64" ]] && lib_paths+="$sdk_lib/ucrt/x86_64;"
  
  export INCLUDE="$include_paths"
  export LIB="$lib_paths"
  
  echo "Configuring SDL2 with CMake..."
  cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=windows-cross.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$sdl2_install" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDL_STATIC=ON \
    -DSDL_SHARED=OFF \
    -DSDL_TEST=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded || die "SDL2 CMake configuration failed"
  
  echo "Building SDL2..."
  make -j$(nproc) || die "SDL2 build failed"
  
  echo "Installing SDL2..."
  make install || die "SDL2 installation failed"
  
  # Normalize and verify installation
  mkdir -p "$sdl2_install/lib"
  # Try to locate SDL2 static lib in common install layouts and copy to a canonical name
  SDL2_CANONICAL_LIB="$sdl2_install/lib/SDL2.lib"
  found_sdl2=""
  for candidate in \
    "$sdl2_install/lib/SDL2.lib" \
    "$sdl2_install/lib/SDL2-static.lib" \
    "$sdl2_install/lib64/SDL2.lib" \
    "$sdl2_install/lib64/SDL2-static.lib" \
    "$sdl2_install/x64/lib/SDL2.lib" \
    "$sdl2_install/x64/lib/SDL2-static.lib"; do
    if [[ -f "$candidate" ]]; then
      cp -f "$candidate" "$SDL2_CANONICAL_LIB"
      found_sdl2="$SDL2_CANONICAL_LIB"
      break
    fi
  done
  # Optional SDL2main lib: copy if present to canonical location
  for candidate in \
    "$sdl2_install/lib/SDL2main.lib" \
    "$sdl2_install/lib64/SDL2main.lib" \
    "$sdl2_install/x64/lib/SDL2main.lib"; do
    if [[ -f "$candidate" ]]; then
      cp -f "$candidate" "$sdl2_install/lib/SDL2main.lib" 2>/dev/null || true
      break
    fi
  done
  
  [[ -f "$found_sdl2" ]] || die "SDL2 build succeeded but libraries not found at: $sdl2_install/lib"
  
  info "SDL2 built successfully at: $sdl2_install"
  info "SDL2.lib size: $(stat -c%s "$sdl2_install/lib/SDL2.lib" 2>/dev/null || stat -f%z "$sdl2_install/lib/SDL2.lib") bytes"
}

# --- SDL2 Detection -------------------------------------------------------
detect_sdl2() {
  if [[ "$TARGET_OS" == "windows" ]]; then
    # For Windows cross-compile, check for prebuilt or build it
    local sdl2_paths=(
      "/opt/windows-libs/SDL2"
      "$PROJECT_ROOT/third_party/SDL2"
    )
    
    for path in "${sdl2_paths[@]}"; do
      if [[ -d "$path/include" && -f "$path/lib/SDL2.lib" ]]; then
        # Include both include roots to support either layout (SDL.h or SDL2/SDL.h)
        SDL2_CFLAGS="-I$path/include -I$path/include/SDL2"
        SDL2_LIBS="$path/lib/SDL2.lib"
        info "Found SDL2 for Windows at: $path"
        return 0
      fi
    done
    
    # Not found - build it automatically
    warn "SDL2 for Windows not found, building automatically..."
    build_sdl2_windows
    
    # Check again after build
    for path in "${sdl2_paths[@]}"; do
      if [[ -d "$path/include" && -f "$path/lib/SDL2.lib" ]]; then
        SDL2_CFLAGS="-I$path/include -I$path/include/SDL2"
        SDL2_LIBS="$path/lib/SDL2.lib"
        info "Using newly built SDL2 at: $path"
        return 0
      fi
    done
    
    die "SDL2 build completed but libraries not found"
  else
    # Native Linux/macOS build
    if command -v sdl2-config >/dev/null 2>&1; then
      SDL2_CFLAGS="$(sdl2-config --cflags)"
      SDL2_LIBS="$(sdl2-config --libs)"
      info "SDL2 found via sdl2-config"
      return 0
    fi
    
    die "SDL2 not found! Install with:\n\
      Ubuntu/Debian: sudo apt install libsdl2-dev\n\
      Fedora: sudo dnf install SDL2-devel\n\
      Arch: sudo pacman -S sdl2\n\
      macOS: brew install sdl2"
  fi
}

# --- Compilation Helper Functions -----------------------------------------
needs_compile() {
  local src="$1"
  local obj="$2"
  local dep_file="$BUILD_DIR/$(basename "${src%.c}").d"
  
  [[ ! -f "$obj" ]] && return 0
  [[ "$src" -nt "$obj" ]] && return 0
  [[ ! -s "$obj" ]] && return 0
  
  # Check dependencies
  if [[ -f "$dep_file" ]]; then
    while read -r dep; do
      dep=$(echo "$dep" | sed 's/^[^:]*:\s*//' | tr ' ' '\n' | head -1)
      [[ -z "$dep" ]] && continue
      [[ "$dep" -nt "$obj" ]] && return 0
    done < "$dep_file"
  fi
  
  return 1
}

compile_batch() {
  local batch_sources=("$@")
  local pids=()
  local temp_outputs=()
  local obj_ext=".o"
  [[ "$TARGET_OS" == "windows" ]] && obj_ext=".obj"
  
  for src in "${batch_sources[@]}"; do
    obj="$OBJ_DIR/$(basename "${src%.c}")${obj_ext}"
    
    if needs_compile "$src" "$obj"; then
      local temp_out="$BUILD_DIR/$(basename "${src%.c}").compile.tmp"
      temp_outputs+=("$temp_out")
      
      {
        if "$CC" -c "$src" -o "$obj" "${CFLAGS[@]}" 2>"$temp_out"; then
          echo -e "  ${COLOR_GREEN}${EMOJI_SUCCESS} $(basename "$src")${COLOR_RESET}" > "$temp_out.status"
        else
          echo -e "  ${COLOR_RED}${EMOJI_FAILED} FAILED: $(basename "$src")${COLOR_RESET}" > "$temp_out.status"
          echo "1" > "$temp_out.failed"
        fi
      } &
      pids+=($!)
    else
      echo -e "  ${COLOR_DIM}${EMOJI_CACHED} $(basename "$src") (cached)${COLOR_RESET}"
    fi
  done
  
  # Wait for all jobs
  local any_failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || any_failed=1
  done
  
  # Print outputs
  for temp_out in "${temp_outputs[@]}"; do
    [[ -f "$temp_out.status" ]] && cat "$temp_out.status"
    [[ -s "$temp_out" ]] && cat "$temp_out" >> "$BUILD_LOG"
    [[ -f "$temp_out.failed" ]] && any_failed=1
    rm -f "$temp_out" "$temp_out.status" "$temp_out.failed"
  done
  
  return $any_failed
}

# --- Compilation ----------------------------------------------------------
compile() {
  banner "${EMOJI_FIRE} Compiling Zelda3"
  
  mkdir -p "$OBJ_DIR"
  init_log
  
  # Detect SDL2
  detect_sdl2
  
  # Source files
  local sources=()
  sources+=($(find src -name "*.c" | sort))
  sources+=($(find snes -name "*.c" | sort))
  sources+=(third_party/gl_core/gl_core_3_1.c)
  sources+=(third_party/opus-1.3.1-stripped/opus_decoder_amalgam.c)
  
  echo "Found ${#sources[@]} source files"
  
  # Build for Windows (clang-cl cross-compile)
  if [[ "$TARGET_OS" == "windows" ]]; then
    banner "${EMOJI_WRENCH} Windows Cross-Compile (clang-cl + lld-link)"
    
    # Setup Windows SDK
    setup_winsdk
    
    # Build system includes (use -imsvc for system headers)
    local system_includes=()
    [[ -d "$DETECTED_CRT_INCLUDE" ]] && system_includes+=("-imsvc$DETECTED_CRT_INCLUDE")
    
    if [[ -d "$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION" ]]; then
      system_includes+=(
        "-imsvc$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/ucrt"
        "-imsvc$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/um"
        "-imsvc$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/shared"
      )
    else
      system_includes+=(
        "-imsvc$DETECTED_SDK_INCLUDE/ucrt"
        "-imsvc$DETECTED_SDK_INCLUDE/um"
        "-imsvc$DETECTED_SDK_INCLUDE/shared"
      )
    fi
    
    # User includes (use -I for project headers)
    local user_includes=("-I." "-I./src" "-I./snes" "-I./third_party")
    # Append SDL2 include tokens individually (not as one quoted string)
    if [[ -n "$SDL2_CFLAGS" ]]; then
      # shellcheck disable=SC2206
      user_includes+=($SDL2_CFLAGS)
    fi
    
    # Compiler flags (MSVC-style for clang-cl)
    export CFLAGS=(
      "--target=$TARGET_TRIPLE"
      "-fuse-ld=lld-link"
      "${system_includes[@]}"
      "${user_includes[@]}"
      "/MT"  # Static CRT
      "/O2"  # Optimize
      "/DNDEBUG"
      "/DSDL_MAIN_HANDLED"  # Avoid dependency on SDL2main.lib
      "/DUNICODE"
      "/D_UNICODE"
      "/DWIN32"
      "/D_WIN32"
      "/DSYSTEM_VOLUME_MIXER_AVAILABLE=0"
      "-fms-compatibility"
      "-fms-compatibility-version=19.37"
      "-Wno-unused-command-line-argument"
    )
    
    export CC="clang-cl"
    
    # Set environment variables for header/library lookup
    local include_paths="" lib_paths=""
    [[ -d "$DETECTED_CRT_INCLUDE" ]] && include_paths+="$DETECTED_CRT_INCLUDE;"
    [[ -d "$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/um" ]] && include_paths+="$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/um;"
    [[ -d "$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/shared" ]] && include_paths+="$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/shared;"
    [[ -d "$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/ucrt" ]] && include_paths+="$DETECTED_SDK_INCLUDE/$DETECTED_SDK_VERSION/ucrt;"
    
    [[ -d "$DETECTED_CRT_LIB/$DETECTED_LIB_ARCH" ]] && lib_paths+="$DETECTED_CRT_LIB/$DETECTED_LIB_ARCH;"
    [[ -d "$DETECTED_SDK_LIB/um/$DETECTED_LIB_ARCH" ]] && lib_paths+="$DETECTED_SDK_LIB/um/$DETECTED_LIB_ARCH;"
    [[ -d "$DETECTED_SDK_LIB/ucrt/$DETECTED_LIB_ARCH" ]] && lib_paths+="$DETECTED_SDK_LIB/ucrt/$DETECTED_LIB_ARCH;"
    
    export INCLUDE="$include_paths"
    export LIB="$lib_paths"
    
  else
    # Build for Linux/macOS (native)
    banner "${EMOJI_WRENCH} Native Linux/macOS Build"
    
    export CFLAGS=(
      "-O2"
      "-I."
      "-Isrc"
      "-Isnes"
      "-Ithird_party"
      $SDL2_CFLAGS
      "-DSYSTEM_VOLUME_MIXER_AVAILABLE=0"
      "-Wall"
      "-Wno-unused-function"
    )
    
    export CC="${CC:-gcc}"
  fi
  
  # Detect flag changes
  flags_file="$BUILD_DIR/.cflags"
  new_flags="CC=$CC
CFLAGS=${CFLAGS[*]}
TARGET_OS=$TARGET_OS"
  
  if [[ ! -f "$flags_file" ]] || ! cmp -s <(printf "%s" "$new_flags") "$flags_file"; then
    warn "Build flags changed, forcing full rebuild"
    printf "%s" "$new_flags" > "$flags_file"
    rm -f "$OBJ_DIR"/*.o "$OBJ_DIR"/*.obj
  fi
  
  # Parallel compilation
  START_TIME=$(date +%s)
  BATCH_SIZE=$JOBS
  
  for ((i=0; i<${#sources[@]}; i+=BATCH_SIZE)); do
    batch=("${sources[@]:i:BATCH_SIZE}")
    compile_batch "${batch[@]}" || die "Compilation failed"
  done
  
  END_TIME=$(date +%s)
  info "Compilation completed in $((END_TIME - START_TIME))s"
  
  # Collect object files
  local objects=()
  for src in "${sources[@]}"; do
    if [[ "$TARGET_OS" == "windows" ]]; then
      objects+=("$OBJ_DIR/$(basename "${src%.c}").obj")
    else
      objects+=("$OBJ_DIR/$(basename "${src%.c}").o")
    fi
  done
  
  # Linking
  banner "${EMOJI_WRENCH} Linking"
  
  if [[ "$TARGET_OS" == "windows" ]]; then
    local output="$PROJECT_ROOT/zelda3.exe"
    
    local linker_args=(
      "/subsystem:windows"
      "/defaultlib:libcmt"
      "/defaultlib:libucrt"
      "/nodefaultlib:msvcrt.lib"
      "/libpath:$DETECTED_SDK_LIB/um/$DETECTED_LIB_ARCH"
      "/libpath:$DETECTED_SDK_LIB/ucrt/$DETECTED_LIB_ARCH"
      "/libpath:$DETECTED_CRT_LIB/$DETECTED_LIB_ARCH"
      "user32.lib"
      "gdi32.lib"
      "opengl32.lib"
      "winmm.lib"
      "shell32.lib"
    )
    
    # Add SDL2 libs
    [[ -n "$SDL2_LIBS" ]] && linker_args+=("$SDL2_LIBS")
    
    echo "Linking ${output}..."
    clang-cl --target="$TARGET_TRIPLE" -fuse-ld=lld-link "${objects[@]}" -o "$output" /link "${linker_args[@]}" || die "Linking failed"
    
  else
    local output="$PROJECT_ROOT/zelda3"
    
    local ldflags=("$SDL2_LIBS" "-lm" "-ldl")
    if [[ "$(uname)" == "Linux" ]]; then
      ldflags+=("-lGL")
    elif [[ "$(uname)" == "Darwin" ]]; then
      ldflags+=("-framework OpenGL" "-framework CoreAudio" "-framework AudioToolbox")
    fi
    
    echo "Linking ${output}..."
    $CC "${objects[@]}" -o "$output" "${ldflags[@]}" || die "Linking failed"
  fi
  
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

${COLOR_CYAN}WINDOWS CROSS-COMPILE (clang-cl + xwin):${COLOR_RESET}
  Install requirements:
    1. Clang/LLVM: sudo apt install clang lld llvm
    2. Rust (for xwin): curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    3. xwin: cargo install xwin
    4. SDL2 for Windows: Build with clang-cl or download SDL2-devel-VC.zip
  
  Then run: TARGET_OS=windows ./build.sh
  
  This produces true native Windows .exe files (MSVC ABI compatible)
  No MinGW required!

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
