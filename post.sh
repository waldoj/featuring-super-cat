#!/usr/bin/env bash

set -euo pipefail

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="https://mastodon.social"

# Your Mastodon account's access token
MASTODON_TOKEN="ABCDefgh123456789x0x0x0x0x0x0x0x0x0x0x0"

# Your Bluesky handle
BLUESKY_HANDLE="{{BLUESKY_HANDLE}}"

# Your Bluesky app password
BLUESKY_APP_PASSWORD="{{BLUESKY_APP_PASSWORD}}"

# The S3 bucket where your video clips are stored, as a bare bucket name and
# path, with a trailing slash — not a hostname
S3_BUCKET="s3://videobucket/directory/"

# The clips are square, per the 750x750 cover art that supercat.sh renders
VIDEO_WIDTH=750
VIDEO_HEIGHT=750

# How many times to look for an unused clip before giving up
MAX_SELECTION_ATTEMPTS=100

# How long to wait for a server to finish processing an upload
MEDIA_POLL_ATTEMPTS=60
MEDIA_POLL_DELAY=5

# The clip currently being worked on; set by select_clip, removed on exit
ENTRY=""

# Remove the downloaded clip however this script exits
function cleanup {
    if [ -n "$ENTRY" ]; then
        rm -f "$ENTRY"
    fi
}

trap cleanup EXIT

# Define a failure function
function exit_error {
    printf '%s\n' "$1" >&2
    exit "${2-1}"
}

# Copy the video clip over from S3
function get_video {
    aws s3 cp "${S3_BUCKET}${ENTRY}" "$ENTRY" || return 1
    return 0
}

# Add the clip to the history of filenames
function add_to_history {
    echo "$ENTRY" >> history.txt
    return 0
}

# Store the total number of clips
function get_clip_count {
    wc -l < files.txt | tr -d ' '
    return 0
}

# Print one random line from the named file. `shuf` isn't part of a stock macOS
# install, so fall back to Homebrew's `gshuf` and then to awk.
function random_line {
    if command -v shuf > /dev/null; then
        shuf -n 1 "$1"
    elif command -v gshuf > /dev/null; then
        gshuf -n 1 "$1"
    else
        # Seed explicitly: a bare srand() seeds from the clock at one-second
        # granularity, so repeated calls would keep returning the same line
        awk -v seed="${RANDOM}${RANDOM}" \
            'BEGIN { srand(seed) } { if (rand() * NR < 1) line = $0 } END { print line }' "$1"
    fi
}

# Update the file listing 5% of the time, or generate it if it doesn't exist
function update_file_list {
    if [ ! -f ./files.txt ] || [ $(( RANDOM % 20 + 1 )) -eq 1 ]; then

        # `aws s3 ls` prints "date time size key". The key is everything from
        # the fourth field on, since these filenames contain spaces.
        if ! aws s3 ls "$S3_BUCKET" \
            | awk '{ $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' \
            | grep -E '\.mp4$' > files.txt.tmp; then
            rm -f files.txt.tmp
            exit_error "Could not update file listing"
        fi

        if [ ! -s files.txt.tmp ]; then
            rm -f files.txt.tmp
            exit_error "File listing came back empty"
        fi

        mv files.txt.tmp files.txt
    fi
    return 0
}

# Select a clip, making sure that it hasn't been used recently
function select_clip {
    local attempts=0

    # Consider a clip recently used if it appears in the most recent half of
    # the history, so that the full catalog cycles before anything repeats
    local clip_history=$(( CLIP_COUNT / 2 ))

    while [ "$attempts" -lt "$MAX_SELECTION_ATTEMPTS" ]; do
        attempts=$(( attempts + 1 ))

        # Select a random filename from the list
        ENTRY=$(random_line files.txt)

        # Remove any trailing carriage return from the filename
        ENTRY=$(printf '%s' "$ENTRY" | tr -d '\r')

        # Ensure that the filename is a plausible length
        if [ ${#ENTRY} -lt 5 ]; then
            exit_error "Filename is too short"
        fi

        # With no history yet, anything goes
        if [ ! -f history.txt ] || [ "$clip_history" -eq 0 ]; then
            return 0
        fi

        # Compare as fixed whole lines: these filenames contain regex
        # metacharacters, like "(Feat. Super Cat)"
        if ! tail -n "$clip_history" history.txt | grep -Fxq "$ENTRY"; then
            return 0
        fi
    done

    ENTRY=""
    exit_error "Could not find an unused clip in $MAX_SELECTION_ATTEMPTS attempts"
}

# Wait for Mastodon to finish processing an uploaded video. A 206 means it is
# still working; 200 means the media is ready to attach to a status.
function await_mastodon_media {
    local media_id="$1"
    local attempt=0
    local status

    while [ "$attempt" -lt "$MEDIA_POLL_ATTEMPTS" ]; do
        attempt=$(( attempt + 1 ))

        status=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer ${MASTODON_TOKEN}" \
            "${MASTODON_SERVER}/api/v1/media/${media_id}") || return 1

        if [ "$status" = "200" ]; then
            return 0
        fi

        if [ "$status" != "206" ]; then
            return 1
        fi

        sleep "$MEDIA_POLL_DELAY"
    done

    return 1
}

# Wait for Bluesky to finish transcoding an uploaded video, echoing the blob
# JSON once the job reports success
function await_bluesky_video {
    local job_id="$1"
    local attempt=0
    local job_json state

    while [ "$attempt" -lt "$MEDIA_POLL_ATTEMPTS" ]; do
        attempt=$(( attempt + 1 ))

        job_json=$(curl -s -f \
            "https://video.bsky.app/xrpc/app.bsky.video.getJobStatus?jobId=${job_id}") || return 1

        state=$(printf '%s' "$job_json" | jq -r '.jobStatus.state // empty')

        if [ "$state" = "JOB_STATE_COMPLETED" ]; then
            printf '%s' "$job_json" | jq -c '.jobStatus.blob'
            return 0
        fi

        if [ "$state" = "JOB_STATE_FAILED" ]; then
            return 1
        fi

        sleep "$MEDIA_POLL_DELAY"
    done

    return 1
}

# Get the name of the working directory
cd "$(dirname "$0")" || exit

# Make sure the tools this script depends on are actually present
for command in aws curl ffprobe jq; do
    if ! command -v "$command" > /dev/null; then
        exit_error "$command is required but not installed"
    fi
done

# Update the file listing
update_file_list

# Store the total number of clips
CLIP_COUNT=$(get_clip_count)

# Select a clip
select_clip

# Copy the video clip over from S3
if ! get_video; then
    exit_error "Could not get video clip"
fi

# Credit the track from the tags supercat.sh wrote into the clip, falling back
# to the filename for older clips that predate those tags
CLIP_TITLE=$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$ENTRY")
CLIP_ARTIST=$(ffprobe -v error -show_entries format_tags=artist -of default=nw=1:nk=1 "$ENTRY")

if [ -z "$CLIP_TITLE" ]; then
    CLIP_TITLE="${ENTRY%.mp4}"
fi

if [ -n "$CLIP_ARTIST" ]; then
    POST_TEXT="\"${CLIP_TITLE} (feat. Super Cat),\" by ${CLIP_ARTIST}"
else
    POST_TEXT="\"${CLIP_TITLE} (feat. Super Cat)\""
fi

# The same wording describes the video for anyone using a screen reader
ALT_TEXT="$POST_TEXT"

# Upload the video to Mastodon. The v2 endpoint returns 202 for video, meaning
# the media was accepted but is still processing.
MEDIA_JSON=$(curl -s -f -X POST \
    -H "Authorization: Bearer ${MASTODON_TOKEN}" \
    -F "file=@${ENTRY}" \
    -F "description=${ALT_TEXT}" \
    "${MASTODON_SERVER}/api/v2/media") \
    || exit_error "Video could not be uploaded to Mastodon"

MEDIA_ID=$(printf '%s' "$MEDIA_JSON" | jq -r '.id // empty')

# If the upload didn't yield a media ID, give up
if [ -z "$MEDIA_ID" ]; then
    exit_error "Mastodon upload didn’t return a media ID"
fi

# Wait for the video to finish processing before attaching it to a status
if ! await_mastodon_media "$MEDIA_ID"; then
    exit_error "Mastodon never finished processing the video"
fi

# Send the message to Mastodon
curl -s -f -X POST "${MASTODON_SERVER}/api/v1/statuses" \
    -H "Authorization: Bearer ${MASTODON_TOKEN}" \
    -F "status=${POST_TEXT}" \
    -F "media_ids[]=${MEDIA_ID}" > /dev/null \
    || exit_error "Posting message to Mastodon failed."

# Login to Bluesky to get session token
SESSION_JSON=$(curl -s -f -X POST https://bsky.social/xrpc/com.atproto.server.createSession \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg identifier "$BLUESKY_HANDLE" \
        --arg password "$BLUESKY_APP_PASSWORD" \
        '{identifier: $identifier, password: $password}')") \
    || exit_error "Bluesky login failed."

ACCESS_JWT=$(printf '%s' "$SESSION_JSON" | jq -r '.accessJwt // empty')
if [ -z "$ACCESS_JWT" ]; then
    exit_error "Bluesky login failed."
fi

# The repo is the account's DID, which is not always the same as the handle
BLUESKY_DID=$(printf '%s' "$SESSION_JSON" | jq -r '.did // empty')
if [ -z "$BLUESKY_DID" ]; then
    exit_error "Bluesky login didn’t return a DID."
fi

# Video uploads need a service auth token rather than the ordinary session
# token. The token's audience has to be the account's own PDS — not the video
# host — so look that up in the DID document.
PDS_HOST=$(curl -s -f "https://plc.directory/${BLUESKY_DID}" \
    | jq -r '.service[] | select(.id == "#atproto_pds") | .serviceEndpoint' \
    | sed -e 's#^https://##' -e 's#/$##') \
    || exit_error "Could not resolve the Bluesky PDS host."

if [ -z "$PDS_HOST" ]; then
    exit_error "DID document didn’t list a PDS endpoint."
fi

# The lexicon method is uploadBlob, even though the call goes to uploadVideo
SERVICE_JSON=$(curl -s -f \
    -H "Authorization: Bearer ${ACCESS_JWT}" \
    "https://bsky.social/xrpc/com.atproto.server.getServiceAuth?aud=did:web:${PDS_HOST}&lxm=com.atproto.repo.uploadBlob") \
    || exit_error "Could not get a Bluesky service token."

SERVICE_JWT=$(printf '%s' "$SERVICE_JSON" | jq -r '.token // empty')
if [ -z "$SERVICE_JWT" ]; then
    exit_error "Bluesky service token was empty."
fi

# Upload the video to Bluesky, which queues a transcoding job rather than
# returning a blob directly. Keep the response body on failure: this endpoint
# explains auth problems in the body, which -f would discard.
JOB_JSON=$(curl -s -X POST \
    "https://video.bsky.app/xrpc/app.bsky.video.uploadVideo?did=${BLUESKY_DID}&name=$(jq -rn --arg n "$ENTRY" '$n|@uri')" \
    -H "Authorization: Bearer ${SERVICE_JWT}" \
    -H "Content-Type: video/mp4" \
    --data-binary "@${ENTRY}") \
    || exit_error "Video upload to Bluesky failed."

# A successful upload reports the job at the top level, not under jobStatus
JOB_ID=$(printf '%s' "$JOB_JSON" | jq -r '.jobId // .jobStatus.jobId // empty')
if [ -z "$JOB_ID" ]; then
    exit_error "Bluesky upload didn’t return a job ID: $JOB_JSON"
fi

# Wait for transcoding to finish, which yields the blob to embed
VIDEO_BLOB=$(await_bluesky_video "$JOB_ID") \
    || exit_error "Bluesky never finished processing the video."

if [ -z "$VIDEO_BLOB" ] || [ "$VIDEO_BLOB" = "null" ]; then
    exit_error "Bluesky returned an empty video blob."
fi

# Prepare the status post for Bluesky
POST_BODY=$(jq -n \
    --arg repo "$BLUESKY_DID" \
    --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg text "$POST_TEXT" \
    --arg alt "$ALT_TEXT" \
    --argjson video "$VIDEO_BLOB" \
    --argjson width "$VIDEO_WIDTH" \
    --argjson height "$VIDEO_HEIGHT" \
    '{
        repo: $repo,
        collection: "app.bsky.feed.post",
        record: {
            "$type": "app.bsky.feed.post",
            text: $text,
            createdAt: $created_at,
            embed: {
                "$type": "app.bsky.embed.video",
                video: $video,
                alt: $alt,
                aspectRatio: { width: $width, height: $height }
            }
        }
    }')

# Post the status to Bluesky, with the uploaded video
BLUESKY_RESPONSE=$(curl -s -f -X POST "https://bsky.social/xrpc/com.atproto.repo.createRecord" \
    -H "Authorization: Bearer ${ACCESS_JWT}" \
    -H "Content-Type: application/json" \
    -d "$POST_BODY") \
    || exit_error "Bluesky post failed."

# Check for success (should contain a 'uri' field)
if ! printf '%s' "$BLUESKY_RESPONSE" | jq -e '.uri' > /dev/null 2>&1; then
    exit_error "Bluesky post failed: $BLUESKY_RESPONSE"
fi

# Both posts landed, so retire this clip from rotation
add_to_history
