#!/bin/bash

# hitvid - 基于chafa的终端视频播放器
# 作者: Hitmux
# 描述: 使用chafa在终端中播放视频，渲染帧

# 默认设置
FPS=5 # 设置播放帧率。
SCALE_MODE="fit" # 设置缩放模式: fit (适应), fill (填充), stretch (拉伸)。
COLORS="256" # 设置颜色模式: 2, 16, 256, full (全彩)
DITHER="ordered" # 设置抖动模式: none (无), ordered (有序), diffusion (扩散)。
SYMBOLS="block" # 设置字符集: block (块), ascii (ASCII), space (空格)。
WIDTH=$(tput cols) # 设置显示宽度 (字符数)。
HEIGHT=$(($(tput lines) - 2)) # 为信息预留1行，安全/提示预留1行
QUIET=0 # 静默模式，抑制进度和其他信息输出。
LOOP=0 # 循环播放视频。
PLAY_MODE="stream" # "preload" (预加载) 或 "stream" (流式)
NUM_THREADS=$(nproc --all 2>/dev/null || echo 4) # 如果nproc失败，默认设置为4

# --- 辅助函数 ---
cleanup() {
    # 首先恢复光标并切换回正常屏幕缓冲区
    # 这样任何后续消息如果需要的话会出现在正常屏幕上，
    # 或者如果rmcup是最后一个的话则会隐藏。
    tput cnorm # 恢复光标
    tput rmcup # 恢复正常屏幕缓冲区

    echo "正在清理临时文件..." >&2 # 这现在会出现在正常屏幕上
    # 如果后台渲染进程存在且正在运行，则终止它
    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        echo "正在终止后台渲染进程 $RENDER_PID..." >&2
        kill "$RENDER_PID" 2>/dev/null
        # 稍等片刻，如果仍然存活则强制终止
        sleep 0.5
        if ps -p "$RENDER_PID" > /dev/null; then
            kill -9 "$RENDER_PID" 2>/dev/null
        fi
    fi
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    # 如果我们为xargs创建了fifo，则删除它
    if [ -n "$XARGS_FIFO" ] && [ -p "$XARGS_FIFO" ]; then
        rm -f "$XARGS_FIFO"
    fi
}

# 显示帮助信息的函数
show_help() {
    echo "hitvid - 基于chafa的终端视频播放器"
    echo ""
    echo "用法: hitvid [视频路径] [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help           显示此帮助信息"
    echo "  -f, --fps FPS        设置播放帧率 (默认: $FPS)"
    echo "  -s, --scale MODE     设置缩放模式: fit (适应), fill (填充), stretch (拉伸) (默认: $SCALE_MODE)"
    echo "  -c, --colors NUM     设置颜色模式: 2, 16, 256, full (全彩) (默认: $COLORS)"
    echo "  -d, --dither MODE    设置抖动模式: none (无), ordered (有序), diffusion (扩散) (默认: $DITHER)"
    echo "  -y, --symbols SET    设置字符集: block (块), ascii (ASCII), space (空格) (默认: $SYMBOLS)"
    echo "  -w, --width WIDTH    设置显示宽度 (默认: 终端宽度)"
    echo "  -t, --height HEIGHT  设置显示高度 (默认: 终端高度 - 2行)"
    echo "  -m, --mode MODE      播放模式: preload (预加载), stream (流式) (默认: $PLAY_MODE)"
    echo "    --threads N        Chafa渲染的并行线程数 (默认: $NUM_THREADS)"
    echo "  -q, --quiet          抑制进度信息"
    echo "  -l, --loop           循环播放"
    echo ""
    echo "示例:"
    echo "  hitvid video.mp4"
    echo "  hitvid video.mp4 --mode stream --threads 8"
    echo "  hitvid video.mp4 --fps 20 --colors full --scale fill"
    echo ""
    exit 0
}

# 检查所需工具是否安装的函数
check_dependencies() {
    for cmd in ffmpeg chafa tput nproc xargs; do
        if ! command -v $cmd &> /dev/null; then
            echo "错误: $cmd 未安装。请先安装它。" >&2
            exit 1
        fi
    done
}

# 创建临时目录的函数
setup_temp_dir() {
    TEMP_DIR=$(mktemp -d /tmp/hitvid.XXXXXX)
    if [ ! -d "$TEMP_DIR" ]; then
        echo "错误: 创建临时目录失败。" >&2
        exit 1
    fi
    JPG_FRAMES_DIR="$TEMP_DIR/jpg_frames"
    CHAFA_FRAMES_DIR="$TEMP_DIR/chafa_frames"
    mkdir "$JPG_FRAMES_DIR" "$CHAFA_FRAMES_DIR"
    if [ ! -d "$JPG_FRAMES_DIR" ] || [ ! -d "$CHAFA_FRAMES_DIR" ]; then
        echo "错误: 创建临时子目录失败。" >&2
        cleanup # 尝试清理后退出
        exit 1
    fi
    # 设置捕获以在退出时清理临时文件并恢复光标/屏幕
    trap "cleanup; exit" INT TERM EXIT # EXIT捕获对于正常终止很重要
}

# 提取视频信息的函数
get_video_info() {
    if [ $QUIET -eq 0 ]; then echo "正在分析视频文件..."; fi
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 "$VIDEO_PATH" 2>/dev/null)
    if [ -z "$VIDEO_INFO" ]; then echo "错误: 无法提取视频信息。" >&2; cleanup; exit 1; fi

    VIDEO_WIDTH=$(echo "$VIDEO_INFO" | cut -d',' -f1)
    VIDEO_HEIGHT=$(echo "$VIDEO_INFO" | cut -d',' -f2)
    VIDEO_DURATION_FLOAT=$(echo "$VIDEO_INFO" | cut -d',' -f3)
    if [[ "$VIDEO_DURATION_FLOAT" == "N/A" ]]; then VIDEO_DURATION="N/A"; else VIDEO_DURATION=$(printf "%.0f" "$VIDEO_DURATION_FLOAT"); fi
    if [ $QUIET -eq 0 ]; then echo "视频分辨率: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}, 时长: ${VIDEO_DURATION}秒"; fi
}

# 从视频中提取帧的函数
extract_frames() {
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"

    local ffmpeg_input_arg="$VIDEO_PATH"
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    if [ $QUIET -eq 0 ]; then
        echo "正在提取帧 (这可能需要一些时间)..."
        ffmpeg -i "$ffmpeg_input_arg" -vf "fps=$FPS" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" > "$ffmpeg_output_file" 2>&1
    else
        ffmpeg -i "$ffmpeg_input_arg" -vf "fps=$FPS" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" &>/dev/null
    fi

    if [ $? -ne 0 ]; then
        if [ $QUIET -eq 0 ]; then
            echo "ffmpeg提取过程中发生错误。日志:" >&2
            cat "$ffmpeg_output_file" >&2
        else
            echo "ffmpeg提取过程中发生错误。请运行时不带 --quiet 以获取详细信息。" >&2
        fi
    fi

    TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" | wc -l)
    TOTAL_FRAMES=${TOTAL_FRAMES// /}

    if [ "$TOTAL_FRAMES" -eq 0 ]; then echo "错误: 未提取任何帧。请检查视频文件和ffmpeg输出。" >&2; cleanup; exit 1; fi
    if [ $QUIET -eq 0 ]; then echo "以 $FPS 帧每秒提取了 $TOTAL_FRAMES 帧"; fi
}

# --- Chafa 渲染函数 ---
export CHAFA_OPTS_RENDER JPG_FRAMES_DIR CHAFA_FRAMES_DIR QUIET

render_single_frame_for_xargs() {
    local frame_jpg_basename="$1"
    local frame_num_str="${frame_jpg_basename%.jpg}"
    local jpg_path="$JPG_FRAMES_DIR/$frame_jpg_basename"
    local txt_path="$CHAFA_FRAMES_DIR/${frame_num_str}.txt"

    if [ ! -f "$jpg_path" ]; then
        if [ "$QUIET" -eq 0 ]; then echo "警告: 未找到JPG $jpg_path 用于渲染。" >&2; fi
        return 1
    fi
    chafa $CHAFA_OPTS_RENDER "$jpg_path" > "$txt_path"
    return $?
}
export -f render_single_frame_for_xargs

render_all_chafa_frames_parallel() {
    if [ $QUIET -eq 0 ]; then
        echo "正在使用最多 $NUM_THREADS 个线程预渲染 $TOTAL_FRAMES 个Chafa帧..."
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
        echo -e "\n并行Chafa渲染完成。渲染了 $rendered_count 帧。"
    fi
    if [ "$rendered_count" -ne "$TOTAL_FRAMES" ]; then
        echo "警告: 预期渲染 $TOTAL_FRAMES 帧，但实际找到 $rendered_count 帧。" >&2
    fi
}

# --- 播放函数 ---
play_chafa_frames() {
    local frame_delay
    frame_delay=$(awk "BEGIN {print 1.0/$FPS}")
    local info_line
    info_line=$(($(tput lines) - 1))

    tput smcup # 切换到备用屏幕缓冲区
    tput civis # 隐藏光标
    clear       # 初次清除备用屏幕

    local current_loop=1
    while true; do
        if [ $QUIET -eq 0 ] && [ $LOOP -eq 1 ] && [ $current_loop -gt 1 ]; then
            tput cup "$info_line" 0; printf "正在开始循环: %d " "$current_loop"; tput el; sleep 1;
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
                           echo -e "\n错误: 后台渲染器已终止，且帧 $chafa_frame_file 缺失。" >&2
                           # cleanup将由trap调用
                           exit 1
                        fi
                    fi
                    sleep 0.01
                    wait_count=$((wait_count + 1))
                    if [ $QUIET -eq 0 ] && (( wait_count % 50 == 0 )); then
                        tput cup "$info_line" 0
                        printf "正在播放: 正在等待帧 %s/%d (渲染器PID: %s)..." "$frame_num_padded" "$TOTAL_FRAMES" "${RENDER_PID:-N/A}"
                        tput el
                    fi
                done
            elif [ ! -f "$chafa_frame_file" ]; then
                echo -e "\n错误: 预加载模式下帧 $chafa_frame_file 缺失。" >&2
                sleep "$frame_delay"
                continue
            fi

            cat "$chafa_frame_file"

            if [ $QUIET -eq 0 ]; then
                local progress=$((100 * i_seq / TOTAL_FRAMES))
                tput cup "$info_line" 0
                printf "正在播放: %3d%% (帧 %s/%d)" "$progress" "$frame_num_padded" "$TOTAL_FRAMES"
                if [ $LOOP -eq 1 ]; then printf " 循环 %d" "$current_loop"; fi
                tput el
            fi
            sleep "$frame_delay"
        done

        if [ $LOOP -eq 0 ]; then break; fi
        current_loop=$((current_loop + 1))
    done

    # 这里不需要tput cnorm或clear，cleanup会处理
    if [ $QUIET -eq 0 ]; then tput cup "$info_line" 0; tput el; echo -e "\n播放完成。"; fi
    # 脚本末尾的 'exit 0' 会触发 EXIT 捕获，从而调用 cleanup。
}

# --- 参数解析 ---
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
            else echo "错误: 未知选项 $1" >&2; exit 1; fi ;;
    esac
done

# --- 验证输入 ---
if [ -z "$VIDEO_PATH" ]; then echo "错误: 未指定视频文件。" >&2; exit 1; fi
if [ ! -f "$VIDEO_PATH" ] && [[ "$VIDEO_PATH" != http* ]]; then echo "错误: 视频文件 '$VIDEO_PATH' 未找到。" >&2; exit 1; fi
if ! [[ "$FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(awk "BEGIN {print ($FPS <= 0)}") )); then echo "错误: FPS必须是正数。" >&2; exit 1; fi
MAX_FPS=60; if (( $(awk "BEGIN {print ($FPS > $MAX_FPS)}") )); then echo "警告: FPS $FPS 过高，已限制为 $MAX_FPS。" >&2; FPS=$MAX_FPS; fi
if [[ "$SCALE_MODE" != "fit" && "$SCALE_MODE" != "fill" && "$SCALE_MODE" != "stretch" ]]; then echo "错误: 无效的缩放模式。" >&2; exit 1; fi
if [[ "$COLORS" != "2" && "$COLORS" != "16" && "$COLORS" != "256" && "$COLORS" != "full" ]]; then echo "错误: 无效的颜色模式。" >&2; exit 1; fi
if [[ "$DITHER" != "none" && "$DITHER" != "ordered" && "$DITHER" != "diffusion" ]]; then echo "错误: 无效的抖动模式。" >&2; exit 1; fi
if [[ "$SYMBOLS" != "block" && "$SYMBOLS" != "ascii" && "$SYMBOLS" != "space" ]]; then echo "错误: 无效的字符集。" >&2; exit 1; fi
if ! [[ "$WIDTH" =~ ^[0-9]+$ ]] || [ "$WIDTH" -le 0 ]; then echo "错误: 宽度必须是正数。" >&2; exit 1; fi
if ! [[ "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -le 0 ]; then echo "错误: 高度必须是正数。" >&2; exit 1; fi
if [[ "$PLAY_MODE" != "preload" && "$PLAY_MODE" != "stream" ]]; then echo "错误: 无效的播放模式。请使用 'preload' 或 'stream'。" >&2; exit 1; fi
if ! [[ "$NUM_THREADS" =~ ^[0-9]+$ ]] || [ "$NUM_THREADS" -le 0 ]; then echo "错误: 线程数必须是正整数。" >&2; exit 1; fi

# --- 主执行 ---
check_dependencies
setup_temp_dir # 设置 TEMP_DIR, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR, 以及 trap

# play_chafa_frames 之前的消息将显示在正常屏幕上
get_video_info
extract_frames # 设置 TOTAL_FRAMES

RENDER_PID=""

if [ "$PLAY_MODE" == "preload" ]; then
    if [ $QUIET -eq 0 ]; then echo "模式: 预加载。播放前渲染所有帧。"; fi
    render_all_chafa_frames_parallel
    play_chafa_frames
elif [ "$PLAY_MODE" == "stream" ]; then
    if [ $QUIET -eq 0 ]; then echo "模式: 流式。播放期间在后台渲染帧。"; fi
    render_all_chafa_frames_parallel &
    RENDER_PID=$!
    if [ $QUIET -eq 0 ]; then echo "后台渲染已启动 (PID: $RENDER_PID)。"; fi
    play_chafa_frames
    if ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "正在等待后台渲染 (PID: $RENDER_PID) 完成..."; fi
        wait "$RENDER_PID"
        if [ $QUIET -eq 0 ]; then echo "后台渲染完成。"; fi
    fi
    RENDER_PID=""
fi

# 正常退出将触发 EXIT 捕获，从而调用 cleanup。
# cleanup 将恢复光标和屏幕。
exit 0