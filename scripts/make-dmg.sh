#!/bin/bash
# Package DeyeWidget.app into a distributable DMG. Run make-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.2.0}"
APP="DeyeWidget.app"
DMG="DeyeWidget-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/make-app.sh first" >&2
    exit 1
fi

echo "==> staging"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname DeyeWidget -srcfolder "$STAGE" -ov -format UDZO "$DMG" | sed 's/^/    /'

echo "==> done: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
