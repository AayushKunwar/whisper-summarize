#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config from .env file
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Defaults
GROQ_MODEL="${GROQ_MODEL:-llama-3.3-70b-versatile}"
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-$SCRIPT_DIR/system_prompt.txt}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/code/whisper.cpp}"
MODEL="$WHISPER_DIR/model/ggml-medium.en.bin"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"

# Temp file for audio filename
AUDIO_FILE=""
TEMP_WAV=""
VIDEO_TITLE=""

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

function error() {
    echo "[ERROR] $*" >&2
    exit 1
}

function check_deps() {
    local missing=()
    
    command -v yt-dlp >/dev/null 2>&1 || missing+=("yt-dlp")
    command -v ffmpeg >/dev/null 2>&1 || missing+=("ffmpeg")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    
    if [[ ! -x "$WHISPER_BIN" ]]; then
        missing+=("whisper-cli ($WHISPER_BIN)")
    fi
    
    if [[ ! -f "$MODEL" ]]; then
        missing+=("whisper model ($MODEL)")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    
    if [[ -z "${GROQ_API_KEY:-}" ]]; then
        error "GROQ_API_KEY not set in .env file or environment"
    fi
    
    if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
        error "System prompt file not found: $SYSTEM_PROMPT_FILE"
    fi
}

function cleanup() {
    local exit_code=$?
    log "Cleanup running (exit code: $exit_code)"
    # Only remove temp WAV, keep audio and transcript
    [[ -n "$TEMP_WAV" && -f "$TEMP_WAV" ]] && rm -f "$TEMP_WAV" && log "Removed temp WAV"
    
    if [[ $exit_code -ne 0 ]]; then
        log "Script exited with error (code: $exit_code)"
    else
        log "Script completed successfully"
    fi
}

trap cleanup EXIT

function download_audio() {
    local url="$1"
    
    # Get video title and ID
    log "Getting video info..."
    local video_title
    video_title=$(yt-dlp --print "%(title)s" --no-playlist -- "$url")
    local video_id
    video_id=$(yt-dlp --print "%(id)s" --no-playlist -- "$url")
    log "Video title: $video_title"
    log "Video ID: $video_id"
    VIDEO_TITLE="$video_title"
    
    # Sanitize title for filename (keep more chars, use ID as fallback)
    local safe_title
    safe_title=$(echo "$video_title" | sed 's/[^a-zA-Z0-9\-_.() ]//g' | tr -s ' ' | cut -c1-80)
    
    # If title becomes empty or too short, use video ID
    if [[ -z "$safe_title" || ${#safe_title} -lt 3 ]]; then
        safe_title="$video_id"
    fi
    
    log "Safe title: $safe_title"
    
    # Check if audio file already exists
    local audio_file="${safe_title}.mp3"
    if [[ -f "$audio_file" ]]; then
        log "Audio file already exists: $audio_file"
        AUDIO_FILE="$audio_file"
        return 0
    fi
    
    # Check if WAV exists
    local wav_file="${safe_title}_16khz.wav"
    if [[ -f "$wav_file" ]]; then
        log "WAV file already exists: $wav_file"
        AUDIO_FILE="$wav_file"
        TEMP_WAV="$wav_file"
        return 0
    fi
    
    log "Downloading audio from YouTube..."
    # Use --audio-format mp3 with -x (extract audio), no specific format to avoid "not available" error
    yt-dlp -x --audio-format mp3 -o "${safe_title}.%(ext)s" --no-playlist -- "$url" 2>&1 | tee /dev/stderr
    
    AUDIO_FILE="$audio_file"
    
    if [[ ! -f "$AUDIO_FILE" ]]; then
        error "Audio file not found: $audio_file"
    fi
    
    log "Audio downloaded: $audio_file ($(wc -c < "$audio_file") bytes)"
}

function convert_audio() {
    local input_file="$1"
    local base_name="${input_file%.*}"
    local wav_file="${base_name}_16khz.wav"
    
    # Check if WAV already exists
    if [[ -f "$wav_file" ]]; then
        log "WAV file already exists: $wav_file"
        TEMP_WAV="$wav_file"
        return 0
    fi
    
    log "Converting to 16kHz WAV..."
    log "  Input: $input_file"
    log "  Output: $wav_file"
    
    ffmpeg -i "$input_file" -ar 16000 -ac 1 -c:a pcm_s16le "$wav_file" -y 2>&1 | tee /dev/stderr
    
    if [[ ! -f "$wav_file" ]]; then
        error "WAV file was not created"
    fi
    
    log "Audio converted: $wav_file ($(wc -c < "$wav_file") bytes)"
    TEMP_WAV="$wav_file"
}

function transcribe() {
    local wav_file="$1"
    local txt_file="${wav_file}.txt"  # whisper saves as <input>.txt
    
    # Check if transcript already exists and is not empty
    if [[ -f "$txt_file" ]]; then
        local txt_size
        txt_size=$(wc -c < "$txt_file")
        if [[ "$txt_size" -gt 100 ]]; then
            log "Transcript already exists: $txt_file ($txt_size bytes)"
            echo "$txt_file"
            return 0
        else
            log "Transcript exists but is too small ($txt_size bytes), re-transcribing..."
        fi
    fi
    
    log "Transcribing with whisper.cpp..."
    log "  Input: $wav_file"
    log "  Output: $txt_file"
    log "  Model: $MODEL"
    
    "$WHISPER_BIN" -m "$MODEL" -f "$wav_file" -otxt -t 10 2>&1 | tee /dev/stderr
    
    if [[ ! -f "$txt_file" ]]; then
        error "Transcript file not created: $txt_file"
    fi
    
    local txt_size
    txt_size=$(wc -c < "$txt_file")
    log "Transcription complete: $txt_file ($txt_size bytes)"
    echo "$txt_file"
}

function summarize() {
    local transcript_file="$1"
    local system_prompt
    system_prompt=$(<"$SYSTEM_PROMPT_FILE")
    local transcript_content
    transcript_content=$(<"$transcript_file")
    
    log "Summarizing with Groq API (model: $GROQ_MODEL)..."
    log "  Transcript: $(wc -c < "$transcript_file") bytes"
    
    # Build JSON payload
    local json_payload
    json_payload=$(
        jq -n \
            --arg system "$system_prompt" \
            --arg content "$transcript_content" \
            --arg model "$GROQ_MODEL" \
            '{
                messages: [
                    {role: "system", content: $system},
                    {role: "user", content: $content}
                ],
                model: $model,
                temperature: 0.6,
                max_completion_tokens: 8192,
                top_p: 1,
                stream: false
            }'
    )
    
    log "Sending request to Groq API..."
    
    local response
    response=$(
        curl -s "https://api.groq.com/openai/v1/chat/completions" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${GROQ_API_KEY}" \
            -d "$json_payload"
    )
    
    log "Groq response received: $(wc -c <<< "$response") bytes"
    
    local error_msg
    error_msg=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error_msg" ]]; then
        log "Groq API error: $error_msg"
        log "Full response: $response"
        error "Groq API error: $error_msg"
    fi
    
    local summary
    summary=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$summary" ]]; then
        log "Empty summary. Response: $response"
        error "No summary in response"
    fi
    
    log "Summary received: $(wc -c <<< "$summary") bytes"
    echo "$summary"
}

function main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <youtube_url> [output_file]" >&2
        exit 1
    fi
    
    local youtube_url="$1"
    local output_file="${2:-}"
    
    check_deps
    log "All dependencies OK"
    
    log "=== STEP 1: Download audio ==="
    log "  URL: $youtube_url"
    log "  Groq Model: $GROQ_MODEL"
    log "  Whisper Model: $MODEL"
    
    download_audio "$youtube_url"
    
    log "=== STEP 2: Convert audio ==="
    convert_audio "$AUDIO_FILE"
    
    log "=== STEP 3: Transcribe ==="
    local transcript_file
    transcript_file=$(transcribe "$TEMP_WAV")
    
    log "=== STEP 4: Summarize ==="
    local summary
    summary=$(summarize "$transcript_file")
    
    # Determine output file
    if [[ -z "$output_file" ]]; then
        output_file="${VIDEO_TITLE}_summary.txt"
    fi
    
    echo "$summary" > "$output_file"
    log "Summary saved to: $output_file"
    
    log "=== DONE ==="
    echo ""
    echo "=== SUMMARY ==="
    echo "$summary"
}

main "$@"
