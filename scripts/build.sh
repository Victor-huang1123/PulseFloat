#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild build -scheme PulseFloat -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet
