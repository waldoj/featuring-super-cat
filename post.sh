#!/usr/bin/env bash

set -euo pipefail

# Shared library: credentials, logging, the failure path, and both platforms'
# transport. See lib/botlib/ and the bot-harness docs.
. "$(dirname "$0")/lib/botlib/core.sh"
. "$(dirname "$0")/lib/botlib/secrets.sh"
. "$(dirname "$0")/lib/botlib/mastodon.sh"
. "$(dirname "$0")/lib/botlib/bluesky.sh"

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

# Get the name of the working directory
cd "$(dirname "$0")" || exit

load_secrets featuring-super-cat
require_secrets MASTODON_SERVER MASTODON_TOKEN \
                BLUESKY_HANDLE BLUESKY_APP_PASSWORD S3_BUCKET

# Make sure the tools this script depends on are actually present
require_commands aws curl ffprobe jq

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

# Mastodon and Bluesky are attempted independently: a failure on one platform
# is logged and the other is still attempted, rather than the whole run dying
# on whichever platform happens to be first. Each block sets its own MASTODON_
# and BLUESKY_ vars to record what happened, and the script exits non-zero at
# the end if either platform failed -- one Slack alert either way, but it no
# longer costs a healthy platform its post.
MASTODON_OK="no"
BLUESKY_OK="no"

# Upload the video to Mastodon. The v2 endpoint returns 202 for video, meaning
# the media was accepted but is still processing.
if MEDIA_ID=$(masto_upload_media "$ENTRY" "$ALT_TEXT"); then
    if masto_await_media "$MEDIA_ID"; then
        if masto_post_status "$POST_TEXT" "$MEDIA_ID" > /dev/null; then
            log_info "posted to mastodon media_id=${MEDIA_ID}"
            MASTODON_OK="yes"
        else
            log_error "Posting message to Mastodon failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        fi
    else
        log_error "Mastodon never finished processing the video: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
    fi
else
    log_error "Video could not be uploaded to Mastodon: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
fi

# Login to Bluesky to get session token
if SESSION_JSON=$(bsky_create_session "$BLUESKY_HANDLE" "$BLUESKY_APP_PASSWORD"); then
    ACCESS_JWT=$(bsky_access_jwt "$SESSION_JSON")

    # The repo is the account's DID, which is not always the same as the handle
    BLUESKY_DID=$(bsky_did "$SESSION_JSON")
    if [ -z "$BLUESKY_DID" ]; then
        log_error "Bluesky login didn’t return a DID: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
    else
        # Video uploads need a service auth token rather than the ordinary
        # session token, and its audience has to be the account's own PDS
        # rather than the video host. The PDS comes out of the session
        # response, which already carries the DID document -- this used to be
        # a second request to plc.directory for a document already in hand.
        if ! PDS_HOST=$(bsky_pds_host_from_session "$SESSION_JSON"); then
            log_error "Could not resolve the Bluesky PDS host."
        # The lexicon method is uploadBlob, even though the call goes to
        # uploadVideo
        elif ! SERVICE_JWT=$(bsky_service_auth "$ACCESS_JWT" "did:web:${PDS_HOST}" \
            "com.atproto.repo.uploadBlob"); then
            log_error "Could not get a Bluesky service token: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        # Upload the video to Bluesky, which queues a transcoding job rather
        # than returning a blob directly
        elif ! JOB_ID=$(bsky_upload_video "$BLUESKY_DID" "$SERVICE_JWT" "$ENTRY" "$ENTRY"); then
            log_error "Video upload to Bluesky failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        # Wait for transcoding to finish, which yields the blob to embed
        elif ! VIDEO_BLOB=$(bsky_await_video "$JOB_ID"); then
            log_error "Bluesky never finished processing the video: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        elif [ -z "$VIDEO_BLOB" ] || [ "$VIDEO_BLOB" = "null" ]; then
            log_error "Bluesky returned an empty video blob."
        else
            # Prepare the record. The library handles transport; what to say
            # stays here, since the embed differs from bot to bot.
            RECORD=$(jq -n \
                --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                --arg text "$POST_TEXT" \
                --arg alt "$ALT_TEXT" \
                --argjson video "$VIDEO_BLOB" \
                --argjson width "$VIDEO_WIDTH" \
                --argjson height "$VIDEO_HEIGHT" \
                '{
                    "$type": "app.bsky.feed.post",
                    text: $text,
                    createdAt: $created_at,
                    embed: {
                        "$type": "app.bsky.embed.video",
                        video: $video,
                        alt: $alt,
                        aspectRatio: { width: $width, height: $height }
                    }
                }')

            # Post the status to Bluesky, with the uploaded video
            if BLUESKY_RESPONSE=$(bsky_create_record "$BLUESKY_DID" "$ACCESS_JWT" "$RECORD"); then
                log_info "posted to bluesky uri=$(printf '%s' "$BLUESKY_RESPONSE" | jq -r '.uri // empty')"
                BLUESKY_OK="yes"
            else
                log_error "Bluesky post failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
            fi
        fi
    fi
else
    log_error "Bluesky login failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
fi

# Retire the clip on any success, so a platform that already has it is not
# handed it again next run. A clip that only reached one platform this run
# gets no automatic retry on the other -- see docs/RESILIENCE.md.
if [ "$MASTODON_OK" = "yes" ] || [ "$BLUESKY_OK" = "yes" ]; then
    add_to_history
fi

if [ "$MASTODON_OK" = "no" ] || [ "$BLUESKY_OK" = "no" ]; then
    exit_error "Posting failed: mastodon=${MASTODON_OK} bluesky=${BLUESKY_OK}"
fi
