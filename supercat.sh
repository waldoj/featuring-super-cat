#!/bin/bash

set -e

# Clean up temporary files
function cleanup() {
    rm -f /tmp/silence.mp3 /tmp/temp_input_with_silence.mp3 /tmp/temp_input.mp3 /tmp/cover.jpg
}

# Run the cleanup() function every time this script exits
trap cleanup EXIT

# Check if an argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <MP3 File>"
    exit 1
fi

if [ ! -f "$1" ]; then
    echo "$1 does not exist"
    exit 1
fi

# The cover art becomes the video, so there's nothing to make without it. Check
# up front, rather than failing partway through with a cryptic ffmpeg error.
if ! ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$1" | grep -q .; then
    echo "$1 has no cover art"
    exit 1
fi

# Input MP3 file from the command line argument
INPUT_MP3="$1"
# The song's own title and artist, carried into the MP4 so that anything
# downstream can credit the track without parsing the filename
INPUT_TITLE=$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$INPUT_MP3")
INPUT_ARTIST=$(ffprobe -v error -show_entries format_tags=artist -of default=nw=1:nk=1 "$INPUT_MP3")
# Duration of silence to prepend (in seconds)
DURATION_OF_SILENCE=5
# Name of the file to combine with
SUPERCAT_MP3="supercat.mp3"
# Output file name
BASE_FILENAME="${INPUT_MP3%.*}"
OUTPUT_MP4="$BASE_FILENAME (Feat. Super Cat).mp4"

# Tags for the MP4. The title passes through untouched. Fall back to the
# filename when the source has no title, so the output is never left untitled.
if [ -n "$INPUT_TITLE" ]; then
    OUTPUT_TITLE="$INPUT_TITLE"
else
    OUTPUT_TITLE="$(basename "$BASE_FILENAME")"
fi

if [ -n "$INPUT_ARTIST" ]; then
    OUTPUT_COMMENT="$INPUT_TITLE by $INPUT_ARTIST, featuring Super Cat"
else
    OUTPUT_COMMENT="Featuring Super Cat"
fi

# Generate silence.mp3 of specified duration
ffmpeg -y -nostdin -f lavfi -i anullsrc=r=44100:cl=stereo -t $DURATION_OF_SILENCE -q:a 9 -acodec libmp3lame /tmp/silence.mp3

# Concatenate silence with the input MP3, decoding both first so that the input
# can be any format, not just a raw MPEG audio stream
ffmpeg -y -nostdin -i /tmp/silence.mp3 -i "$INPUT_MP3" -filter_complex \
    "[0:a][1:a]concat=n=2:v=0:a=1,aresample=44100[aout]" -map "[aout]" /tmp/temp_input_with_silence.mp3

# Combine the modified input MP3 with the second MP3
ffmpeg -y -nostdin -i /tmp/temp_input_with_silence.mp3 -i $SUPERCAT_MP3 -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest,aresample=44100" /tmp/temp_input.mp3

# Save the cover art from the input MP3, re-encoding rather than copying, since
# embedded art may be PNG (common in M4A files) instead of JPEG
ffmpeg -y -nostdin -i "$INPUT_MP3" -an -frames:v 1 /tmp/cover.jpg

sips -z 750 750 /tmp/cover.jpg

# Add a "Featuring Supercat" overlay
ffmpeg -y -nostdin -i /tmp/cover.jpg -i overlay.png -filter_complex "overlay=W-w-10:H-h-10" /tmp/cover.jpg

# Truncate song at 30 seconds, fading it out at the end, and add cover art.
# Audio is mono at 128 kbps.
ffmpeg -y -nostdin -loop 1 -framerate 2 -i /tmp/cover.jpg -i /tmp/temp_input.mp3 -filter_complex "[1:a]afade=t=out:st=28:d=2,atrim=duration=30[audio]" -map 0:v -map "[audio]" -metadata title="$OUTPUT_TITLE" -metadata artist="$INPUT_ARTIST" -metadata comment="$OUTPUT_COMMENT" -c:v libx264 -t 30 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 1 "$OUTPUT_MP4"

echo "Created $OUTPUT_MP4"
