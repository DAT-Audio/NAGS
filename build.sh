#!/bin/bash
# Builds "Network Audio Grabber.app" and "Network Audio Sender.app" from the SwiftPM package. No
# Xcode required — Command Line Tools are enough. Every path is relative to this script, so the
# project can be moved or shared.
#
#   ./build.sh                  both apps, release
#   ./build.sh debug            both apps, debug
#   ./build.sh release sender   one of them: grabber | sender | au
#   ./build.sh release au install  the Audio Unit, copied into ~/Library/Audio/Plug-Ins/Components
#   ./build.sh release dmg      everything, then the disk image: build/NAGS-Mac-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Network Audio Local Signing}"
WHICH="${2:-all}"
INSTALL="${3:-}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"

# product  app-name  info-plist  icon-variant
assemble() {
  local PRODUCT="$1" APPNAME="$2" PLIST="$3" VARIANT="$4"
  local APP="build/$APPNAME.app"
  if [ ! -f "Resources/$PRODUCT.icns" ]; then
    echo "==> drawing $APPNAME icon"
    swift Tools/make_icon.swift Resources $VARIANT
  fi
  [ -x "$BINDIR/$PRODUCT" ] || { echo "Build product not found at $BINDIR/$PRODUCT"; exit 1; }

  echo "==> assembling $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BINDIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
  # No debug map: it lists every object file by the full path it was built at, which names the
  # folder the project lives in. Crash reports are unaffected.
  strip -S "$APP/Contents/MacOS/$PRODUCT"
  cp "Resources/$PLIST" "$APP/Contents/Info.plist"
  cp "Resources/$PRODUCT.icns" "$APP/Contents/Resources/$PRODUCT.icns"
  # Help → Quick Start Guide: the illustrated page, self-contained (pictures inside), from
  # `python3 Tools/guide-to-html.py`.
  cp "docs/quick-start/QUICK-START.html" "$APP/Contents/Resources/Quick Start.html"
  # Licences: the apps' own (MIT), and swift-crypto (Apache-2.0), for the Remote
  # link. Listed by About → Licences… (`LicenceFiles`).
  mkdir -p "$APP/Contents/Resources/Licences"
  cp "LICENSE" "$APP/Contents/Resources/Licences/LICENSE.txt"
  cp ".build/checkouts/swift-crypto/LICENSE.txt" "$APP/Contents/Resources/Licences/swift-crypto LICENSE.txt"
  [ -f ".build/checkouts/swift-crypto/NOTICE.txt" ] && cp ".build/checkouts/swift-crypto/NOTICE.txt" "$APP/Contents/Resources/Licences/swift-crypto NOTICE.txt"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # The Grabber carries the DAT Audio plug-ins, for Help → Install DAW Plug-ins:
  # already signed, in a place codesign accepts nested code, and one macOS does not scan for
  # Audio Units, so carrying them installs nothing.
  if [ "$PRODUCT" = "NetworkAudioGrabber" ]; then
    local CARRIED="build/Network Audio Grabber.component"
    if [ -d "$CARRIED" ]; then
      mkdir -p "$APP/Contents/Library/Audio/Plug-Ins/Components"
      ditto "$CARRIED" "$APP/Contents/Library/Audio/Plug-Ins/Components/Network Audio Grabber.component"
      cp "Sources/AudioUnitSDK/LICENSE.txt" "$APP/Contents/Resources/Licences/AudioUnitSDK LICENSE.txt"
    else
      echo "    (no plug-ins built yet: this Grabber will not offer to install them)"
    fi
  fi

  # Signed with a stable local identity when this Mac has one, otherwise ad-hoc. Either makes
  # the Local Network and audio-recording prompts name this app rather than the terminal. The
  # difference: macOS ties the audio-recording permission to the signature, and an ad-hoc one
  # changes with every build, so each rebuild silently lost the Sender's permission.
  # A self-signed certificate named "$SIGN_IDENTITY" keeps it across rebuilds; see README →
  # "A stable signature for development". Override with SIGN_IDENTITY=- for ad-hoc.
  sign "$APP"
  echo "Built: $APP"
}

sign() {
  if [ "$SIGN_IDENTITY" != "-" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    echo "==> codesign ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$1" >/dev/null
  else
    echo "==> codesign (ad-hoc)"
    codesign --force --sign - --timestamp=none "$1" >/dev/null
  fi
}

# The Grabber as an Audio Unit: the same core as the app, in a .component bundle
# with two components — an instrument and an effect. See Sources/NetworkAudioGrabberAU.
assemble_au() {
  local AU="build/Network Audio Grabber.component"
  local LIB="$BINDIR/libNetworkAudioGrabberAU.dylib"
  [ -f "$LIB" ] || { echo "Build product not found at $LIB"; exit 1; }
  echo "==> assembling $AU"
  rm -rf "$AU"
  mkdir -p "$AU/Contents/MacOS" "$AU/Contents/Resources"
  cp "$LIB" "$AU/Contents/MacOS/NetworkAudioGrabberAU"
  install_name_tool -id "@loader_path/NetworkAudioGrabberAU" "$AU/Contents/MacOS/NetworkAudioGrabberAU"
  strip -S "$AU/Contents/MacOS/NetworkAudioGrabberAU"      # as the apps: no debug map, no paths
  cp "Resources/AU-Info.plist" "$AU/Contents/Info.plist"
  [ -f "Resources/NetworkAudioGrabber.icns" ] && cp "Resources/NetworkAudioGrabber.icns" "$AU/Contents/Resources/"
  # Its own icon in Finder (the Grabber's with a plug badge): Tools/make_plugin_icon.swift.
  [ -f "Resources/DATAudioPlugins.icns" ] || swift Tools/make_plugin_icon.swift Resources
  cp "Resources/DATAudioPlugins.icns" "$AU/Contents/Resources/"
  # Licences of what is built in: Apple's AudioUnitSDK and swift-crypto (both Apache-2.0).
  mkdir -p "$AU/Contents/Resources/Licences"
  cp "LICENSE" "$AU/Contents/Resources/Licences/LICENSE.txt"
  cp "Sources/AudioUnitSDK/LICENSE.txt" "$AU/Contents/Resources/Licences/AudioUnitSDK LICENSE.txt"
  cp ".build/checkouts/swift-crypto/LICENSE.txt" "$AU/Contents/Resources/Licences/swift-crypto LICENSE.txt"
  [ -f ".build/checkouts/swift-crypto/NOTICE.txt" ] && cp ".build/checkouts/swift-crypto/NOTICE.txt" "$AU/Contents/Resources/Licences/swift-crypto NOTICE.txt"
  printf 'BNDL????' > "$AU/Contents/PkgInfo"
  sign "$AU"
  echo "Built: $AU"
  if [ "$INSTALL" = "install" ]; then
    local DEST="$HOME/Library/Audio/Plug-Ins/Components"
    mkdir -p "$DEST"
    rm -rf "$DEST/Network Audio Grabber.component"
    cp -R "$AU" "$DEST/"
    echo "Installed: $DEST/Network Audio Grabber.component"
  fi
}

# The disk image: the two apps beside an Applications shortcut, the plug-ins (beta)
# beside a shortcut to the all-users Components folder, and the Read Me, over a drawn
# background. Laid out by dmgbuild (MIT; a build tool only, fetched once into .build/dmg-venv).
make_dmg() {
  local VERSION
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  local STAGE="build/dmg-staging" OUT="build/NAGS-Mac-$VERSION.dmg"
  echo "==> disk image $OUT"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  if [ ! -x .build/dmg-venv/bin/dmgbuild ]; then
    echo "    (fetching dmgbuild, once)"
    python3 -m venv .build/dmg-venv
    .build/dmg-venv/bin/pip install -q dmgbuild
  fi
  # The background: light. DMG_STYLE=dark for the graphite one.
  swift Tools/make_dmg_background.swift "$VERSION" "$STAGE" $([ "${DMG_STYLE:-}" = dark ] && echo --dark) >/dev/null
  tiffutil -cathidpicheck "$STAGE/background.png" "$STAGE/background@2x.png" -out "$STAGE/background.tiff" >/dev/null 2>&1
  cp "Resources/NetworkAudioGrabber.icns" "$STAGE/volume.icns"
  cp "Resources/dmg/Read Me.html" "$STAGE/Read Me.html"
  # The plug-ins under the DAWs' name for them, so they cannot be taken for the Grabber app beside
  # them; the installer recognises them by bundle identifier, whatever the file is called.
  ditto --noextattr --noqtn "build/Network Audio Grabber.component" "$STAGE/DAT Audio Plug-ins.component"
  # Clean copies of the apps too: no sync-service or download attributes in the image.
  ditto --noextattr --noqtn "build/Network Audio Grabber.app" "$STAGE/Network Audio Grabber.app"
  ditto --noextattr --noqtn "build/Network Audio Sender.app" "$STAGE/Network Audio Sender.app"
  rm -f "$OUT"
  .build/dmg-venv/bin/dmgbuild -s Tools/dmg_settings.py -D build="build" -D staging="$STAGE" \
    "Network Audio Grabber $VERSION" "$OUT" >/dev/null
  echo "Built: $OUT"
}

# The plug-ins first: the Grabber carries them.
if [ "$WHICH" = "all" ] || [ "$WHICH" = "au" ] || [ "$WHICH" = "dmg" ]; then
  assemble_au
fi
if [ "$WHICH" = "all" ] || [ "$WHICH" = "grabber" ] || [ "$WHICH" = "dmg" ]; then
  assemble NetworkAudioGrabber "Network Audio Grabber" Info.plist ""
fi
if [ "$WHICH" = "all" ] || [ "$WHICH" = "sender" ] || [ "$WHICH" = "dmg" ]; then
  assemble NetworkAudioSender "Network Audio Sender" Sender-Info.plist sender
fi
if [ "$WHICH" = "dmg" ]; then
  make_dmg
fi
