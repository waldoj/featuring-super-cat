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

# Input MP3 file from the command line argument
INPUT_MP3="$1"
# Duration of silence to prepend (in seconds)
DURATION_OF_SILENCE=7
# Name of the file to combine with
SUPERCAT_MP3="supercat.mp3"
# Output file name
BASE_FILENAME="${INPUT_MP3%.*}"
OUTPUT_MP4="$BASE_FILENAME (Feat. Supercat).mp4"

# Generate silence.mp3 of specified duration
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t $DURATION_OF_SILENCE -q:a 9 -acodec libmp3lame /tmp/silence.mp3

# Concatenate silence with the input MP3
ffmpeg -i "concat:/tmp/silence.mp3|$INPUT_MP3" -acodec copy /tmp/temp_input_with_silence.mp3

# Combine the modified input MP3 with the second MP3
ffmpeg -i /tmp/temp_input_with_silence.mp3 -i $SUPERCAT_MP3 -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest" /tmp/temp_input.mp3

# Save the cover art from the input MP3
ffmpeg -i "$INPUT_MP3" -an -vcodec copy /tmp/cover.jpg

# Add a "Featuring Supercat" overlay
ffmpeg -y -i /tmp/cover.jpg -i overlay.png -filter_complex "overlay=W-w-10:H-h-10" /tmp/cover.jpg

# Truncate song at 30 seconds, fading it out at the end, and add cover art
ffmpeg -loop 1 -framerate 2 -i /tmp/cover.jpg -i /tmp/temp_input.mp3 -filter_complex "[1:a]afade=t=out:st=28:d=2,atrim=duration=30[audio]" -map 0:v -map "[audio]" -c:v libx264 -t 30 -pix_fmt yuv420p -c:a aac "$OUTPUT_MP4"

echo "Created $OUTPUT_MP4"
