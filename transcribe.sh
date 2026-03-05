#!/bin/bash

# --- CONFIGURATION ---
WHISPER_DIR="$HOME/code/whisper.cpp"
MODEL="$WHISPER_DIR/model/ggml-medium.en.bin"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"

# Check for input
if [ -z "$1" ]; then
    echo "Usage: ./transcribe.sh <file_or_folder>"
    exit 1
fi

TARGET="$1"

# Function to process a single file
process_file() {
    local FILE="$1"
    local BASE_NAME="${FILE%.*}"
    local TEMP_WAV="${BASE_NAME}_temp_16khz.wav"

    echo "Processing: $FILE"
    
    # Convert to 16kHz WAV
    ffmpeg -i "$FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TEMP_WAV" -y -loglevel error
    
    # Transcribe
    "$WHISPER_BIN" -m "$MODEL" -f "$TEMP_WAV" -otxt -t 10
    
    # Cleanup
    rm "$TEMP_WAV"
}

# --- MAIN LOGIC ---
if [ -d "$TARGET" ]; then
    echo "Target is a directory. Processing all files..."
    # Loop through common video/audio extensions
    for f in "$TARGET"/*.{mp4,mkv,avi,mov,mp3,wav,flac}; do
        # Check if files matching the extensions actually exist
        [ -e "$f" ] || continue
        process_file "$f"
    done
elif [ -f "$TARGET" ]; then
    process_file "$TARGET"
else
    echo "Error: '$TARGET' is not a valid file or directory."
    exit 1
fi

echo "Done!"
