#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/tests work/module-cache
python3 Tests/Fixtures.py
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/work/module-cache" \
  Sources/Shared/Schedule.swift Sources/App/XLSXReader.swift Sources/App/XLSXCompletionWriter.swift \
  Sources/App/CompletionStrikeStore.swift Sources/App/ExcelLiveWriter.swift Tests/NativeLiveIntegration.swift \
  -o work/native-live-test
work/native-live-test "$PWD"
