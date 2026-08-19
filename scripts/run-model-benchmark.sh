#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "Usage: $0 <model-identifier> <model-folder> [manifest]"
  exit 2
fi

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
model_identifier="$1"
model_folder="$2"
manifest_path="${3:-${project_directory}/EvaluationFixtures/FLEURS/manifest.json}"
derived_data="/private/tmp/meetingbar-model-benchmark"
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

MEETINGBAR_RUN_MODEL_TESTS=1 \
MEETINGBAR_MODEL_IDENTIFIER="${model_identifier}" \
MEETINGBAR_MODEL_PATH="${model_folder}" \
MEETINGBAR_EVALUATION_MANIFEST="${manifest_path}" \
xcrun xctest \
  -XCTest MeetingBarTests.RealModelIntegrationTests/testPublicSwedishAndEnglishFixturesStayWithinMeasuredWER \
  "${test_bundle}"
