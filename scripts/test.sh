#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/tests work/module-cache
python3 Tests/Fixtures.py
python3 -c 'import plistlib,pathlib; r=pathlib.Path.cwd(); (r/"work/tests/Info.plist").write_bytes(plistlib.dumps({"LocalDataDirectory":str(r/"work/tests/state")}))'
xcrun swiftc -parse-as-library -swift-version 5 -D WRITEBACK_TESTING -module-cache-path "$PWD/work/module-cache" \
  Sources/Shared/Schedule.swift Sources/App/XLSXReader.swift Sources/App/XLSXCompletionWriter.swift Sources/App/CompletionStrikeStore.swift Sources/App/ExcelLiveWriter.swift Tests/ScheduleTests.swift Tests/WritebackTests.swift Tests/LiveWritebackTests.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/work/tests/Info.plist" \
  -o work/tests/schedule-tests
work/tests/schedule-tests "$PWD"
