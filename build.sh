#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="MeetingRecorder.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Не найден swiftc. Установи инструменты разработчика: xcode-select --install"
    exit 1
fi

echo "Собираю для ${TARGET}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -target "$TARGET" \
    -framework SwiftUI -framework AVFoundation -framework ScreenCaptureKit -framework AppKit \
    -o "$APP/Contents/MacOS/MeetingRecorder" \
    Sources/*.swift

# Ad-hoc подпись нужна, чтобы macOS помнил выданные разрешения между запусками.
codesign --force --sign - --identifier local.meetingrecorder "$APP" >/dev/null

echo "Готово: $(pwd)/$APP"
echo "Запуск: open $APP"
