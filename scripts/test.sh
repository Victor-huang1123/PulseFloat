#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild build-for-testing -scheme PulseFloatCore -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet
xcrun xctest build/DerivedData/Build/Products/Debug/PulseFloatCoreTests.xctest
