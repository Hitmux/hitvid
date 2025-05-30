#!/bin/bash

# hitvid - A terminal-based video player using chafa
# Author: Hitmux
# Description: Play videos in terminal using chafa for rendering frames

# Default settings
FPS=5 # Set the playback frames per second.
SCALE_MODE="fit" # Set scaling mode: fit, fill, stretch.
COLORS="256" # Set color mode: 2, 16, 256, full (full color)
DITHER="ordered" # Set dithering mode: none, ordered, diffusion.
SYMBOLS="block" # Set character set: block, ascii, space.
WIDTH=$(tput cols) # Set display width (in characters).
HEIGHT=$(($(tput lines) - 2)) # Reserve 1 line for info, 1 for safety/prompt
QUIET=0 # Quiet mode, suppresses progress and other information output.
LOOP=0 # 	Loop video playback.
PLAY_MODE="stream" # "preload" or "stream"
NUM_THREADS=$(nproc --all 2>/dev/null || echo 4) # Default to 4 if nproc fails

# --- Helper Functions ---
cleanup() {
    # Restore cursor and switch back to normal screen buffer first
    # so any subsequent messages appear on the normal screen if desired,
    # or are hidden if rmcup is last.
    tput cnorm # Restore cursor
    tput rmcup # Restore normal screen buffer

    echo "Cleaning up temporary files..." >&2 # This will now appear on the normal screen
    # Kill background rendering process if it exists and is running
    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        echo "Terminating background rendering process $RENDER_PID..." >&2
        kill "$RENDER_PID" 2>/dev/null
        # Give it a moment, then force kill if still alive
        sleep 0.5
        if ps -p "$RENDER_PID" > /dev/null; then
            kill -9 "$RENDER_PID" 2>/dev/null
        fi
    fi
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    # If we created a fifo for xargs, remove it
    if [ -n "$XARGS_FIFO" ] && [ -p "$XARGS_FIFO" ]; then
        rm -f "$XARGS_FIFO"
    fi
}

# Function to display help message
show_help() {
    echo "hitvid - Terminal-based video player using chafa"
    echo ""
    echo "Usage: hitvid [VIDEO_PATH] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help message"
    echo "  -f, --fps FPS         Set playback frames per second (default: $FPS)"
    echo "  -s, --scale MODE      Set scaling mode: fit, fill, stretch (default: $SCALE_MODE)"
    echo "  -c, --colors NUM      Set color mode: 2, 16, 256, full (default: $COLORS)"
    echo "  -d, --dither MODE     Set dither mode: none, ordered, diffusion (default: $DITHER)"
    echo "  -y, --symbols SET     Set symbol set: block, ascii, space (default: $SYMBOLS)"
    echo "  -w, --width WIDTH     Set display width (default: terminal width)"
    echo "  -t, --height HEIGHT   Set display height (default: terminal height - 2 lines)"
    echo "  -m, --mode MODE       Playback mode: preload, stream (default: $PLAY_MODE)"
    echo "      --threads N       Number of parallel threads for Chafa rendering (default: $NUM_THREADS)"
    echo "  -q, --quiet           Suppress progress information"
    echo "  -l, --loop            Loop playback"
    echo ""
    echo "Examples:"
    echo "  hitvid video.mp4"
    echo "  hitvid video.mp4 --mode stream --threads 8"
    echo "  hitvid video.mp4 --fps 20 --colors full --scale fill"
    echo ""
    exit 0
}

# Function to check if required tools are installed
check_dependencies() {
    for cmd in ffmpeg chafa tput nproc xargs; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed. Please install it first." >&2
            exit 1
        fi
    done
}

# Function to create temporary directory
setup_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/hitvid.XXXXXX)
    if [ ! -d "$TEMP_DIR" ]; then
        echo "Error: Failed to create temporary directory." >&2
        exit 1
    fi
    JPG_FRAMES_DIR="$TEMP_DIR/jpg_frames"
    CHAFA_FRAMES_DIR="$TEMP_DIR/chafa_frames"
    mkdir "$JPG_FRAMES_DIR" "$CHAFA_FRAMES_DIR"
    if [ ! -d "$JPG_FRAMES_DIR" ] || [ ! -d "$CHAFA_FRAMES_DIR" ]; then
        echo "Error: Failed to create temporary subdirectories." >&2
        cleanup # Attempt cleanup before exiting
        exit 1
    fi
    # Set trap to clean up temporary files and restore cursor/screen on exit
    trap "cleanup; exit" INT TERM EXIT # EXIT trap is important for normal termination
}

# Function to extract video information
get_video_info() {
    if [ $QUIET -eq 0 ]; then echo "Analyzing video file..."; fi
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 "$VIDEO_PATH" 2>/dev/null)
    if [ -z "$VIDEO_INFO" ]; then echo "Error: Could not extract video information." >&2; cleanup; exit 1; fi

    VIDEO_WIDTH=$(echo "$VIDEO_INFO" | cut -d',' -f1)
    VIDEO_HEIGHT=$(echo "$VIDEO_INFO" | cut -d',' -f2)
    VIDEO_DURATION_FLOAT=$(echo "$VIDEO_INFO" | cut -d',' -f3)
    if [[ "$VIDEO_DURATION_FLOAT" == "N/A" ]]; then VIDEO_DURATION="N/A"; else VIDEO_DURATION=$(printf "%.0f" "$VIDEO_DURATION_FLOAT"); fi
    if [ $QUIET -eq 0 ]; then echo "Video resolution: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}, Duration: ${VIDEO_DURATION}s"; fi
}

# Function to extract frames from video
extract_frames() {
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"

    local ffmpeg_input_arg="$VIDEO_PATH"
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    if [ $QUIET -eq 0 ]; then
        echo "Extracting frames (this may take a while)..."
        ffmpeg -i "$ffmpeg_input_arg" -vf "fps=$FPS" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" > "$ffmpeg_output_file" 2>&1
    else
        ffmpeg -i "$ffmpeg_input_arg" -vf "fps=$FPS" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" &>/dev/null
    fi

    if [ $? -ne 0 ]; then
        if [ $QUIET -eq 0 ]; then
            echo "Error during ffmpeg extraction. Log:" >&2
            cat "$ffmpeg_output_file" >&2
        else
            echo "Error during ffmpeg extraction. Run without --quiet for details." >&2
        fi
    fi

    TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" | wc -l)
    TOTAL_FRAMES=${TOTAL_FRAMES// /}

    if [ "$TOTAL_FRAMES" -eq 0 ]; then echo "Error: No frames were extracted. Check video file and ffmpeg output." >&2; cleanup; exit 1; fi
    if [ $QUIET -eq 0 ]; then echo "Extracted $TOTAL_FRAMES frames at $FPS fps"; fi
}

# --- Chafa Rendering Functions ---
export CHAFA_OPTS_RENDER JPG_FRAMES_DIR CHAFA_FRAMES_DIR QUIET

render_single_frame_for_xargs() {
    local frame_jpg_basename="$1"
    local frame_num_str="${frame_jpg_basename%.jpg}"
    local jpg_path="$JPG_FRAMES_DIR/$frame_jpg_basename"
    local txt_path="$CHAFA_FRAMES_DIR/${frame_num_str}.txt"

    if [ ! -f "$jpg_path" ]; then
        if [ "$QUIET" -eq 0 ]; then echo "Warning: JPG $jpg_path not found for rendering." >&2; fi
        return 1
    fi
    chafa $CHAFA_OPTS_RENDER "$jpg_path" > "$txt_path"
    return $?
}
export -f render_single_frame_for_xargs

render_all_chafa_frames_parallel() {
    if [ $QUIET -eq 0 ]; then
        echo "Pre-rendering $TOTAL_FRAMES Chafa frames using up to $NUM_THREADS threads..."
    fi

    CHAFA_OPTS_RENDER="--clear --size=${WIDTH}x${HEIGHT} --colors=$COLORS --dither=$DITHER"
    case $SCALE_MODE in "fill") CHAFA_OPTS_RENDER+=" --zoom";; "stretch") CHAFA_OPTS_RENDER+=" --stretch";; esac
    case $SYMBOLS in "block") CHAFA_OPTS_RENDER+=" --symbols=block";; "ascii") CHAFA_OPTS_RENDER+=" --symbols=ascii";; "space") CHAFA_OPTS_RENDER+=" --symbols=space";; esac
    export CHAFA_OPTS_RENDER

    find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -printf "%f\n" | \
        xargs -P "$NUM_THREADS" -I {} bash -c 'render_single_frame_for_xargs "$@"' _ {}

    local rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" | wc -l)
    rendered_count=${rendered_count// /}
    if [ $QUIET -eq 0 ]; then
        echo -e "\nParallel Chafa rendering complete. $rendered_count frames rendered."
    fi
    if [ "$rendered_count" -ne "$TOTAL_FRAMES" ]; then
        echo "Warning: Expected $TOTAL_FRAMES rendered frames, but found $rendered_count." >&2
    fi
}

# --- Playback Functions ---
play_chafa_frames() {
    local frame_delay
    frame_delay=$(awk "BEGIN {print 1.0/$FPS}")
    local info_line
    info_line=$(($(tput lines) - 1))

    tput smcup # Switch to alternate screen buffer
    tput civis # Hide cursor
    clear     # Initial clear of the alternate screen

    local current_loop=1
    while true; do
        if [ $QUIET -eq 0 ] && [ $LOOP -eq 1 ] && [ $current_loop -gt 1 ]; then
            tput cup "$info_line" 0; printf "Starting Loop: %d " "$current_loop"; tput el; sleep 1;
        fi

        for i_seq in $(seq 1 "$TOTAL_FRAMES"); do
            local frame_num_padded
            frame_num_padded=$(printf "frame-%05d" "$i_seq")
            local chafa_frame_file="$CHAFA_FRAMES_DIR/${frame_num_padded}.txt"

            if [ "$PLAY_MODE" == "stream" ]; then
                local wait_count=0
                while [ ! -f "$chafa_frame_file" ]; do
                    if [[ -n "$RENDER_PID" ]] && ! ps -p "$RENDER_PID" > /dev/null; then
                        if [ ! -f "$chafa_frame_file" ]; then
                           echo -e "\nError: Background renderer died and frame $chafa_frame_file is missing." >&2
                           # cleanup will be called by trap
                           exit 1
                        fi
                    fi
                    sleep 0.01
                    wait_count=$((wait_count + 1))
                    if [ $QUIET -eq 0 ] && (( wait_count % 50 == 0 )); then
                        tput cup "$info_line" 0
                        printf "Playing: Waiting for frame %s/%d (Renderer PID: %s)..." "$frame_num_padded" "$TOTAL_FRAMES" "${RENDER_PID:-N/A}"
                        tput el
                    fi
                done
            elif [ ! -f "$chafa_frame_file" ]; then
                echo -e "\nError: Frame $chafa_frame_file missing in preload mode." >&2
                sleep "$frame_delay"
                continue
            fi

            cat "$chafa_frame_file"

            if [ $QUIET -eq 0 ]; then
                local progress=$((100 * i_seq / TOTAL_FRAMES))
                tput cup "$info_line" 0
                printf "Playing: %3d%% (Frame %s/%d)" "$progress" "$frame_num_padded" "$TOTAL_FRAMES"
                if [ $LOOP -eq 1 ]; then printf " Loop %d" "$current_loop"; fi
                tput el
            fi
            sleep "$frame_delay"
        done

        if [ $LOOP -eq 0 ]; then break; fi
        current_loop=$((current_loop + 1))
    done

    # No need for tput cnorm or clear here, cleanup will handle it
    if [ $QUIET -eq 0 ]; then tput cup "$info_line" 0; tput el; echo -e "\nPlayback complete."; fi
    # The 'exit 0' at the end of the script will trigger the EXIT trap, which calls cleanup.
}

# --- Argument Parsing ---
if [ $# -eq 0 ]; then show_help; fi
VIDEO_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -f|--fps) FPS="$2"; shift 2 ;;
        -s|--scale) SCALE_MODE="$2"; shift 2 ;;
        -c|--colors) COLORS="$2"; shift 2 ;;
        -d|--dither) DITHER="$2"; shift 2 ;;
        -y|--symbols) SYMBOLS="$2"; shift 2 ;;
        -w|--width) WIDTH="$2"; shift 2 ;;
        -t|--height) HEIGHT="$2"; shift 2 ;;
        -m|--mode) PLAY_MODE="$2"; shift 2 ;;
        --threads) NUM_THREADS="$2"; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        -l|--loop) LOOP=1; shift ;;
        *)
            if [ -z "$VIDEO_PATH" ]; then VIDEO_PATH="$1"; shift;
            else echo "Error: Unknown option $1" >&2; exit 1; fi ;;
    esac
done

# --- Validate Inputs ---
if [ -z "$VIDEO_PATH" ]; then echo "Error: No video file specified." >&2; exit 1; fi
if [ ! -f "$VIDEO_PATH" ] && [[ "$VIDEO_PATH" != http* ]]; then echo "Error: Video file '$VIDEO_PATH' not found." >&2; exit 1; fi
if ! [[ "$FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(awk "BEGIN {print ($FPS <= 0)}") )); then echo "Error: FPS must be a positive number." >&2; exit 1; fi
MAX_FPS=60; if (( $(awk "BEGIN {print ($FPS > $MAX_FPS)}") )); then echo "Warning: FPS $FPS is high, capping at $MAX_FPS." >&2; FPS=$MAX_FPS; fi
if [[ "$SCALE_MODE" != "fit" && "$SCALE_MODE" != "fill" && "$SCALE_MODE" != "stretch" ]]; then echo "Error: Invalid scale mode." >&2; exit 1; fi
if [[ "$COLORS" != "2" && "$COLORS" != "16" && "$COLORS" != "256" && "$COLORS" != "full" ]]; then echo "Error: Invalid color mode." >&2; exit 1; fi
if [[ "$DITHER" != "none" && "$DITHER" != "ordered" && "$DITHER" != "diffusion" ]]; then echo "Error: Invalid dither mode." >&2; exit 1; fi
if [[ "$SYMBOLS" != "block" && "$SYMBOLS" != "ascii" && "$SYMBOLS" != "space" ]]; then echo "Error: Invalid symbol set." >&2; exit 1; fi
if ! [[ "$WIDTH" =~ ^[0-9]+$ ]] || [ "$WIDTH" -le 0 ]; then echo "Error: Width must be positive." >&2; exit 1; fi
if ! [[ "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -le 0 ]; then echo "Error: Height must be positive." >&2; exit 1; fi
if [[ "$PLAY_MODE" != "preload" && "$PLAY_MODE" != "stream" ]]; then echo "Error: Invalid play mode. Use 'preload' or 'stream'." >&2; exit 1; fi
if ! [[ "$NUM_THREADS" =~ ^[0-9]+$ ]] || [ "$NUM_THREADS" -le 0 ]; then echo "Error: Number of threads must be a positive integer." >&2; exit 1; fi

# --- Main Execution ---
check_dependencies
setup_temp_dir # Sets TEMP_DIR, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR, and trap

# Messages before play_chafa_frames will appear on the normal screen
get_video_info
extract_frames # Sets TOTAL_FRAMES

RENDER_PID=""

if [ "$PLAY_MODE" == "preload" ]; then
    if [ $QUIET -eq 0 ]; then echo "Mode: Preload. Rendering all frames before playback."; fi
    render_all_chafa_frames_parallel
    play_chafa_frames
elif [ "$PLAY_MODE" == "stream" ]; then
    if [ $QUIET -eq 0 ]; then echo "Mode: Stream. Rendering frames in background during playback."; fi
    render_all_chafa_frames_parallel &
    RENDER_PID=$!
    if [ $QUIET -eq 0 ]; then echo "Background rendering started (PID: $RENDER_PID)."; fi
    play_chafa_frames
    if ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "Waiting for background rendering (PID: $RENDER_PID) to complete..."; fi
        wait "$RENDER_PID"
        if [ $QUIET -eq 0 ]; then echo "Background rendering complete."; fi
    fi
    RENDER_PID=""
fi

# Normal exit will trigger the EXIT trap, which calls cleanup.
# cleanup will restore cursor and screen.
exit 0