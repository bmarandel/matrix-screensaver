#!/bin/zsh
# Compile Matrix.saver (universel x86_64 + arm64) ; --install le copie dans ~/Library/Screen Savers
set -euo pipefail
cd "${0:A:h}"
B=build/Matrix.saver
rm -rf build && mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
for arch in x86_64 arm64; do
  swiftc -O -parse-as-library -module-name Matrix -target $arch-apple-macos12 \
    -emit-library -o build/Matrix-$arch Sources/*.swift \
    -framework ScreenSaver -framework AppKit -framework CoreText -framework Metal -framework QuartzCore
done
lipo -create build/Matrix-x86_64 build/Matrix-arm64 -output "$B/Contents/MacOS/Matrix"
cp Info.plist "$B/Contents/"
cp Resources/* "$B/Contents/Resources/"
xattr -cr "$B"
codesign --force --deep --sign - "$B"
(cd build && ditto -c -k --keepParent Matrix.saver Matrix.saver.zip)
echo "OK → $B (+ build/Matrix.saver.zip)"
if [[ ${1:-} == --install ]]; then
  mkdir -p ~/Library/"Screen Savers"
  rm -rf ~/Library/"Screen Savers"/Matrix.saver
  cp -R "$B" ~/Library/"Screen Savers"/
  killall legacyScreenSaver 2>/dev/null || true
  echo "Installé → ~/Library/Screen Savers/Matrix.saver"
fi
