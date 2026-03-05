#!/bin/bash

# Check if a URL was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <youtube_url>"
    exit 1
fi

# Download audio using yt-dlp
# --extract-audio: Convert to audio-only
# --audio-format: Save as mp3 (or m4a, wav, etc.)
# --output: Standard naming format
yt-dlp -x --audio-format mp3 -o "%(title)s.%(ext)s" "$1"
