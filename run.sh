#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP="$PWD/build/Typeless Alt.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TypelessAlt "$APP/Contents/MacOS/TypelessAlt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $APP"
else
  # Direct launch preserves OPENAI_API_KEY from this shell.
  exec "$APP/Contents/MacOS/TypelessAlt"
fi
