#!/usr/bin/env bash
# Post (or refresh) the one before/after evidence comment easy-approve leaves on a PR.
#
#   post_evidence.sh <owner/repo> <pr> <before.png> <after.png> \
#       --caption "<what to look at>" --evidence "<one line of evidence>" \
#       [--base <sha>] [--device "<where it was captured>"] [--dry-run]
#
# Uploads both images to GitHub's user-attachments endpoint with the `gh` user token (same CDN
# the web UI's drag-drop uses; assets inherit the repo's visibility and never enter a commit),
# builds the comment body, and then either PATCHes the existing easy-approve comment on that
# PR or POSTs a new one. The hidden marker is what makes a re-run update instead of duplicate.
#
# --dry-run prints the body it would post and exits without uploading or commenting.
#
# Upload recipe from the visual-evidence skill (HumandDev/hu-ai-agent-plugin,
# plugins/humand-tech/skills/visual-evidence). 422 = content type / extension mismatch;
# 404 = bad repository id or no push access to the repo.
set -euo pipefail

MARKER='<!-- easy-approve:evidence -->'

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -ge 4 ] || usage
REPO=$1; PR=$2; BEFORE=$3; AFTER=$4; shift 4

CAPTION=""; EVIDENCE=""; BASE=""; DEVICE=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --caption)  CAPTION=$2; shift 2 ;;
    --evidence) EVIDENCE=$2; shift 2 ;;
    --base)     BASE=$2; shift 2 ;;
    --device)   DEVICE=$2; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ "$REPO" == */* ]] || { echo "repo must be owner/name, got '$REPO'" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "pr must be a number, got '$PR'" >&2; exit 2; }
[ -n "$CAPTION" ] || { echo "--caption is required: say what region to look at" >&2; exit 2; }
[ -n "$EVIDENCE" ] || { echo "--evidence is required: one line on what the pair proves" >&2; exit 2; }
for f in "$BEFORE" "$AFTER"; do
  [ -f "$f" ] || { echo "missing image: $f" >&2; exit 2; }
  [[ "$f" == *.png ]] || { echo "images must be .png (the endpoint matches extension to mime): $f" >&2; exit 2; }
done

upload_asset() {  # <file>  -> prints the asset URL
  local file=$1 name response url
  name=$(basename "$file")
  response=$(curl -sS -X POST \
    "https://uploads.github.com/user-attachments/assets?name=${name}&content_type=image/png&repository_id=${REPO_ID}" \
    -H "Authorization: Bearer $(gh auth token)" -H "Accept: application/json" \
    --data-binary @"$file")
  url=$(printf '%s' "$response" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
  [ -n "$url" ] || { echo "upload failed for $file: $response" >&2; exit 1; }
  printf '%s' "$url"
}

if [ "$DRY_RUN" -eq 1 ]; then
  BEFORE_URL="file://$(cd "$(dirname "$BEFORE")" && pwd)/$(basename "$BEFORE")"
  AFTER_URL="file://$(cd "$(dirname "$AFTER")" && pwd)/$(basename "$AFTER")"
else
  REPO_ID=$(gh api "repos/$REPO" --jq .id)
  BEFORE_URL=$(upload_asset "$BEFORE")
  AFTER_URL=$(upload_asset "$AFTER")
fi

BEFORE_LABEL="Before"; [ -n "$BASE" ] && BEFORE_LABEL="Before (base \`${BASE}\`)"
FOOTER="Evidence only, not an approval — posted by the easy-approve skill."
[ -n "$DEVICE" ] && FOOTER="Captured on ${DEVICE}. ${FOOTER}"

BODY_FILE=$(mktemp -t easy-approve-evidence.XXXXXX)
trap 'rm -f "$BODY_FILE"' EXIT
cat > "$BODY_FILE" <<EOF
${MARKER}
**easy-approve — before/after**

| ${BEFORE_LABEL} | After (this PR) |
| --- | --- |
| ![Before](${BEFORE_URL}) | ![After](${AFTER_URL}) |

**What to look at:** ${CAPTION}

**Evidence:** ${EVIDENCE}

<sub>${FOOTER}</sub>
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- dry run: would post to $REPO#$PR ---"
  cat "$BODY_FILE"
  exit 0
fi

# awk reads to EOF: `head -n1` would close the pipe early and, under pipefail, turn a paginated
# comment list into a spurious non-zero exit.
EXISTING=$(gh api "repos/$REPO/issues/$PR/comments" --paginate \
  --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" | awk 'NR==1')

if [ -n "$EXISTING" ]; then
  gh api -X PATCH "repos/$REPO/issues/comments/$EXISTING" -F "body=@$BODY_FILE" --jq .html_url
else
  gh api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$BODY_FILE" --jq .html_url
fi
