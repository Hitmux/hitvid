#!/bin/bash

# hitvid v1.0.2 - A terminal-based video player using chafa
# Author: Hitmux
# Description: Play videos in terminal using chafa for rendering frames

# Default settings
FPS=15 # Set the playback frames per second for EXTRACTION.
SCALE_MODE="fit" # Set scaling mode: fit, fill, stretch.
COLORS="256" # Set color mode: 2, 16, 256, full (full color)
DITHER="ordered" # Set dithering mode: none, ordered, diffusion.
SYMBOLS="block" # Set character set: block, ascii, space.
WIDTH=$(tput cols) # Set display width (in characters).
HEIGHT=$(($(tput lines) - 2)) # Reserve 1 line for info, 1 for safety/prompt
QUIET=0 # Quiet mode, suppresses progress and other information output.
LOOP=0 # Loop video playback.
PLAY_MODE="stream" # "preload" or "stream"
NUM_THREADS=$(nproc --all 2>/dev/null || echo 4) # Default to 4 if nproc fails

# Constants for FFmpeg pre-scaling based on character cell approximation
CHAR_PIXEL_WIDTH_APPROX=8
CHAR_PIXEL_HEIGHT_APPROX=16

# Playback control settings
PAUSED=0
ORIGINAL_FPS=$FPS # Store the FPS used for extraction, set properly after arg parsing
CURRENT_FPS_MULTIPLIER_INDEX=3 # Index for 1.0x speed in PLAYBACK_SPEED_MULTIPLIERS
declare -a PLAYBACK_SPEED_MULTIPLIERS
PLAYBACK_SPEED_MULTIPLIERS=(0.25 0.50 0.75 1.00 1.25 1.50 2.00)
SEEK_SECONDS=5

# --- Helper Functions ---
cleanup() {
    stty sane # Restore terminal settings to a known good state
    tput cnorm # Restore cursor
    tput rmcup # Restore normal screen buffer

    if [ $QUIET -eq 0 ]; then echo "Cleaning up temporary files..." >&2; fi

    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "Terminating background rendering process $RENDER_PID..." >&2; fi
        kill "$RENDER_PID" 2>/dev/null
        sleep 0.1
        if ps -p "$RENDER_PID" > /dev/null; then
            kill -9 "$RENDER_PID" 2>/dev/null
        fi
    fi
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

show_help() {
    echo "hitvid - Terminal-based video player using chafa"
    echo ""
    echo "Usage: hitvid [VIDEO_PATH] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help message"
    echo "  -f, --fps FPS         Set extraction frames per second (default: $FPS)"
    echo "  -s, --scale MODE      Set scaling mode: fit, fill, stretch (default: $SCALE_MODE)"
    echo "                        This affects both FFmpeg pre-scaling and Chafa rendering."
    echo "  -c, --colors NUM      Set color mode: 2, 16, 256, full (default: $COLORS)"
    echo "  -d, --dither MODE     Set dither mode: none, ordered, diffusion (default: $DITHER)"
    echo "  -y, --symbols SET     Set symbol set: block, ascii, space (default: $SYMBOLS)"
    echo "  -w, --width WIDTH     Set display width (default: terminal width)"
    echo "  -t, --height HEIGHT   Set display height (default: terminal height - 2 lines)"
    echo "  -m, --mode MODE       Playback mode: preload, stream (default: $PLAY_MODE)"
    echo "      --threads N       Number of parallel threads for Chafa rendering (default: $NUM_THREADS)"
    echo "  -q, --quiet           Suppress progress information and interactive feedback"
    echo "  -l, --loop            Loop playback"
    echo ""
    echo "Interactive Controls (during playback):"
    echo "  Spacebar              Pause/Resume"
    echo "  Right Arrow           Seek forward $SEEK_SECONDS seconds"
    echo "  Left Arrow            Seek backward $SEEK_SECONDS seconds"
    echo "  Up Arrow              Increase playback speed"
    echo "  Down Arrow            Decrease playback speed"
    echo ""
    echo "Examples:"
    echo "  hitvid video.mp4"
    echo "  hitvid video.mp4 --mode stream --threads 8"
    echo "  hitvid video.mp4 --fps 20 --colors full --scale fill"
    echo ""
    exit 0
}

check_dependencies() {
    for cmd in ffmpeg chafa tput nproc xargs awk; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed. Please install it first." >&2
            exit 1
        fi
    done
}

setup_temp_dir() {
    local temp_base_path="/tmp" # Default
    local use_shm=0
    local temp_dir_attempt=""

    if [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && [ -x "/dev/shm" ]; then
        temp_dir_attempt=$(mktemp -d "/dev/shm/hitvid.XXXXXX" 2>/dev/null)
        if [ -n "$temp_dir_attempt" ] && [ -d "$temp_dir_attempt" ]; then
            TEMP_DIR="$temp_dir_attempt"
            if [ $QUIET -eq 0 ]; then echo "Using tmpfs (/dev/shm) for temporary files: $TEMP_DIR" >&2; fi
            use_shm=1
        else
            if [ $QUIET -eq 0 ]; then echo "Warning: Failed to create temp directory in /dev/shm. Falling back to $temp_base_path." >&2; fi
        fi
    elif [ $QUIET -eq 0 ]; then
        echo "Warning: /dev/shm not available or not writable/executable. Using $temp_base_path for temporary files. Performance might be impacted." >&2
    fi

    if [ $use_shm -eq 0 ]; then
        TEMP_DIR=$(mktemp -d "${temp_base_path}/hitvid.XXXXXX")
    fi

    if [ ! -d "$TEMP_DIR" ]; then
        echo "Error: Failed to create temporary directory." >&2
        exit 1
    fi

    JPG_FRAMES_DIR="$TEMP_DIR/jpg_frames"
    CHAFA_FRAMES_DIR="$TEMP_DIR/chafa_frames"
    mkdir "$JPG_FRAMES_DIR" "$CHAFA_FRAMES_DIR"
    if [ ! -d "$JPG_FRAMES_DIR" ] || [ ! -d "$CHAFA_FRAMES_DIR" ]; then
        echo "Error: Failed to create temporary subdirectories." >&2
        if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
        exit 1
    fi
    trap "cleanup; exit" INT TERM EXIT
}


display_progress_bar() {
    local current_val=$1
    local total_val=$2
    local bar_width=$3
    local prefix_text="${4:-Progress}"
    local bar_char_filled="="
    local bar_char_empty=" "
    local percent=0
    local filled_len=0

    if [ "$total_val" -gt 0 ]; then
        percent=$((current_val * 100 / total_val))
        filled_len=$((current_val * bar_width / total_val))
    else
        percent=0
        filled_len=0
        if [ "$current_val" -eq 0 ] && [ "$total_val" -eq 0 ]; then
             percent=0
        elif [ "$total_val" -le 0 ] && [ "$current_val" -gt 0 ]; then
            percent=100
            filled_len=$bar_width
        fi
    fi

    if [ "$filled_len" -gt "$bar_width" ]; then filled_len=$bar_width; fi
    if [ "$filled_len" -lt 0 ]; then filled_len=0; fi

    local empty_len=$((bar_width - filled_len))

    local bar_str=""
    for ((i=0; i<filled_len; i++)); do bar_str+="$bar_char_filled"; done
    for ((i=0; i<empty_len; i++)); do bar_str+="$bar_char_empty"; done

    printf "%s: [%s] %3d%% (%s/%s)\r" "$prefix_text" "$bar_str" "$percent" "$current_val" "$total_val"
}

get_video_info() {
    if [ $QUIET -eq 0 ]; then echo "Analyzing video file..."; fi
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration,nb_frames -of csv=p=0 "$VIDEO_PATH" 2>/dev/null)
    if [ -z "$VIDEO_INFO" ]; then echo "Error: Could not extract video information." >&2; cleanup; exit 1; fi

    VIDEO_WIDTH=$(echo "$VIDEO_INFO" | cut -d',' -f1)
    VIDEO_HEIGHT=$(echo "$VIDEO_INFO" | cut -d',' -f2)
    VIDEO_DURATION_FLOAT_STR=$(echo "$VIDEO_INFO" | cut -d',' -f3)
    VIDEO_NB_FRAMES_STR=$(echo "$VIDEO_INFO" | cut -d',' -f4)

    VIDEO_DURATION_FLOAT="0"
    if [[ "$VIDEO_DURATION_FLOAT_STR" != "N/A" && "$VIDEO_DURATION_FLOAT_STR" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then
        VIDEO_DURATION_FLOAT="$VIDEO_DURATION_FLOAT_STR"
        VIDEO_DURATION=$(printf "%.0f" "$VIDEO_DURATION_FLOAT")
    else
        VIDEO_DURATION="N/A"
    fi

    if ! [[ "$VIDEO_NB_FRAMES_STR" =~ ^[0-9]+$ ]]; then
        VIDEO_NB_FRAMES_STR="N/A"
    fi

    if [ $QUIET -eq 0 ]; then
        echo "Video resolution: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}, Duration: ${VIDEO_DURATION}s, Total Input Frames: ${VIDEO_NB_FRAMES_STR}"
    fi
}

extract_frames() {
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"
    local progress_file="$TEMP_DIR/ffmpeg_progress.log"
    rm -f "$progress_file"

    local ffmpeg_input_arg="$VIDEO_PATH"
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    local ffmpeg_target_pixel_width=$((WIDTH * CHAR_PIXEL_WIDTH_APPROX))
    local ffmpeg_target_pixel_height=$((HEIGHT * CHAR_PIXEL_HEIGHT_APPROX))
    local scale_vf_option=""

    if [ "$ffmpeg_target_pixel_width" -gt 0 ] && [ "$ffmpeg_target_pixel_height" -gt 0 ]; then
        case "$SCALE_MODE" in
            "fit")
                scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=decrease"
                ;;
            "fill")
                scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=increase,crop=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}"
                ;;
            "stretch")
                scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}"
                ;;
        esac
    fi

    local vf_opts="fps=$ORIGINAL_FPS"
    if [ -n "$scale_vf_option" ]; then
        vf_opts="${vf_opts},${scale_vf_option}"
    fi

    local FFMPEG_EXIT_CODE=0
    if [ $QUIET -eq 0 ]; then
        echo "Extracting frames (this may take a while)..."
        echo "FFmpeg video filter options: $vf_opts"
        ffmpeg -nostdin -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" \
               -progress "$progress_file" > "$ffmpeg_output_file" 2>&1 &
        local ffmpeg_pid=$!

        local last_progress_update_time=$(date +%s%N)
        while ps -p "$ffmpeg_pid" > /dev/null; do
            local current_time=$(date +%s%N)
            if (( (current_time - last_progress_update_time) > 200000000 )); then
                if [ -f "$progress_file" ]; then
                    local current_input_frame_progress=$(grep '^frame=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local current_out_time_us=$(grep '^out_time_us=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local progress_status=$(grep '^progress=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')

                    if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0.0)}"; then
                        local total_duration_us=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * 1000000.0)}")
                        if [[ -n "$current_out_time_us" && "$total_duration_us" -gt 0 ]]; then
                             display_progress_bar "$current_out_time_us" "$total_duration_us" 30 "FFmpeg Extracting (time)"
                        elif [[ -n "$current_input_frame_progress" ]]; then
                            printf "FFmpeg Extracting... Input Frame: %s \r" "${current_input_frame_progress}"
                        else
                            printf "FFmpeg Extracting... \r"
                        fi
                    elif [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then
                        if [[ -n "$current_input_frame_progress" ]]; then
                            display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg Extracting (frames)"
                        else
                            printf "FFmpeg Extracting... \r"
                        fi
                    else
                        if [[ -n "$current_input_frame_progress" ]]; then
                            printf "FFmpeg Extracting... (PID: %s) Input Frame: %s \r" "$ffmpeg_pid" "${current_input_frame_progress:-?}"
                        else
                            printf "FFmpeg Extracting... (PID: %s) \r" "$ffmpeg_pid"
                        fi
                    fi
                    if [[ "$progress_status" == "end" ]]; then break; fi
                fi
                last_progress_update_time=$current_time
            fi
            sleep 0.05
        done
        wait "$ffmpeg_pid"
        FFMPEG_EXIT_CODE=$?

        TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
        local expected_output_frames=0
        if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0.0)}"; then
            expected_output_frames=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * $ORIGINAL_FPS)}")
        fi

        if [ "$expected_output_frames" -le 0 ]; then
            if [ "$TOTAL_FRAMES" -gt 0 ]; then
                expected_output_frames=$TOTAL_FRAMES
            else
                expected_output_frames=1 # Avoid division by zero if no frames
            fi
        fi
        display_progress_bar "$TOTAL_FRAMES" "$expected_output_frames" 30 "FFmpeg Extracted"
        echo
    else
        ffmpeg -nostdin -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" &>/dev/null
        FFMPEG_EXIT_CODE=$?
    fi

    if [ "$FFMPEG_EXIT_CODE" -ne 0 ]; then
        if [ $QUIET -eq 0 ]; then
            echo "Error during ffmpeg extraction. Log:" >&2
            cat "$ffmpeg_output_file" >&2
        else
            echo "Error during ffmpeg extraction. Run without --quiet for details." >&2
        fi
        cleanup; exit 1;
    fi

    TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$TOTAL_FRAMES" -eq 0 ]; then echo "Error: No frames were extracted. Check video file and ffmpeg output." >&2; cleanup; exit 1; fi
    if [ $QUIET -eq 0 ]; then echo "Extracted $TOTAL_FRAMES frames at $ORIGINAL_FPS fps (target)."; fi
}

# This function is called directly and by xargs.
# It relies on CHAFA_OPTS_RENDER, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR being available.
# - As shell variables when called directly.
# - As exported environment variables when called by xargs.
render_single_frame_for_xargs() {
    local frame_jpg_basename="$1"
    local frame_num_str="${frame_jpg_basename%.jpg}"
    local jpg_path="$JPG_FRAMES_DIR/$frame_jpg_basename"
    local txt_path="$CHAFA_FRAMES_DIR/${frame_num_str}.txt"

    if [ ! -f "$jpg_path" ]; then
        return 1
    fi
    chafa $CHAFA_OPTS_RENDER "$jpg_path" > "$txt_path"
    local chafa_status=$?
    return $chafa_status
}
export -f render_single_frame_for_xargs # Export function definition for xargs

render_all_chafa_frames_parallel() {
    if [ $QUIET -eq 0 ]; then
        local mode_msg="Pre-rendering"
        if [ "$PLAY_MODE" == "stream" ]; then
            mode_msg="Starting background Chafa rendering for"
        fi
        echo "$mode_msg $TOTAL_FRAMES Chafa frames using up to $NUM_THREADS threads..."
    fi

    # CHAFA_OPTS_RENDER is already defined globally.
    # Export necessary variables for the subshells spawned by xargs.
    # QUIET is not directly used by render_single_frame_for_xargs, but exporting for consistency if it ever did.
    export CHAFA_OPTS_RENDER JPG_FRAMES_DIR CHAFA_FRAMES_DIR QUIET

    find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -printf "%f\n" | \
        xargs -P "$NUM_THREADS" -I {} bash -c 'render_single_frame_for_xargs "$@"' _ {} &
    local xargs_pid=$!

    if [ "$PLAY_MODE" == "preload" ]; then
        if [ $QUIET -eq 0 ]; then
            local rendered_count=0
            local last_progress_update_time=$(date +%s%N)
            while ps -p "$xargs_pid" > /dev/null; do
                local current_time=$(date +%s%N)
                if (( (current_time - last_progress_update_time) > 200000000 )); then # 200ms
                    rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
                    display_progress_bar "$rendered_count" "$TOTAL_FRAMES" 30 "Chafa Rendering"
                    last_progress_update_time=$current_time
                fi
                sleep 0.05
            done
            rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
            display_progress_bar "$rendered_count" "$TOTAL_FRAMES" 30 "Chafa Rendering"
            echo
        fi
    fi

    wait "$xargs_pid"

    local final_rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')

    if [ "$PLAY_MODE" == "preload" ] && [ $QUIET -eq 0 ]; then
        echo "Parallel Chafa rendering complete. $final_rendered_count frames rendered."
    fi

    if [ "$final_rendered_count" -ne "$TOTAL_FRAMES" ]; then
        echo "Warning: Expected $TOTAL_FRAMES rendered Chafa frames, but found $final_rendered_count." >&2
    fi
}

play_chafa_frames() {
    local current_playback_fps
    local frame_delay
    current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
    frame_delay=$(awk "BEGIN {print 1.0 / $current_playback_fps}")

    local info_line_row
    info_line_row=$(($(tput lines) - 1))

    tput smcup
    tput civis
    clear

    local current_loop=1
    while true; do
        if [ $QUIET -eq 0 ] && [ $LOOP -eq 1 ] && [ $current_loop -gt 1 ]; then
            tput cup "$info_line_row" 0; printf "Starting Loop: %d " "$current_loop"; tput el; sleep 1;
        fi

        local i_seq=1
        while [ "$i_seq" -le "$TOTAL_FRAMES" ]; do
            local frame_start_time_ns=$(date +%s%N)

            if [ $QUIET -eq 0 ]; then
                local key=""
                if read -s -r -N1 -t 0.001 pressed_key; then
                    key="$pressed_key"
                    if [[ "$key" == $'\e' ]]; then
                        if read -s -r -N1 -t 0.001 next_char; then
                            key+="$next_char"
                            if [[ "$next_char" == "[" ]]; then
                                if read -s -r -N1 -t 0.001 final_char; then
                                    key+="$final_char"
                                fi
                            fi
                        fi
                    fi
                fi

                case "$key" in
                    ' ')
                        PAUSED=$((1 - PAUSED))
                        ;;
                    $'\e[A')
                        if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -lt $((${#PLAYBACK_SPEED_MULTIPLIERS[@]} - 1)) ]; then
                            CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX + 1))
                        fi
                        ;;
                    $'\e[B')
                        if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -gt 0 ]; then
                            CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX - 1))
                        fi
                        ;;
                    $'\e[C')
                        local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                        i_seq=$((i_seq + frames_to_skip))
                        if [ "$i_seq" -gt "$TOTAL_FRAMES" ]; then i_seq=$TOTAL_FRAMES; fi
                        ;;
                    $'\e[D')
                        local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                        i_seq=$((i_seq - frames_to_skip))
                        if [ "$i_seq" -lt 1 ]; then i_seq=1; fi
                        ;;
                esac
                current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
                frame_delay=$(awk "BEGIN {print 1.0 / $current_playback_fps}")
            fi

            if [ "$PAUSED" -eq 1 ]; then
                if [ $QUIET -eq 0 ]; then
                    tput cup "$info_line_row" 0
                    printf "[PAUSED] Press Space to resume. Frame %d/%d. Speed: %.2fx" \
                        "$i_seq" "$TOTAL_FRAMES" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
                    tput el
                fi
                sleep 0.1
                continue
            fi

            local frame_num_padded
            frame_num_padded=$(printf "frame-%05d" "$i_seq")
            local chafa_frame_file="$CHAFA_FRAMES_DIR/${frame_num_padded}.txt"

            if [ "$PLAY_MODE" == "stream" ]; then
                local wait_count=0
                while [ ! -f "$chafa_frame_file" ]; do
                    if [[ -n "$RENDER_PID" ]] && ! ps -p "$RENDER_PID" > /dev/null; then
                        if [ ! -f "$chafa_frame_file" ]; then
                           echo -e "\nError: Background renderer (PID $RENDER_PID) died and frame $chafa_frame_file is missing." >&2
                           # cleanup is handled by trap EXIT
                           exit 1
                        fi
                    fi
                    sleep 0.01
                    wait_count=$((wait_count + 1))
                    if [ $QUIET -eq 0 ] && (( wait_count % 20 == 0 )); then # Update every ~200ms
                        tput cup "$info_line_row" 0
                        printf "Playing: Waiting for frame %s/%d (Renderer PID: %s)..." "$frame_num_padded" "$TOTAL_FRAMES" "${RENDER_PID:-N/A}"
                        tput el
                    fi
                    if [ $QUIET -eq 0 ]; then
                        local key_wait=""
                        if read -s -r -N1 -t 0.001 pressed_key_wait; then
                            if [[ "$pressed_key_wait" == ' ' ]]; then PAUSED=1; break; fi
                        fi
                    fi
                done
                if [ "$PAUSED" -eq 1 ]; then continue; fi
            elif [ ! -f "$chafa_frame_file" ]; then
                if [ $QUIET -eq 0 ]; then echo -e "\nError: Frame $chafa_frame_file missing in preload mode." >&2; fi
                sleep "$frame_delay" # Still wait to maintain timing somewhat
                i_seq=$((i_seq + 1))
                continue
            fi

            cat "$chafa_frame_file"

            if [ $QUIET -eq 0 ]; then
                tput cup "$info_line_row" 0
                local bar_width_chars=20
                if [ "$(tput cols)" -gt 60 ]; then bar_width_chars=30; fi
                if [ "$(tput cols)" -gt 90 ]; then bar_width_chars=40; fi

                local percent_done_val=0; local filled_width_chars=0; local empty_width_chars=$bar_width_chars;
                if [ "$TOTAL_FRAMES" -gt 0 ]; then
                    percent_done_val=$((i_seq * 100 / TOTAL_FRAMES))
                    filled_width_chars=$((i_seq * bar_width_chars / TOTAL_FRAMES))
                    if [ "$filled_width_chars" -gt "$bar_width_chars" ]; then filled_width_chars=$bar_width_chars; fi
                    if [ "$filled_width_chars" -lt 0 ]; then filled_width_chars=0; fi
                    empty_width_chars=$((bar_width_chars - filled_width_chars))
                fi
                
                printf "["
                printf "%${filled_width_chars}s" "" | tr ' ' '='
                printf "%${empty_width_chars}s" "" | tr ' ' ' '
                printf "] %d/%d (%d%%)" "$i_seq" "$TOTAL_FRAMES" "$percent_done_val"

                printf " | Speed: %.2fx" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
                if [ $LOOP -eq 1 ]; then printf " | Loop %d" "$current_loop"; fi
                tput el
            fi

            local frame_end_time_ns=$(date +%s%N)
            local processing_time_ns=$((frame_end_time_ns - frame_start_time_ns))
            local sleep_duration_s=$(awk "BEGIN {sd = $frame_delay - ($processing_time_ns / 1000000000.0); if (sd < 0) sd = 0; print sd}")
            sleep "$sleep_duration_s"

            i_seq=$((i_seq + 1))
        done

        if [ $LOOP -eq 0 ]; then break; fi
        current_loop=$((current_loop + 1))
        PAUSED=0
    done

    if [ $QUIET -eq 0 ]; then tput cup "$info_line_row" 0; tput el; echo -e "\nPlayback complete."; fi
}

# --- Argument Parsing ---
if [ $# -eq 0 ]; then show_help; fi
VIDEO_PATH=""
USER_FPS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -f|--fps) USER_FPS="$2"; FPS="$2"; shift 2 ;;
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
            else echo "Error: Unknown option $1" >&2; show_help; fi ;;
    esac
done

# --- Validate Inputs ---
if [ -z "$VIDEO_PATH" ]; then echo "Error: No video file specified." >&2; show_help; fi
if [[ "$VIDEO_PATH" != http* && "$VIDEO_PATH" != ftp* && "$VIDEO_PATH" != rtmp* && "$VIDEO_PATH" != "-" ]]; then
    if [ ! -f "$VIDEO_PATH" ]; then echo "Error: Video file '$VIDEO_PATH' not found." >&2; exit 1; fi
fi

if ! [[ "$FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk "BEGIN {exit !($FPS > 0)}"; then echo "Error: FPS must be a positive number." >&2; exit 1; fi
MAX_FPS=60; if awk "BEGIN {exit !($FPS > $MAX_FPS)}"; then echo "Warning: FPS $FPS is high for extraction, capping at $MAX_FPS." >&2; FPS=$MAX_FPS; fi
ORIGINAL_FPS=$FPS

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
setup_temp_dir # TEMP_DIR, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR are set here

get_video_info
extract_frames # TOTAL_FRAMES is set here

# Define CHAFA_OPTS_RENDER once, used by both direct call and xargs (via export)
CHAFA_OPTS_RENDER="--clear --size=${WIDTH}x${HEIGHT} --colors=$COLORS --dither=$DITHER"
case $SCALE_MODE in
    "fill") CHAFA_OPTS_RENDER+=" --zoom";;
    "stretch") CHAFA_OPTS_RENDER+=" --stretch";;
esac
case $SYMBOLS in
    "block") CHAFA_OPTS_RENDER+=" --symbols=block";;
    "ascii") CHAFA_OPTS_RENDER+=" --symbols=ascii";;
    "space") CHAFA_OPTS_RENDER+=" --symbols=space";;
esac

RENDER_PID=""

if [ "$PLAY_MODE" == "preload" ]; then
    render_all_chafa_frames_parallel
    play_chafa_frames
elif [ "$PLAY_MODE" == "stream" ]; then
    if [ $QUIET -eq 0 ]; then
        echo "Pre-rendering first frame for faster startup..."
    fi
    
    # Find the first extracted JPG frame. -r for xargs means do not run if input is empty.
    # 2>/dev/null suppresses errors if JPG_FRAMES_DIR is empty or ls fails.
    first_jpg_basename=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -print0 2>/dev/null | xargs -0 -r ls -1tr 2>/dev/null | head -n 1 | xargs basename 2>/dev/null)

    if [ -n "$first_jpg_basename" ] && [ -f "$JPG_FRAMES_DIR/$first_jpg_basename" ]; then
        # render_single_frame_for_xargs uses global CHAFA_OPTS_RENDER, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR
        render_single_frame_for_xargs "$first_jpg_basename"
        if [ $QUIET -eq 0 ]; then echo "First frame pre-rendered."; fi
    else
        if [ $QUIET -eq 0 ]; then
            # This specific check for TOTAL_FRAMES is a bit redundant due to earlier exit, but safe.
            if [ "$TOTAL_FRAMES" -eq 0 ]; then
                 echo "Warning: No frames were extracted. Cannot pre-render first frame." >&2
            else
                 echo "Warning: Could not find/pre-render first JPG frame ('${first_jpg_basename:-not found}'). Startup might be slow." >&2
            fi
        fi
    fi

    render_all_chafa_frames_parallel &
    RENDER_PID=$!
    
    # Message about background rendering PID is now part of render_all_chafa_frames_parallel if not quiet.
    # If an explicit message is desired here:
    # if [ $QUIET -eq 0 ]; then
    #    echo "Background rendering process for remaining frames started (PID: $RENDER_PID)."
    # fi

    play_chafa_frames

    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "Waiting for any remaining background rendering (PID: $RENDER_PID) to complete..."; fi
        wait "$RENDER_PID"
        if [ $QUIET -eq 0 ]; then echo "Background rendering fully complete."; fi
    elif [ $QUIET -eq 0 ]; then
        echo "Background rendering already completed."
    fi
    RENDER_PID=""
fi

exit 0