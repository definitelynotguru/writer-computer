#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
RELEASE_REPO="definitelynotguru/writer-computer"

NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file)
      NOTES_FILE="$2"
      shift 2
      ;;
    --notes-file=*)
      NOTES_FILE="${1#*=}"
      shift
      ;;
    *)
      echo "Error: unknown argument: $1"
      echo "Usage: $0 --notes-file <path>"
      exit 1
      ;;
  esac
done

if [ -z "$NOTES_FILE" ]; then
  echo "Error: --notes-file <path> is required"
  echo "Pass a markdown file with the user-facing release notes (drafted by the agent from CHANGELOG.md)."
  exit 1
fi
if [ ! -s "$NOTES_FILE" ]; then
  echo "Error: notes file is missing or empty: $NOTES_FILE"
  exit 1
fi

# Load signing environment; the updater keypair lives OUTSIDE the repo
# (see docs/releasing.md#linux-builds).
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found at $ENV_FILE"
  echo ""
  echo "Create it with:"
  echo "  TAURI_SIGNING_PRIVATE_KEY=\"\"  # contents of tauri-signing.key"
  echo "  TAURI_SIGNING_PRIVATE_KEY_PASSWORD=\"\""
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  echo "Error: TAURI_SIGNING_PRIVATE_KEY is not set in .env"
  exit 1
fi
# Empty-password keys are fine but tauri-cli checks the env var is present.
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"

# Arch-family quirks when bundling AppImages: linuxdeploy ships a 2024-era
# binutils strip that cannot read `.relr.dyn` sections in modern Arch libs
# (strip calls fail and the run aborts), and its AppImage runtime needs FUSE2
# unless extracted. Both workarounds are no-ops on other distros.
export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1

# Read version from tauri.conf.json
TAURI_CONF="$ROOT_DIR/apps/desktop/src-tauri/tauri.conf.json"
VERSION=$(python3 -c "import json; print(json.load(open('$TAURI_CONF'))['version'])")
TAG="v$VERSION"

# Pre-flight: must be on master, clean, in sync with origin, and the tag must
# not already exist anywhere. Cheap checks — fail before the long build.
CURRENT_BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "master" ]; then
  echo "Error: releases must be cut from master, currently on '$CURRENT_BRANCH'"
  exit 1
fi

if ! git -C "$ROOT_DIR" diff-index --quiet HEAD --; then
  echo "Error: working tree has uncommitted changes — commit the version bump first"
  git -C "$ROOT_DIR" status --short
  exit 1
fi

echo "Fetching origin to verify sync..."
git -C "$ROOT_DIR" fetch origin master --tags

LOCAL_REV=$(git -C "$ROOT_DIR" rev-parse HEAD)
REMOTE_REV=$(git -C "$ROOT_DIR" rev-parse origin/master)
BASE_REV=$(git -C "$ROOT_DIR" merge-base HEAD origin/master)
if [ "$LOCAL_REV" != "$REMOTE_REV" ] && [ "$BASE_REV" != "$REMOTE_REV" ]; then
  echo "Error: local master is not a fast-forward of origin/master"
  echo "  local:  $LOCAL_REV"
  echo "  origin: $REMOTE_REV"
  echo "  Pull or rebase before releasing."
  exit 1
fi

if git -C "$ROOT_DIR" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  echo "Error: tag $TAG already exists locally — bump the version or delete the tag"
  exit 1
fi
if git -C "$ROOT_DIR" ls-remote --tags --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists on origin — bump the version"
  exit 1
fi

echo "Pushing master to origin..."
git -C "$ROOT_DIR" push origin master

echo "Building Writer $TAG..."

# Build the signable AppImage + updater signature.
cd "$ROOT_DIR/apps/desktop"
vp exec tauri build --bundles appimage

BUNDLE_DIR="$ROOT_DIR/apps/desktop/src-tauri/target/release/bundle"
APPIMAGE_DIR="$BUNDLE_DIR/appimage"

APPIMAGE_FILE=$(ls "$APPIMAGE_DIR"/*.AppImage 2>/dev/null | head -1 || true)
SIG_FILE=$(ls "$APPIMAGE_DIR"/*.AppImage.sig 2>/dev/null | head -1 || true)

if [ -z "$APPIMAGE_FILE" ] || [ -z "$SIG_FILE" ]; then
  echo "Error: AppImage or its signature missing in $APPIMAGE_DIR"
  echo "  Check that \`createUpdaterArtifacts\` is true and TAURI_SIGNING_PRIVATE_KEY is set."
  exit 1
fi

echo ""
echo "Built: $(basename "$APPIMAGE_FILE") ($(du -h "$APPIMAGE_FILE" | cut -f1))"

# Latest.json for the v2 updater: platform key linux-x86_64 regardless of host
# arch (Tauri AppImages bundle two arches under one key).
SIGNATURE=$(cat "$SIG_FILE")
TARGET="linux-x86_64"
APPIMAGE_NAME=$(basename "$APPIMAGE_FILE")
PUB_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOTES="Writer $TAG"
DOWNLOAD_URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$APPIMAGE_NAME"

LATEST_JSON="$BUNDLE_DIR/latest.json"
python3 - "$LATEST_JSON" "$VERSION" "$NOTES" "$PUB_DATE" "$TARGET" "$SIGNATURE" "$DOWNLOAD_URL" <<'PY'
import json, sys
out_path, version, notes, pub_date, target, signature, url = sys.argv[1:]
payload = {
    "version": version,
    "notes": notes,
    "pub_date": pub_date,
    "platforms": {
        target: {
            "signature": signature,
            "url": url,
        }
    },
}
with open(out_path, "w") as f:
    json.dump(payload, f, indent=2)
PY

echo "Built: latest.json ($TARGET)"

# Create a DRAFT GitHub Release with the AppImage, its signature, and the
# signed update manifest, plus the agent-drafted user-facing notes.
echo ""
echo "Creating draft release $TAG on $RELEASE_REPO..."

gh release create "$TAG" "$APPIMAGE_FILE" "$SIG_FILE" "$LATEST_JSON" \
  --repo "$RELEASE_REPO" \
  --title "Writer $TAG" \
  --notes-file "$NOTES_FILE" \
  --draft

DRAFT_URL=$(gh release view "$TAG" --repo "$RELEASE_REPO" --json url --jq '.url')

# Tag this repo so the release artifact is pinned to a specific commit. If you
# end up abandoning the draft, delete the tag manually.
echo ""
echo "Tagging $TAG locally and pushing to origin..."
git -C "$ROOT_DIR" tag "$TAG"
git -C "$ROOT_DIR" push origin "$TAG"

echo ""
echo "Draft created: $DRAFT_URL"
echo "Review the notes and click Publish to ship it."