#!/usr/bin/env bash
set -euo pipefail
# mac-build.sh
# Build a macOS Emacs.app from source (mac-port style) with optional icon
usage() {
    cat <<EOF
Usage: $0 [options]
Options:
  --src DIR           Emacs source directory (default: current directory)
  --app-dir DIR       Directory for --enable-mac-app (where Emacs.app will be created)
                      (default: $HOME/Documents/emacs-mac-build)
  --prefix DIR        Optional install prefix for configure --prefix
  --icon PATH         Path to an icon file (PNG or ICNS). PNG will be converted to ICNS.
  --assets PATH       Path to Assets.car file to apply (Tahoe macOS 26+)
  --jobs N            Number of parallel make jobs (default: cpu count)
  --sign-identity ID  Codesign identity (default: ad-hoc '-'). Use --no-sign to skip signing.
  --no-sign           Do not run codesign after build
  --dry-run           Print actions but don't run build commands
  --help              Show this help
EOF
}
# Defaults
SRC_DIR="$(pwd)"
APP_DIR="$HOME/Documents/emacs-mac-build"
ICON_PATH=""
ASSETS_PATH=""
JOBS=""
PREFIX=""
DRY_RUN=0
SIGN_IDENTITY="-"
NO_SIGN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
    --src)
        SRC_DIR="$2"
        shift 2
        ;;
    --app-dir)
        APP_DIR="$2"
        shift 2
        ;;
    --icon)
        ICON_PATH="$2"
        shift 2
        ;;
    --assets)
        ASSETS_PATH="$2"
        shift 2
        ;;
    --jobs)
        JOBS="$2"
        shift 2
        ;;
    --prefix)
        PREFIX="$2"
        shift 2
        ;;
    --sign-identity)
        SIGN_IDENTITY="$2"
        shift 2
        ;;
    --no-sign)
        NO_SIGN=1
        shift
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done
if [[ -z "$JOBS" ]]; then
    if command -v sysctl >/dev/null 2>&1; then
        JOBS=$(sysctl -n hw.ncpu)
    else
        JOBS=4
    fi
fi
echocmd() {
    echo "+ $*"
    if [[ $DRY_RUN -eq 0 ]]; then
        "$@"
    fi
}
convert_image_to_icns() {
    # $1 = input image (PNG/JPEG/etc)
    # $2 = output .icns file path
    local input="$1" output_icns="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' RETURN
    local iconsetdir="$tmpdir/Emacs.iconset"
    mkdir -p "$iconsetdir"
    # Create required icon sizes (including @2x). Prefer ImageMagick (magick) if available, else sips.
    local sizes=(16 32 64 128 256 512)
    if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
        local IM_CMD
        if command -v magick >/dev/null 2>&1; then
            IM_CMD="magick"
        else
            IM_CMD="convert"
        fi
        for s in "${sizes[@]}"; do
            local sd=$((s * 2))
            # create normal size
            "$IM_CMD" "$input" -resize "${s}x${s}" "$iconsetdir/icon_${s}x${s}.png" >/dev/null 2>&1 || cp "$input" "$iconsetdir/icon_${s}x${s}.png"
            # create @2x
            "$IM_CMD" "$input" -resize "${sd}x${sd}" "$iconsetdir/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || cp "$input" "$iconsetdir/icon_${s}x${s}@2x.png"
        done
    else
        for s in "${sizes[@]}"; do
            sips -z "$s" "$s" "$input" --out "$iconsetdir/icon_${s}x${s}.png" >/dev/null 2>&1 || cp "$input" "$iconsetdir/icon_${s}x${s}.png"
            local sd=$((s * 2))
            sips -z "$sd" "$sd" "$input" --out "$iconsetdir/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || cp "$input" "$iconsetdir/icon_${s}x${s}@2x.png"
        done
    fi
    # iconutil to create icns
    iconutil -c icns "$iconsetdir" -o "$output_icns"
}
echo "Starting mac build helper"
echo "  Source dir: $SRC_DIR"
echo "  App dir:    $APP_DIR"
[[ -n "$ICON_PATH" ]] && echo "  Icon:       $ICON_PATH"
[[ -n "$ASSETS_PATH" ]] && echo "  Assets:     $ASSETS_PATH"
echo "  Jobs:       $JOBS"
[[ $NO_SIGN -eq 0 ]] && echo "  Codesign:   will sign with identity: $SIGN_IDENTITY" || echo "  Codesign:   skipped"
cd "$SRC_DIR"
# STEP 2: Bootstrap (autogen) and configure
if [[ -f autogen.sh ]]; then
    echocmd ./autogen.sh
else
    echocmd autoreconf -fvi
fi
# Prepare configure args
# Detect architecture and set appropriate flags
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    CFLAGS="-O2 -mcpu=native -march=native -mtune=native -fomit-frame-pointer -DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT"
else
    # For x86_64, -mcpu is not valid
    CFLAGS="-O2 -march=native -mtune=native -fomit-frame-pointer -DFD_SETSIZE=10000 -DDARWIN_UNLIMITED_SELECT"
fi
CONFIGURE_OPTS=(--with-modules --with-native-compilation=aot --with-tree-sitter --enable-mac-self-contained --with-xwidgets --without-dbus --with-mac-metal)
# Ensure we pass the app dir to enable-mac-app
CONFIGURE_OPTS+=("--enable-mac-app=$APP_DIR")
if [[ -n "$PREFIX" ]]; then
    CONFIGURE_OPTS+=("--prefix=$PREFIX")
fi
echo "Configuring Emacs (this may take a moment)"
echocmd env CFLAGS="$CFLAGS" ./configure "${CONFIGURE_OPTS[@]}"
# STEP 3: Build
echo "Running make (bootstrap, then make and make install)"
if echocmd make -j"$JOBS" bootstrap; then
    echo "Bootstrap succeeded"
else
    echo "Warning: bootstrap failed; continuing with normal build"
fi
echocmd make -j"$JOBS"
# Use make install to install into app dir / prefix as configured
if [[ -n "$PREFIX" ]]; then
    echo "Installing to prefix: $PREFIX"
    echocmd make install
else
    echo "Running 'make install' -- this will install the Mac App to $APP_DIR (if configured)."
    echocmd make install
fi
# STEP 4: Post-build packaging / wrapper
EMACS_APP="${APP_DIR}/Emacs.app"
if [[ ! -d "$EMACS_APP" ]]; then
    # Some builds may put Emacs.app under nextstep/Emacs.app or nextstep/ nextstep/Emacs.app
    if [[ -d "nextstep/Emacs.app" ]]; then
        echo "Moving nextstep/Emacs.app -> $APP_DIR"
        echocmd mkdir -p "${APP_DIR}"
        echocmd cp -a "nextstep/Emacs.app" "$APP_DIR/"
    else
        echo "Warning: Emacs.app not found at $EMACS_APP. Build may have failed or app path differs."
    fi
fi
if [[ -d "$EMACS_APP" ]]; then
    # STEP 5: Icon handling and Info.plist updates (use PlistBuddy commands found in repo)
    PLIST="$EMACS_APP/Contents/Info.plist"
    if [[ -n "$ICON_PATH" ]]; then
        RESOURCES_DIR="$EMACS_APP/Contents/Resources"
        echocmd mkdir -p "$RESOURCES_DIR"
        # If ICON_PATH is a URL, download it first
        tmp_download=""
        if [[ "$ICON_PATH" =~ ^https?:// ]]; then
            echo "Downloading icon from: $ICON_PATH"
            tmp_download=$(mktemp -t emacs_icon.XXXXXX)
            if command -v curl >/dev/null 2>&1; then
                echocmd curl -fsSL -o "$tmp_download" "$ICON_PATH"
            else
                echocmd wget -q -O "$tmp_download" "$ICON_PATH"
            fi
            ICON_SOURCE="$tmp_download"
        else
            ICON_SOURCE="$ICON_PATH"
        fi
        # If user provided a PNG/JPEG (or non-icns), convert to icns
        input_lower=$(echo "$ICON_SOURCE" | tr '[:upper:]' '[:lower:]')
        tmp_icns=""
        if [[ "$input_lower" == *.png || "$input_lower" == *.jpg || "$input_lower" == *.jpeg ]]; then
            echo "Converting image to ICNS"
            tmp_icns="$(mktemp).icns"
            convert_image_to_icns "$ICON_SOURCE" "$tmp_icns"
            ICON_TO_USE="$tmp_icns"
        else
            ICON_TO_USE="$ICON_SOURCE"
        fi
        echo "Applying icon: copying $ICON_TO_USE -> $RESOURCES_DIR/Emacs.icns"
        echocmd cp "$ICON_TO_USE" "$RESOURCES_DIR/Emacs.icns"
        # Clean up conflicting icon keys first
        echocmd /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c 'Delete :CFBundleIcons' "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFiles' "$PLIST" 2>/dev/null || true
        
        # Remove Assets.car unless user explicitly provided one
        if [[ -z "$ASSETS_PATH" ]]; then
            echocmd rm -f "$RESOURCES_DIR/Assets.car" || true
        else
            # User provided Assets.car - copy it and use CFBundleIconName
            echocmd cp "$ASSETS_PATH" "$RESOURCES_DIR/Assets.car"
            echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Emacs" "$PLIST"
            # When using Assets.car, CFBundleIconName is primary, skip other icon keys
            echo "Using Assets.car with CFBundleIconName"
        fi
        
        # Set icon keys - these work whether Assets.car exists or not
        # CFBundleIconFile points to the .icns file (without extension)
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Emacs" "$PLIST"
        
        # Modern CFBundleIcons dictionary structure (macOS 10.13+)
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string Emacs" "$PLIST" 2>/dev/null || true
        echocmd /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName string Emacs" "$PLIST" 2>/dev/null || true
        # Touch the app bundle to update modification time
        echocmd touch "$EMACS_APP"
        echocmd touch "$EMACS_APP/Contents"
        echocmd touch "$EMACS_APP/Contents/Info.plist"
        
        echo "Icon applied successfully to $RESOURCES_DIR/Emacs.icns"
        echo ""
        echo "To ensure the icon displays immediately, run these commands:"
        echo "  touch \"$EMACS_APP\""
        echo "  killall Finder"
        echo "  killall Dock"
        echo ""
        echo "Or register the app with LaunchServices:"
        LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if [[ -x "$LSREG" ]]; then
            echocmd "$LSREG" -f "$EMACS_APP"
            echo "  $LSREG -f \"$EMACS_APP\""
        fi
        echo ""
        echo "If the icon still doesn't appear, log out and back in."
        # Cleanup temporary files
        if [[ -n "${tmp_icns:-}" && -f "${tmp_icns:-}" ]]; then
            rm -f "${tmp_icns}" || true
        fi
        if [[ -n "${tmp_download:-}" && -f "${tmp_download:-}" ]]; then
            rm -f "${tmp_download}" || true
        fi
    fi
    # Optionally inject protected resources usage descriptions found in EmacsBase.rb
    # (Camera/Microphone/Speech). These can be useful for sandboxed builds.
    echo "Ensuring protected resources usage descriptions exist in Info.plist"
    /usr/libexec/PlistBuddy -c "Print NSCameraUsageDescription" "$PLIST" >/dev/null 2>&1 ||
        echocmd /usr/libexec/PlistBuddy -c "Add NSCameraUsageDescription string Emacs requires permission to access the Camera." "$PLIST"
    /usr/libexec/PlistBuddy -c "Print NSMicrophoneUsageDescription" "$PLIST" >/dev/null 2>&1 ||
        echocmd /usr/libexec/PlistBuddy -c "Add NSMicrophoneUsageDescription string Emacs requires permission to access the Microphone." "$PLIST"
    /usr/libexec/PlistBuddy -c "Print NSSpeechRecognitionUsageDescription" "$PLIST" >/dev/null 2>&1 ||
        echocmd /usr/libexec/PlistBuddy -c "Add NSSpeechRecognitionUsageDescription string Emacs requires permission to handle any speech recognition." "$PLIST"
    # Verify the bundle format and contents before signing
    echo "Verifying bundle format and contents"
    # Check if Contents/Resources directory contains necessary files
    RESOURCES_DIR="$EMACS_APP/Contents/Resources"
    if [[ ! -d "$RESOURCES_DIR" ]]; then
        echo "Error: Resources directory not found"
        exit 1
    fi
    
    if [[ ! -f "$RESOURCES_DIR/Emacs.icns" ]]; then
        echo "Warning: Resources directory is missing Emacs.icns (may use default icon)"
    else
        echo "Resources directory contains necessary files"
    fi
    
    # Check if Contents/MacOS directory contains necessary files
    MACOS_DIR="$EMACS_APP/Contents/MacOS"
    if [[ ! -d "$MACOS_DIR" ]]; then
        echo "Error: MacOS directory not found"
        exit 1
    fi
    
    if [[ ! -f "$MACOS_DIR/Emacs" ]]; then
        echo "Error: MacOS directory is missing Emacs executable"
        exit 1
    else
        echo "MacOS directory contains necessary files"
    fi
    
    # Check if Contents/Info.plist exists
    PLIST_FILE="$EMACS_APP/Contents/Info.plist"
    if [[ ! -f "$PLIST_FILE" ]]; then
        echo "Error: Info.plist file not found"
        exit 1
    else
        echo "Info.plist file exists"
    fi
    
    # Codesign (self-sign / ad-hoc by default) if requested
    if [[ $NO_SIGN -eq 0 ]]; then
        echo "Signing app: $EMACS_APP (identity: $SIGN_IDENTITY)"
        # Use the same simple re-sign approach used by the repo's post_install (ad-hoc by default)
        echocmd /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$EMACS_APP"
        
        if /usr/bin/codesign --verify --deep --strict --verbose=2 "$EMACS_APP"; then
            echo "Code signing verification successful"
        else
            echo "Warning: Code signing verification failed"
        fi
    else
        echo "Skipping codesign as requested"
    fi
    
    # Remove quarantine attribute so the built app can be launched locally without Gatekeeper prompts
    if command -v xattr >/dev/null 2>&1; then
        echocmd /usr/bin/xattr -dr com.apple.quarantine "$EMACS_APP" || true
    fi
else
    echo "Error: Emacs.app not found at $EMACS_APP"
    exit 1
fi
echo "mac build helper complete"
# End of file
