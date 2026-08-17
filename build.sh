#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="DaktRecorder.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Не найден swiftc. Установи инструменты разработчика: xcode-select --install"
    exit 1
fi

echo "Собираю для ${TARGET}…"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -target "$TARGET" \
    -framework SwiftUI -framework AVFoundation -framework ScreenCaptureKit -framework AppKit \
    -o "$APP/Contents/MacOS/DaktRecorder" \
    Sources/*.swift

# Иконка рисуется кодом, чтобы в репозитории не лежали бинарные ассеты.
if command -v iconutil >/dev/null 2>&1; then
    mkdir -p build
    swift Tools/MakeIcon.swift build/DaktRecorder.iconset >/dev/null
    iconutil -c icns build/DaktRecorder.iconset -o "$APP/Contents/Resources/DaktRecorder.icns"
    rm -rf build
else
    echo "iconutil недоступен — приложение соберётся без иконки."
fi

# Ad-hoc подпись: без неё macOS может забыть выданные разрешения после сборки.
codesign --force --sign - --identifier local.daktrecorder "$APP" >/dev/null

echo "Готово: $(pwd)/$APP"
echo "Запуск: open $APP"
