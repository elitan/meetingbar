#!/bin/zsh
set -euo pipefail

if (( $# < 3 || $# > 4 )); then
  print -u2 "Usage: $0 <model-identifier> <model-folder> <models-root> [audio-file]"
  exit 2
fi

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
model_identifier="$1"
model_folder="$2"
models_root="$3"
audio_path="${4:-${project_directory}/EvaluationFixtures/AMI/audio/ES2005a-diarization.wav}"
derived_data="/private/tmp/meetingbar-pipeline-benchmark"
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

MEETINGBAR_RUN_PIPELINE_TESTS=1 \
MEETINGBAR_MODEL_IDENTIFIER="${model_identifier}" \
MEETINGBAR_MODEL_PATH="${model_folder}" \
MEETINGBAR_PIPELINE_MODELS_ROOT="${models_root}" \
MEETINGBAR_PIPELINE_AUDIO_PATH="${audio_path}" \
xcrun xctest \
  -XCTest MeetingBarTests.RealModelIntegrationTests/testPublicAMIFixtureProducesSpeakerPrefixedTranscriptEndToEnd \
  "${test_bundle}"
