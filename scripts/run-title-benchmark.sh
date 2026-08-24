#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
derived_data="/private/tmp/meetingbar-title-benchmark"
test_bundle="${derived_data}/Build/Products/Debug/MeetingBar.app/Contents/PlugIns/MeetingBarTests.xctest"

xcodebuild build-for-testing -quiet \
  -project "${project_directory}/MeetingBar.xcodeproj" \
  -scheme MeetingBar \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${derived_data}" \
  -disableAutomaticPackageResolution

mkdir -p "${test_bundle}/Contents/Frameworks"
ditto \
  "${derived_data}/Build/Products/Debug/MeetingBar.app/Contents/MacOS/MeetingBar.debug.dylib" \
  "${test_bundle}/Contents/Frameworks/MeetingBar.debug.dylib"

MEETINGBAR_RUN_TITLE_TESTS=1 \
xcrun xctest \
  -XCTest MeetingBarTests.RealModelIntegrationTests/testSystemModelGeneratesGroundedSwedishAndEnglishTitles \
  "${test_bundle}"
