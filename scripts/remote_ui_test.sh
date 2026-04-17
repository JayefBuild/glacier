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

mkdir -p "$LOCAL_ARTIFACT_DIR/screenshots"

echo "Syncing repo to $REMOTE_HOST:$REMOTE_DIR"
ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR' '$REMOTE_ARTIFACT_DIR'"

# Sync .git/ so UI tests can exercise git-aware views (e.g. Git Graph).
rsync -az --delete \
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
  ln -sfn "$LOCAL_ARTIFACT_DIR" "$ROOT_DIR/remote-artifacts/latest"
else
  echo "No xcresult bundle found at $REMOTE_RESULT_BUNDLE"
fi

XCRESULT_LOCAL="$LOCAL_ARTIFACT_DIR/$(basename "$REMOTE_RESULT_BUNDLE")"
SCREENSHOT_DIR="$LOCAL_ARTIFACT_DIR/screenshots"

if [ -e "$XCRESULT_LOCAL" ]; then
  echo "Extracting screenshots from xcresult to $SCREENSHOT_DIR"
  # Walk every test node and pull its attachments via the new test-results API.
  test_ids=$(xcrun xcresulttool get test-results tests --path "$XCRESULT_LOCAL" 2>/dev/null \
    | jq -r '[.. | objects | select(.nodeType? == "Test Case") | .nodeIdentifier] | .[]')
  idx=0
  for tid in $test_ids; do
    activities_json=$(xcrun xcresulttool get test-results activities \
      --path "$XCRESULT_LOCAL" --test-id "$tid" 2>/dev/null)
    echo "$activities_json" \
      | jq -r '[.. | objects | .attachments? // empty | .[] | "\(.payloadId)\t\(.name)"] | .[]' \
      | while IFS=$'\t' read -r payload name; do
          [ -z "$payload" ] && continue
          idx=$((idx+1))
          safe_name="${name//[^a-zA-Z0-9_-]/_}"
          out="$SCREENSHOT_DIR/$(printf '%03d' "$idx")_${safe_name}"
          xcrun xcresulttool export object --legacy \
            --path "$XCRESULT_LOCAL" \
            --id "$payload" \
            --type file \
            --output-path "$out" 2>/dev/null && echo "  Saved: $out"
        done
  done
fi

echo
echo "Remote test completed."
echo "xcresult: $XCRESULT_LOCAL"
echo "screenshots: $SCREENSHOT_DIR"

exit "$test_status"
