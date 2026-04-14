#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST to user@host before running this script}"
REMOTE_DIR="${REMOTE_DIR:?Set REMOTE_DIR to the target repo path on the remote machine}"
SCHEME="${SCHEME:-Glacier}"
PROJECT="${PROJECT:-Glacier.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TEST_IDENTIFIER="${1:-GlacierUITests/GlacierUITests/testSplitCommandsSupportAutonomousAutomation}"
SAFE_TEST_NAME="${TEST_IDENTIFIER//\//_}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
LOCAL_ARTIFACT_DIR="${LOCAL_ARTIFACT_DIR:-$ROOT_DIR/remote-artifacts/$TIMESTAMP}"
REMOTE_ARTIFACT_DIR="$REMOTE_DIR/.remote-artifacts"
REMOTE_RESULT_BUNDLE="$REMOTE_ARTIFACT_DIR/${SAFE_TEST_NAME}.xcresult"

mkdir -p "$LOCAL_ARTIFACT_DIR"

echo "Syncing repo to $REMOTE_HOST:$REMOTE_DIR"
ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR' '$REMOTE_ARTIFACT_DIR'"

rsync -az --delete \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude 'DerivedData/' \
  --exclude 'default.profraw' \
  --exclude '.remote-artifacts/' \
  --exclude 'remote-artifacts/' \
  --exclude '*.xcresult/' \
  "$ROOT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"

echo "Running XCUITest on $REMOTE_HOST"
set +e
ssh "$REMOTE_HOST" "
  set -euo pipefail
  rm -rf '$REMOTE_RESULT_BUNDLE'
  cd '$REMOTE_DIR'
  xcodebuild \
    -scheme '$SCHEME' \
    -project '$PROJECT' \
    -configuration '$CONFIGURATION' \
    -resultBundlePath '$REMOTE_RESULT_BUNDLE' \
    '-only-testing:$TEST_IDENTIFIER' \
    test
"
test_status=$?
set -e

echo "Copying xcresult bundle back to $LOCAL_ARTIFACT_DIR"
if ssh "$REMOTE_HOST" "test -e '$REMOTE_RESULT_BUNDLE'"; then
  rsync -az "$REMOTE_HOST:$REMOTE_RESULT_BUNDLE" "$LOCAL_ARTIFACT_DIR/"
else
  echo "No xcresult bundle found at $REMOTE_RESULT_BUNDLE"
fi

echo
echo "Remote test completed."
echo "xcresult: $LOCAL_ARTIFACT_DIR/$(basename "$REMOTE_RESULT_BUNDLE")"

exit "$test_status"
