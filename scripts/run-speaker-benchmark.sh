#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "Usage: $0 <speaker-model-download-base> [audio-file]"
  exit 2
fi

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
download_base="$1"
audio_path="${2:-${project_directory}/EvaluationFixtures/AMI/audio/ES2005a-diarization.wav}"
derived_data="/private/tmp/meetingbar-speaker-benchmark"
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

MEETINGBAR_RUN_SPEAKER_TESTS=1 \
MEETINGBAR_SPEAKER_AUDIO_PATH="${audio_path}" \
MEETINGBAR_SPEAKER_DOWNLOAD_BASE="${download_base}" \
xcrun xctest \
  -XCTest MeetingBarTests.RealModelIntegrationTests/testPublicAMIFixtureDetectsMultipleSpeakers \
  "${test_bundle}"
