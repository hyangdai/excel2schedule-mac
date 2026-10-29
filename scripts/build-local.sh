#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/outputs/今日事项.app"
EXT="$APP/Contents/PlugIns/TodayScheduleWidget.appex"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS" "$ROOT/work/module-cache" "$ROOT/.local-data"
python3 scripts/configure.py local "$ROOT"
COMMON=(-sdk "$SDK" -target "${ARCH}-apple-macos14.0" -swift-version 5 -D LOCAL_DEVELOPMENT -module-cache-path "$ROOT/work/module-cache" -parse-as-library -O)
xcrun swiftc "${COMMON[@]}" -module-name TodaySchedule Sources/Shared/*.swift Sources/App/*.swift -o "$APP/Contents/MacOS/TodaySchedule"
xcrun swiftc "${COMMON[@]}" -application-extension -module-name TodayScheduleWidget Sources/Shared/*.swift Sources/Widget/*.swift -o "$EXT/Contents/MacOS/TodayScheduleWidget"
codesign --force --sign - --entitlements "$ROOT/work/Widget.local.entitlements" "$EXT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '已生成：%s\n' "$APP"
printf '这是本机临时签名版本；系统是否接受桌面扩展需实际验证。\n'
