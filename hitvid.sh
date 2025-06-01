#!/bin/bash

# hitvid v1.1.0 - A terminal-based video player using chafa
# Author: Hitmux
# Description: Play videos in terminal using chafa for rendering frames

# Default settings
FPS=15
SCALE_MODE="fit"
COLORS="256"
DITHER="ordered"
SYMBOLS="block"
WIDTH=$(tput cols)
HEIGHT=$(($(tput lines) - 2)) # Reserve 1 line for info, 1 for safety/prompt
QUIET=0
LOOP=0
PLAY_MODE="stream" # "preload" or "stream" (true stream)
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

# PIDs for background processes
FFMPEG_PID=""
CHAFA_RENDER_DAEMON_PID=""
# EXPECTED_TOTAL_FRAMES will be calculated in get_video_info
EXPECTED_TOTAL_FRAMES=0
FFMPEG_MONITOR_PID="" # PID for the FFmpeg monitoring subshell

cleanup() {
    stty sane # Restore terminal settings to a known good state
    tput cnorm # Restore cursor
    tput rmcup # Restore normal screen buffer

    local show_cleanup_messages=$QUIET 

    if [ $show_cleanup_messages -eq 0 ]; then echo -e "\nCleaning up..." >&2; fi

    if [[ -n "$FFMPEG_MONITOR_PID" ]] && ps -p "$FFMPEG_MONITOR_PID" > /dev/null; then
        if [ $show_cleanup_messages -eq 0 ]; then echo "Terminating FFmpeg monitor $FFMPEG_MONITOR_PID..." >&2; fi
        kill "$FFMPEG_MONITOR_PID" 2>/dev/null
        wait "$FFMPEG_MONITOR_PID" 2>/dev/null # Wait for it to exit
    fi
    FFMPEG_MONITOR_PID=""

    if [[ -n "$CHAFA_RENDER_DAEMON_PID" ]] && ps -p "$CHAFA_RENDER_DAEMON_PID" > /dev/null; then
        if [ $show_cleanup_messages -eq 0 ]; then echo "Terminating Chafa render daemon $CHAFA_RENDER_DAEMON_PID..." >&2; fi
        kill "$CHAFA_RENDER_DAEMON_PID" 2>/dev/null
        sleep 0.2
        if ps -p "$CHAFA_RENDER_DAEMON_PID" > /dev/null; then
            if [ $show_cleanup_messages -eq 0 ]; then echo "Force terminating Chafa render daemon $CHAFA_RENDER_DAEMON_PID..." >&2; fi
            kill -9 "$CHAFA_RENDER_DAEMON_PID" 2>/dev/null
        fi
    fi
    CHAFA_RENDER_DAEMON_PID=""


    if [[ -n "$FFMPEG_PID" ]] && ps -p "$FFMPEG_PID" > /dev/null; then
        if [ $show_cleanup_messages -eq 0 ]; then echo "Terminating FFmpeg process $FFMPEG_PID..." >&2; fi
        kill "$FFMPEG_PID" 2>/dev/null
        sleep 0.2
        if ps -p "$FFMPEG_PID" > /dev/null; then
            if [ $show_cleanup_messages -eq 0 ]; then echo "Force terminating FFmpeg process $FFMPEG_PID..." >&2; fi
            kill -9 "$FFMPEG_PID" 2>/dev/null
        fi
    fi
    FFMPEG_PID=""

    if [ -d "$TEMP_DIR" ]; then
        if [ $show_cleanup_messages -eq 0 ]; then echo "Removing temporary directory $TEMP_DIR..." >&2; fi
        rm -rf "$TEMP_DIR"
    fi
    if [ $show_cleanup_messages -eq 0 ]; then echo "Cleanup complete." >&2; fi
}

show_help() {
    echo "hitvid - Terminal-based video player using chafa"
    echo ""
    echo "Usage: hitvid [VIDEO_PATH] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help message"
    echo "  -f, --fps FPS         Set extraction frames per second (default: 15)"
    echo "  -s, --scale MODE      Set scaling mode: fit, fill, stretch (default: $SCALE_MODE)"
    echo "  -c, --colors NUM      Set color mode: 2, 16, 256, full (default: $COLORS)"
    echo "  -d, --dither MODE     Set dither mode: none, ordered, diffusion (default: $DITHER)"
    echo "  -y, --symbols SET     Set symbol set: block, ascii, space (default: $SYMBOLS)"
    echo "  -w, --width WIDTH     Set display width (default: terminal width)"
    echo "  -t, --height HEIGHT   Set display height (default: terminal height - 2 lines)"
    echo "  -m, --mode MODE       Playback mode: preload, stream (default: $PLAY_MODE)"
    echo "      --threads N       Number of parallel threads for Chafa rendering (default: $NUM_THREADS)"
    echo "  -q, --quiet           Suppress loading progress bars. Errors and warnings are still shown."
    echo "  -l, --loop            Loop playback"
    echo ""
    echo "Interactive Controls (during playback):"
    echo "  Spacebar              Pause/Resume"
    echo "  Right Arrow           Seek forward $SEEK_SECONDS seconds"
    echo "  Left Arrow            Seek backward $SEEK_SECONDS seconds"
    echo "  Up Arrow              Increase playback speed"
    echo "  Down Arrow            Decrease playback speed"
    echo "  Ctrl+C                Quit"
    echo ""
    echo "Examples:"
    echo "  hitvid video.mp4"
    echo "  hitvid video.mp4 --mode stream --threads 8"
    echo "  hitvid video.mp4 --fps 20 --colors full --scale fill"
    echo ""
    exit 0
}

check_dependencies() {
    for cmd in ffmpeg ffprobe chafa tput nproc xargs awk bc grep; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed. Please install it first." >&2
            exit 1
        fi
    done
}

setup_temp_dir() {
    local temp_base_path="/tmp"
    local use_shm=0
    local temp_dir_attempt=""

    if [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && [ -x "/dev/shm" ]; then
        temp_dir_attempt=$(mktemp -d "/dev/shm/hitvid.XXXXXX" 2>/dev/null)
        if [ -n "$temp_dir_attempt" ] && [ -d "$temp_dir_attempt" ]; then
            TEMP_DIR="$temp_dir_attempt"
            use_shm=1
        else
            echo "Warning: Failed to create temp directory in /dev/shm. Falling back to $temp_base_path." >&2;
        fi
    elif [ $QUIET -eq 0 ]; then 
        echo "Info: /dev/shm not available or not writable/executable. Using $temp_base_path for temporary files. Performance might be impacted." >&2
    fi

    if [ $use_shm -eq 0 ]; then
        TEMP_DIR=$(mktemp -d "${temp_base_path}/hitvid.XXXXXX")
    fi

    if [ ! -d "$TEMP_DIR" ]; then echo "Error: Failed to create temporary directory." >&2; exit 1; fi

    JPG_FRAMES_DIR="$TEMP_DIR/jpg_frames"
    CHAFA_FRAMES_DIR="$TEMP_DIR/chafa_frames"
    mkdir -p "$JPG_FRAMES_DIR" "$CHAFA_FRAMES_DIR"
    if [ ! -d "$JPG_FRAMES_DIR" ] || [ ! -d "$CHAFA_FRAMES_DIR" ]; then
        echo "Error: Failed to create temporary subdirectories." >&2
        if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
        exit 1
    fi
    # The trap is crucial. Ensure it's set up to call cleanup.
    # The 'exit 1' in trap ensures that if the script is killed, it exits with an error code.
    trap 'cleanup; exit 130' INT # 130 is typical for Ctrl+C
    trap 'cleanup; exit 1' TERM EXIT
}

display_progress_bar() {
    # This function is now only called by preload_frames or the initial phase of stream mode.
    # It should not be called by the ffmpeg_monitor_subshell during active playback.
    if [ $QUIET -eq 1 ]; then return; fi 

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
        if [ "$current_val" -gt 0 ]; then
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

    # Ensure this prints to a consistent place, not interfering with playback info line
    # For preload, this is fine as it's before tput smcup.
    # For initial stream, we need to be careful.
    printf "%s: [%s] %3d%% (%s/%s)\r" "$prefix_text" "$bar_str" "$percent" "$current_val" "$total_val"
}

get_video_info() {
    VIDEO_INFO_RAW=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,duration,nb_frames,r_frame_rate \
        -of csv=p=0 "$VIDEO_PATH" 2>/dev/null)

    VIDEO_DURATION_DECIMAL_STR=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_PATH" 2>/dev/null)

    if [ -z "$VIDEO_INFO_RAW" ]; then echo "Error: Could not extract video stream information from '$VIDEO_PATH'." >&2; exit 1; fi
    
    if [ -z "$VIDEO_DURATION_DECIMAL_STR" ] || [[ "$VIDEO_DURATION_DECIMAL_STR" == "N/A" ]]; then
        VIDEO_DURATION_DECIMAL_STR=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f3)
    fi

    VIDEO_WIDTH_ORIG=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f1) 
    VIDEO_HEIGHT_ORIG=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f2) 
    VIDEO_DURATION_STREAM_STR=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f3)
    VIDEO_NB_FRAMES_STR=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f4)
    VIDEO_R_FRAME_RATE_STR=$(echo "$VIDEO_INFO_RAW" | cut -d',' -f5)

    VIDEO_DURATION_FLOAT="0"
    if [[ "$VIDEO_DURATION_DECIMAL_STR" != "N/A" ]]; then
        if echo "$VIDEO_DURATION_DECIMAL_STR" | grep -Eq '^[0-9]+(\.[0-9]*)?$'; then
            VIDEO_DURATION_FLOAT="$VIDEO_DURATION_DECIMAL_STR"
        elif echo "$VIDEO_DURATION_DECIMAL_STR" | grep -q '/'; then
            VIDEO_DURATION_FLOAT=$(awk "BEGIN {print $VIDEO_DURATION_DECIMAL_STR}" 2>/dev/null)
        fi
    fi
    
    if ! awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0)}"; then
        if [[ "$VIDEO_DURATION_STREAM_STR" != "N/A" ]]; then
            if echo "$VIDEO_DURATION_STREAM_STR" | grep -Eq '^[0-9]+(\.[0-9]*)?$'; then
                VIDEO_DURATION_FLOAT="$VIDEO_DURATION_STREAM_STR"
            elif echo "$VIDEO_DURATION_STREAM_STR" | grep -q '/'; then
                VIDEO_DURATION_FLOAT=$(awk "BEGIN {print $VIDEO_DURATION_STREAM_STR}" 2>/dev/null)
            fi
        fi
    fi
    
    if ! echo "$VIDEO_DURATION_FLOAT" | grep -Eq '^[0-9]+(\.[0-9]*)?$'; then
        VIDEO_DURATION_FLOAT="0"
    fi

    VIDEO_DURATION=$(printf "%.0f" "$VIDEO_DURATION_FLOAT" 2>/dev/null || echo "N/A")

    if ! [[ "$VIDEO_NB_FRAMES_STR" =~ ^[0-9]+$ ]]; then
        VIDEO_NB_FRAMES_STR="N/A"
    fi
    
    if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0)}"; then
        EXPECTED_TOTAL_FRAMES=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * $ORIGINAL_FPS)}")
    elif [[ "$VIDEO_NB_FRAMES_STR" != "N/A" ]] && [[ "$VIDEO_R_FRAME_RATE_STR" != "N/A" ]]; then
        local video_fps_decimal_calc="0"
        if echo "$VIDEO_R_FRAME_RATE_STR" | grep -q '/'; then
            video_fps_decimal_calc=$(awk "BEGIN {print $VIDEO_R_FRAME_RATE_STR}" 2>/dev/null)
        elif echo "$VIDEO_R_FRAME_RATE_STR" | grep -Eq '^[0-9]+(\.[0-9]*)?$'; then
            video_fps_decimal_calc="$VIDEO_R_FRAME_RATE_STR"
        fi

        if awk "BEGIN {exit !($video_fps_decimal_calc > 0)}"; then
            local estimated_duration_from_frames=$(awk "BEGIN {print $VIDEO_NB_FRAMES_STR / $video_fps_decimal_calc}")
            EXPECTED_TOTAL_FRAMES=$(awk "BEGIN {print int($estimated_duration_from_frames * $ORIGINAL_FPS)}")
            if [ $QUIET -eq 0 ]; then echo "Info: Video duration N/A or invalid. Estimated from frame count and rate for frame calculation." >&2; fi
        else
            EXPECTED_TOTAL_FRAMES=0
        fi
    else
        EXPECTED_TOTAL_FRAMES=0
    fi

    if [ "$EXPECTED_TOTAL_FRAMES" -le 0 ]; then
        echo "Error: Could not determine expected total frames for processing. Video duration or frame count might be missing/invalid, or target FPS is too low." >&2
        echo "Debug Info: VIDEO_DURATION_FLOAT='$VIDEO_DURATION_FLOAT', VIDEO_DURATION_DECIMAL_STR='$VIDEO_DURATION_DECIMAL_STR', VIDEO_DURATION_STREAM_STR='$VIDEO_DURATION_STREAM_STR', VIDEO_NB_FRAMES_STR='$VIDEO_NB_FRAMES_STR', VIDEO_R_FRAME_RATE_STR='$VIDEO_R_FRAME_RATE_STR', ORIGINAL_FPS='$ORIGINAL_FPS'" >&2
        exit 1
    fi
}

# This subshell monitors FFmpeg's health and logs errors.
# It does NOT print progress bars to the terminal during stream mode playback.
ffmpeg_monitor_subshell() {
    local monitored_ffmpeg_pid=$1
    local ffmpeg_log_file=$2
    local progress_log_file=$3 # For stream mode initial loading, if desired
    local show_initial_progress_bar=$4 # 1 for yes, 0 for no

    # This trap is for the monitor subshell itself
    trap '' INT TERM # Prevent this subshell from being killed directly by Ctrl+C meant for main

    local last_progress_update_time=$(date +%s%N)
    while ps -p "$monitored_ffmpeg_pid" > /dev/null; do
        if [ "$show_initial_progress_bar" -eq 1 ] && [ $QUIET -eq 0 ]; then
            local current_time=$(date +%s%N)
            if (( (current_time - last_progress_update_time) > 500000000 )); then
                if [ -f "$progress_log_file" ]; then
                    local current_input_frame_progress=$(grep '^frame=' "$progress_log_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local current_out_time_us=$(grep '^out_time_us=' "$progress_log_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local progress_status=$(grep '^progress=' "$progress_log_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')

                    # This display_progress_bar call is for the *initial* loading phase of stream mode
                    # It should happen *before* play_chafa_frames takes over the screen.
                    if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0.0)}"; then
                        local total_duration_us=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * 1000000.0)}")
                        if [[ -n "$current_out_time_us" && "$total_duration_us" -gt 0 ]]; then
                             display_progress_bar "$current_out_time_us" "$total_duration_us" 30 "FFmpeg Extracting (time)"
                        elif [[ -n "$current_input_frame_progress" ]]; then
                             if [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then
                                 display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg Extracting (frames)"
                             else
                                 printf "\rFFmpeg Extracting... Input Frame: %s " "${current_input_frame_progress}" 
                             fi
                        fi
                    elif [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then
                         if [[ -n "$current_input_frame_progress" ]]; then
                            display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg Extracting (frames)"
                         fi
                    elif [[ -n "$current_input_frame_progress" ]]; then 
                            printf "\rFFmpeg Extracting... Input Frame: %s " "${current_input_frame_progress:-?}"
                    fi
                    if [[ "$progress_status" == "end" ]]; then 
                        if [ $QUIET -eq 0 ]; then printf "\n"; fi 
                        # Once FFmpeg reports 'end', this monitor should stop showing progress bar
                        # even if FFmpeg process lingers for a bit.
                        show_initial_progress_bar=0 
                    fi
                fi
                last_progress_update_time=$current_time
            fi
        fi
        sleep 0.1
    done
    
    # Wait for the specific FFmpeg PID it was asked to monitor
    wait "$monitored_ffmpeg_pid" 2>/dev/null 
    local FFMPEG_EXIT_CODE_MONITOR=$?

    # Clear any lingering progress bar line if it was shown
    if [ "$show_initial_progress_bar" -eq 1 ] && [ $QUIET -eq 0 ]; then
        printf "\r%*s\r" "$(tput cols)" "" 
    fi

    if [ "$FFMPEG_EXIT_CODE_MONITOR" -ne 0 ]; then
        # Check if the log file has content (actual errors)
        if [ -s "$ffmpeg_log_file" ]; then
            echo "Error: FFmpeg (PID $monitored_ffmpeg_pid from monitor) exited with code $FFMPEG_EXIT_CODE_MONITOR. Log:" >&2
            cat "$ffmpeg_log_file" >&2
        elif [ "$FFMPEG_EXIT_CODE_MONITOR" -ne 130 ] && [ "$FFMPEG_EXIT_CODE_MONITOR" -ne 143 ]; then # 130=INT, 143=TERM
             # If no log content but still an error code (not from typical signals), mention it.
            echo "Error: FFmpeg (PID $monitored_ffmpeg_pid from monitor) exited with code $FFMPEG_EXIT_CODE_MONITOR (no specific error in log)." >&2
        fi
    fi
}


extract_frames_daemon() {
    local expected_frames_count=$1
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"
    local progress_file="$TEMP_DIR/ffmpeg_progress.log"
    rm -f "$progress_file" "$ffmpeg_output_file" # Clear previous logs

    local ffmpeg_input_arg="$VIDEO_PATH"
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    local ffmpeg_target_pixel_width=$((WIDTH * CHAR_PIXEL_WIDTH_APPROX))
    local ffmpeg_target_pixel_height=$((HEIGHT * CHAR_PIXEL_HEIGHT_APPROX))
    local scale_vf_option=""

    if [ "$ffmpeg_target_pixel_width" -gt 0 ] && [ "$ffmpeg_target_pixel_height" -gt 0 ]; then
        case "$SCALE_MODE" in
            "fit") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=decrease";;
            "fill") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=increase,crop=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}";;
            "stretch") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}";;
        esac
    fi

    local vf_opts="fps=$ORIGINAL_FPS"
    if [ -n "$scale_vf_option" ]; then vf_opts="${vf_opts},${scale_vf_option}"; fi

    # FFmpeg now logs only errors to $ffmpeg_output_file
    # The -progress flag is still useful for the initial loading bar
    ffmpeg -nostdin -hide_banner -loglevel error -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" \
           -progress "$progress_file" > "$ffmpeg_output_file" 2>&1 &
    FFMPEG_PID=$!
    
    # Start the monitor subshell.
    # For stream mode, the 'show_initial_progress_bar' is 1 initially.
    # The monitor subshell itself will turn it off once ffmpeg progress reports 'end'.
    ffmpeg_monitor_subshell "$FFMPEG_PID" "$ffmpeg_output_file" "$progress_file" 1 &
    FFMPEG_MONITOR_PID=$!
}

render_chafa_daemon() {
    local expected_total_frames=$1
    local parent_ffmpeg_pid_arg=$2
    
    ( 
        declare -a chafa_pids_local=()
        _cleanup_chafa_workers_daemon() {
            for pid_worker in "${chafa_pids_local[@]}"; do
                if ps -p "$pid_worker" > /dev/null; then kill "$pid_worker" 2>/dev/null; fi
            done
            sleep 0.1 
            for pid_worker in "${chafa_pids_local[@]}"; do
                if ps -p "$pid_worker" > /dev/null; then kill -9 "$pid_worker" 2>/dev/null; fi
            done
            chafa_pids_local=()
        }
        trap _cleanup_chafa_workers_daemon EXIT TERM INT

        local rendered_count=0
        local current_frame_to_render=1
        local active_chafa_jobs=0

        while [ "$current_frame_to_render" -le "$expected_total_frames" ]; do
            local jpg_frame_basename=$(printf "frame-%05d.jpg" "$current_frame_to_render")
            local jpg_file_path="$JPG_FRAMES_DIR/$jpg_frame_basename"
            local txt_frame_basename=$(printf "frame-%05d.txt" "$current_frame_to_render")
            local txt_file_path="$CHAFA_FRAMES_DIR/$txt_frame_basename"

            local jpg_wait_start_time=$(date +%s)
            while [ ! -f "$jpg_file_path" ]; do
                # Check if the main FFMPEG_PID (the one Chafa daemon cares about) is still alive
                if ! ps -p "$parent_ffmpeg_pid_arg" > /dev/null; then
                    if [ ! -f "$jpg_file_path" ]; then 
                         echo "Warning: ChafaDaemon: FFmpeg (PID $parent_ffmpeg_pid_arg) died, and $jpg_file_path not found. Assuming end of input for frame $current_frame_to_render." >&2
                    fi
                    current_frame_to_render=$((expected_total_frames + 1)) 
                    break 
                fi
                sleep 0.01
                if [ $(( $(date +%s) - jpg_wait_start_time )) -gt 15 ]; then 
                    echo "Warning: ChafaDaemon: Waited >15s for $jpg_file_path. FFmpeg PID $parent_ffmpeg_pid_arg still active? Check FFmpeg logs." >&2
                    jpg_wait_start_time=$(date +%s) 
                fi
            done
            
            if [ "$current_frame_to_render" -gt "$expected_total_frames" ]; then break; fi
            if [ ! -f "$jpg_file_path" ]; then 
                echo "Warning: ChafaDaemon: $jpg_file_path did not appear after wait. Stopping." >&2;
                break
            fi

            while [ "$active_chafa_jobs" -ge "$NUM_THREADS" ]; do
                local found_finished_worker=0
                for i in "${!chafa_pids_local[@]}"; do
                    local pid_to_check="${chafa_pids_local[$i]}"
                    if ! ps -p "$pid_to_check" > /dev/null; then
                        wait "$pid_to_check" 2>/dev/null 
                        unset 'chafa_pids_local[i]'
                        active_chafa_jobs=$((active_chafa_jobs - 1))
                        rendered_count=$((rendered_count + 1))
                        found_finished_worker=1
                        break
                    fi
                done
                if [ "$found_finished_worker" -eq 0 ]; then sleep 0.02; fi
                chafa_pids_local=("${chafa_pids_local[@]}") 
            done

            (chafa $CHAFA_OPTS_RENDER "$jpg_file_path" > "$txt_file_path") &
            chafa_pids_local+=($!)
            active_chafa_jobs=$((active_chafa_jobs + 1))
            current_frame_to_render=$((current_frame_to_render + 1))
        done
        
        for pid_to_wait in "${chafa_pids_local[@]}"; do
            wait "$pid_to_wait" 2>/dev/null
            rendered_count=$((rendered_count + 1))
        done
        chafa_pids_local=()
    ) &
    CHAFA_RENDER_DAEMON_PID=$!
}

preload_frames() {
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"
    local progress_file="$TEMP_DIR/ffmpeg_progress.log"
    rm -f "$progress_file" "$ffmpeg_output_file"

    local ffmpeg_input_arg="$VIDEO_PATH"
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    local ffmpeg_target_pixel_width=$((WIDTH * CHAR_PIXEL_WIDTH_APPROX))
    local ffmpeg_target_pixel_height=$((HEIGHT * CHAR_PIXEL_HEIGHT_APPROX))
    local scale_vf_option=""

    if [ "$ffmpeg_target_pixel_width" -gt 0 ] && [ "$ffmpeg_target_pixel_height" -gt 0 ]; then
        case "$SCALE_MODE" in
            "fit") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=decrease";;
            "fill") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}:force_original_aspect_ratio=increase,crop=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}";;
            "stretch") scale_vf_option="scale=${ffmpeg_target_pixel_width}:${ffmpeg_target_pixel_height}";;
        esac
    fi
    local vf_opts="fps=$ORIGINAL_FPS"
    if [ -n "$scale_vf_option" ]; then vf_opts="${vf_opts},${scale_vf_option}"; fi

    local FFMPEG_EXIT_CODE_PRELOAD=0

    if [ $QUIET -eq 0 ]; then 
        ffmpeg -nostdin -hide_banner -loglevel error -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" \
               -progress "$progress_file" > "$ffmpeg_output_file" 2>&1 &
        local ffmpeg_pid_preload=$!
        
        local last_progress_update_time=$(date +%s%N)
        while ps -p "$ffmpeg_pid_preload" > /dev/null; do
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
                             if [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then
                                 display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg Extracting (frames)"
                             else
                                 printf "FFmpeg Extracting... Input Frame: %s \r" "${current_input_frame_progress}"
                             fi
                        fi
                    elif [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then
                        if [[ -n "$current_input_frame_progress" ]]; then
                            display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg Extracting (frames)"
                        fi
                    elif [[ -n "$current_input_frame_progress" ]]; then
                            printf "FFmpeg Extracting... Input Frame: %s \r" "${current_input_frame_progress:-?}"
                    fi
                    if [[ "$progress_status" == "end" ]]; then break; fi
                fi
                last_progress_update_time=$current_time
            fi
            sleep 0.05
        done
        wait "$ffmpeg_pid_preload"
        FFMPEG_EXIT_CODE_PRELOAD=$?
        
        local actual_total_frames_preload=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
        local display_total_ffmpeg=$EXPECTED_TOTAL_FRAMES
        if [ "$actual_total_frames_preload" -gt "$EXPECTED_TOTAL_FRAMES" ] || [ "$EXPECTED_TOTAL_FRAMES" -eq 0 ]; then
            display_total_ffmpeg=$actual_total_frames_preload
        fi
        # Ensure progress bar is cleared before next output
        display_progress_bar "$actual_total_frames_preload" "$display_total_ffmpeg" 30 "FFmpeg Extracted"
        echo 
    else 
        ffmpeg -nostdin -hide_banner -loglevel error -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" > "$ffmpeg_output_file" 2>&1
        FFMPEG_EXIT_CODE_PRELOAD=$?
    fi

    if [ "$FFMPEG_EXIT_CODE_PRELOAD" -ne 0 ]; then
        if [ -s "$ffmpeg_output_file" ]; then # Check if log has content
            echo "Error during ffmpeg extraction (preload). Log:" >&2; cat "$ffmpeg_output_file" >&2;
        else
            echo "Error during ffmpeg extraction (preload), exit code $FFMPEG_EXIT_CODE_PRELOAD (no specific error in log)." >&2
        fi
        exit 1;
    fi

    local actual_total_frames_preload=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$actual_total_frames_preload" -eq 0 ]; then echo "Error: No frames were extracted in preload mode." >&2; exit 1; fi
    
    EXPECTED_TOTAL_FRAMES=$actual_total_frames_preload
    
    _render_single_frame_for_xargs_preload() {
        local frame_jpg_basename_arg="$1"
        local frame_num_str_arg="${frame_jpg_basename_arg%.jpg}"
        local jpg_path_arg="$JPG_FRAMES_DIR/$frame_jpg_basename_arg"
        local txt_path_arg="$CHAFA_FRAMES_DIR/${frame_num_str_arg}.txt"
        if [ ! -f "$jpg_path_arg" ]; then return 1; fi
        # Chafa errors will go to its stderr, which should be visible if any.
        chafa $CHAFA_OPTS_RENDER "$jpg_path_arg" > "$txt_path_arg"
        return $?
    }
    export -f _render_single_frame_for_xargs_preload

    find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -printf "%f\n" | \
        xargs -P "$NUM_THREADS" -I {} bash -c '_render_single_frame_for_xargs_preload "$@"' _ {} &
    local xargs_pid_preload=$!

    if [ $QUIET -eq 0 ]; then 
        local rendered_count_preload_chafa=0
        local last_progress_update_time_chafa=$(date +%s%N)
        while ps -p "$xargs_pid_preload" > /dev/null; do
            local current_time_chafa=$(date +%s%N)
            if (( (current_time_chafa - last_progress_update_time_chafa) > 200000000 )); then
                rendered_count_preload_chafa=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
                display_progress_bar "$rendered_count_preload_chafa" "$EXPECTED_TOTAL_FRAMES" 30 "Chafa Rendering"
                last_progress_update_time_chafa=$current_time_chafa
            fi
            sleep 0.05
        done
        rendered_count_preload_chafa=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
        display_progress_bar "$rendered_count_preload_chafa" "$EXPECTED_TOTAL_FRAMES" 30 "Chafa Rendering"
        echo 
    else 
        wait "$xargs_pid_preload"
    fi
    
    local final_rendered_count_preload=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$final_rendered_count_preload" -ne "$EXPECTED_TOTAL_FRAMES" ]; then
        echo "Warning (Preload): Expected $EXPECTED_TOTAL_FRAMES rendered Chafa frames, but found $final_rendered_count_preload." >&2
    fi
}


play_chafa_frames() {
    local total_frames_to_play=$1
    local current_playback_fps
    local frame_delay

    current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
    frame_delay=$(awk "BEGIN { od = 1.0 / $current_playback_fps; if (od < 0.001) od = 0.001; print od }")

    local info_line_row=$(($(tput lines) - 1))
    
    # Clear screen and switch to alternate buffer *after* any initial loading messages
    if [ $QUIET -eq 0 ] && [ "$PLAY_MODE" == "stream" ]; then
        # Ensure any lingering progress bar from initial ffmpeg load is cleared
        printf "\r%*s\r" "$(tput cols)" "" 
    fi
    tput smcup; tput civis; clear

    local current_loop=1
    local quit_playback=0 
    while true; do
        if [ "$quit_playback" -eq 1 ]; then break; fi

        local i_seq=1
        while [ "$i_seq" -le "$total_frames_to_play" ]; do
            if [ "$quit_playback" -eq 1 ]; then break; fi
            local frame_start_time_ns=$(date +%s%N)

            local key=""
            # Non-blocking read for input
            # The timeout 0.001 is very short, adjust if input feels laggy or CPU usage is high
            if read -s -r -N1 -t 0.001 pressed_key; then
                key="$pressed_key"
                if [[ "$key" == $'\e' ]]; then # Arrow key sequence
                    if read -s -r -N1 -t 0.001 next_char; then
                        key+="$next_char"
                        if [[ "$next_char" == "[" ]]; then
                            if read -s -r -N1 -t 0.001 final_char; then key+="$final_char"; fi
                        fi
                    fi
                fi
            fi

            case "$key" in
                ' ') PAUSED=$((1 - PAUSED)) ;;
                $'\e[A') # Up Arrow
                    if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -lt $((${#PLAYBACK_SPEED_MULTIPLIERS[@]} - 1)) ]; then
                        CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX + 1))
                    fi
                    ;;
                $'\e[B') # Down Arrow
                    if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -gt 0 ]; then
                        CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX - 1))
                    fi
                    ;;
                $'\e[C') # Right Arrow
                    local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                    i_seq=$((i_seq + frames_to_skip))
                    if [ "$i_seq" -gt "$total_frames_to_play" ]; then i_seq=$total_frames_to_play; fi
                    # In stream mode, seeking past available frames might cause a longer wait
                    ;;
                $'\e[D') # Left Arrow
                    local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                    i_seq=$((i_seq - frames_to_skip))
                    if [ "$i_seq" -lt 1 ]; then i_seq=1; fi
                    ;;
            esac
            current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
            frame_delay=$(awk "BEGIN { od = 1.0 / $current_playback_fps; if (od < 0.001) od = 0.001; print od }")


            if [ "$PAUSED" -eq 1 ]; then
                tput cup "$info_line_row" 0
                printf "[PAUSED] %d/%d | Speed: %.2fx | Ctrl+C to quit" \
                    "$i_seq" "$total_frames_to_play" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
                tput el # Erase to end of line
                sleep 0.1 # Reduce CPU usage while paused
                continue
            fi

            local frame_num_padded=$(printf "frame-%05d" "$i_seq")
            local chafa_frame_file="$CHAFA_FRAMES_DIR/${frame_num_padded}.txt"
            
            local wait_count=0
            local max_wait_no_daemon_stream=200 # ~2 seconds
            local max_wait_preload=10           # ~0.1 seconds (should be ready)
            local max_wait_current=$max_wait_preload
            if [ "$PLAY_MODE" == "stream" ]; then max_wait_current=$max_wait_no_daemon_stream; fi

            while [ ! -f "$chafa_frame_file" ]; do
                if [ "$quit_playback" -eq 1 ]; then break; fi 
                local ffmpeg_alive_check=0; if [[ -n "$FFMPEG_PID" ]] && ps -p "$FFMPEG_PID" >/dev/null; then ffmpeg_alive_check=1; fi
                local chafa_daemon_alive_check=0; if [[ -n "$CHAFA_RENDER_DAEMON_PID" ]] && ps -p "$CHAFA_RENDER_DAEMON_PID" >/dev/null; then chafa_daemon_alive_check=1; fi

                if [ "$PLAY_MODE" == "stream" ] && [ "$ffmpeg_alive_check" -eq 0 ] && [ "$chafa_daemon_alive_check" -eq 0 ]; then
                    wait_count=$((wait_count + 1))
                    if [ "$wait_count" -gt "$max_wait_current" ]; then
                        # This is an actual issue, so print warning to stderr (above info line)
                        tput cup "$info_line_row" 0; tput el 
                        echo "Warning: Player: Daemons dead & frame $chafa_frame_file missing after max wait. Skipping." >&2
                        break # Break from while [ ! -f ... ]
                    fi
                elif [ "$PLAY_MODE" == "preload" ] && [ "$wait_count" -gt "$max_wait_current" ]; then
                    tput cup "$info_line_row" 0; tput el
                    echo "Warning: Player: Frame $chafa_frame_file missing (preload) after max wait. Skipping." >&2
                    break # Break from while [ ! -f ... ]
                fi

                sleep 0.01 # Short sleep while waiting for frame
                wait_count=$((wait_count + 1))
                
                # Check for pause input even while waiting for a frame
                if read -s -r -N1 -t 0.001 pressed_key_wait; then
                    if [[ "$pressed_key_wait" == ' ' ]]; then PAUSED=1; break; fi # Break from while [ ! -f ... ]
                fi
            done # End of while [ ! -f "$chafa_frame_file" ]

            if [ "$PAUSED" -eq 1 ] || [ "$quit_playback" -eq 1 ]; then continue; fi # Re-check after breaking from inner wait loop

            if [ -f "$chafa_frame_file" ]; then
                # Output frame content. tput cup 0 0 is implicit with cat if screen was cleared.
                # Chafa output itself should handle positioning if --clear is used.
                cat "$chafa_frame_file"
            else 
                # Frame is missing after wait/checks, print message at top of screen
                tput cup 0 0 ; printf "Frame %s missing, display skipped." "$frame_num_padded" ; tput el 
            fi

            # Always display minimal info bar at the bottom
            tput cup "$info_line_row" 0
            local bar_width_chars=20
            if [ "$(tput cols)" -gt 70 ]; then bar_width_chars=30; fi
            if [ "$(tput cols)" -gt 100 ]; then bar_width_chars=40; fi
            
            local percent_done_val=0; local filled_width_chars=0; local empty_width_chars=$bar_width_chars;
            if [ "$total_frames_to_play" -gt 0 ]; then
                percent_done_val=$((i_seq * 100 / total_frames_to_play))
                filled_width_chars=$((i_seq * bar_width_chars / total_frames_to_play))
                if [ "$filled_width_chars" -gt "$bar_width_chars" ]; then filled_width_chars=$bar_width_chars; fi
                if [ "$filled_width_chars" -lt 0 ]; then filled_width_chars=0; fi
                empty_width_chars=$((bar_width_chars - filled_width_chars))
            fi
            
            printf "["
            printf "%${filled_width_chars}s" "" | tr ' ' '='
            printf "%${empty_width_chars}s" "" | tr ' ' ' '
            printf "] %d/%d (%d%%)" "$i_seq" "$total_frames_to_play" "$percent_done_val"
            printf " | Speed: %.2fx | Ctrl+C to quit" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
            tput el # Erase to end of line
            

            local frame_end_time_ns=$(date +%s%N)
            local processing_time_ns=$((frame_end_time_ns - frame_start_time_ns))
            local sleep_duration_s=$(bc <<< "scale=9; sd = $frame_delay - ($processing_time_ns / 1000000000.0); if (sd < 0) sd = 0; sd")
            
            # Only sleep if duration is positive and significant enough
            if awk "BEGIN {exit !($sleep_duration_s > 0.000001)}"; then
                sleep "$sleep_duration_s"
            fi

            i_seq=$((i_seq + 1))
        done # End of while [ "$i_seq" -le "$total_frames_to_play" ]
        if [ "$quit_playback" -eq 1 ]; then break; fi # Break from outer loop if quit

        if [ $LOOP -eq 0 ]; then break; fi # Break from outer loop if not looping
        current_loop=$((current_loop + 1))
        PAUSED=0 # Reset pause state for next loop iteration
    done # End of while true (outer playback loop)

    tput cup "$info_line_row" 0; tput el # Clear info line on exit from playback
}

# --- Argument Parsing ---
if [ $# -eq 0 ]; then show_help; fi
VIDEO_PATH=""
USER_SET_FPS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -f|--fps) USER_SET_FPS="$2"; FPS="$2"; shift 2 ;; 
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
ORIGINAL_FPS=$FPS
MAX_FPS_CAP=60
if awk "BEGIN {exit !($ORIGINAL_FPS > $MAX_FPS_CAP)}"; then
    echo "Warning: Requested FPS $ORIGINAL_FPS is high for extraction, capping at $MAX_FPS_CAP." >&2
    ORIGINAL_FPS=$MAX_FPS_CAP
fi


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

echo "Mode: $PLAY_MODE, FPS: $ORIGINAL_FPS, Size: ${WIDTH}x${HEIGHT}, Threads: $NUM_THREADS, File: $VIDEO_PATH"

setup_temp_dir # Trap is set inside here

get_video_info 

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
export CHAFA_OPTS_RENDER JPG_FRAMES_DIR CHAFA_FRAMES_DIR VIDEO_DURATION_FLOAT VIDEO_NB_FRAMES_STR # Export vars needed by ffmpeg_monitor_subshell

if [ "$PLAY_MODE" == "preload" ]; then
    preload_frames 
    play_chafa_frames "$EXPECTED_TOTAL_FRAMES"
elif [ "$PLAY_MODE" == "stream" ]; then
    extract_frames_daemon "$EXPECTED_TOTAL_FRAMES" 

    # Wait for the initial FFmpeg progress to finish or for a few seconds
    # This allows the initial progress bar to show before playback starts
    if [ $QUIET -eq 0 ]; then
        local wait_initial_ffmpeg=0
        while ps -p "$FFMPEG_PID" > /dev/null && [ "$wait_initial_ffmpeg" -lt 50 ]; do # Wait up to 5s
             # Check if progress file indicates 'end'
            if [ -f "$TEMP_DIR/ffmpeg_progress.log" ] && grep -q '^progress=end' "$TEMP_DIR/ffmpeg_progress.log"; then
                break
            fi
            sleep 0.1
            wait_initial_ffmpeg=$((wait_initial_ffmpeg + 1))
        done
        # Clear the progress bar line if it was shown by the monitor
        printf "\r%*s\r" "$(tput cols)" "" 
    fi
    
    first_jpg_to_check="$JPG_FRAMES_DIR/frame-00001.jpg"
    first_txt_to_create="$CHAFA_FRAMES_DIR/frame-00001.txt"
    
    local wait_first_jpg_count=0
    while [ ! -f "$first_jpg_to_check" ] && [ "$wait_first_jpg_count" -lt 50 ] && [[ -n "$FFMPEG_PID" ]] && ps -p "$FFMPEG_PID" >/dev/null; do
        sleep 0.01
        wait_first_jpg_count=$((wait_first_jpg_count + 1))
    done

    if [ -f "$first_jpg_to_check" ]; then
        (chafa $CHAFA_OPTS_RENDER "$first_jpg_to_check" > "$first_txt_to_create")
    elif [ $QUIET -eq 0 ]; then 
        echo "Info: Could not pre-render first frame quickly. FFmpeg PID: ${FFMPEG_PID:-N/A}. File: $first_jpg_to_check" >&2
    fi

    render_chafa_daemon "$EXPECTED_TOTAL_FRAMES" "$FFMPEG_PID" 
    
    play_chafa_frames "$EXPECTED_TOTAL_FRAMES"

    # Cleanup will handle killing FFMPEG_MONITOR_PID, FFMPEG_PID, CHAFA_RENDER_DAEMON_PID
fi

# Explicitly call cleanup before exiting normally.
# The trap handles abnormal exits (Ctrl+C, TERM, script error).
cleanup
exit 0
