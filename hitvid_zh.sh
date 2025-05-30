#!/bin/bash

# hitvid v1.0.2 - 一款使用 chafa 的基于终端的视频播放器
# 作者: Hitmux
# 描述: 使用 chafa 渲染帧，在终端中播放视频

# 默认设置
FPS=15 # 设置用于 EXTRACTION (提取) 的播放帧率。
SCALE_MODE="fit" # 设置缩放模式: fit (适应), fill (填充), stretch (拉伸)。
COLORS="256" # 设置颜色模式: 2, 16, 256, full (全彩)。
DITHER="ordered" # 设置抖动模式: none (无), ordered (有序), diffusion (扩散)。
SYMBOLS="block" # 设置字符集: block (方块), ascii, space (空格)。
WIDTH=$(tput cols) # 设置显示宽度 (字符数)。
HEIGHT=$(($(tput lines) - 2)) # 预留1行用于信息，1行用于安全/提示符。
QUIET=0 # 安静模式，禁止显示进度和其他信息输出。
LOOP=0 # 循环播放视频。
PLAY_MODE="stream" # "preload" (预加载) 或 "stream" (流式)。
NUM_THREADS=$(nproc --all 2>/dev/null || echo 4) # 如果 nproc 失败，默认为 4 个线程。

# 基于字符单元格近似值的 FFmpeg 预缩放常量
CHAR_PIXEL_WIDTH_APPROX=8
CHAR_PIXEL_HEIGHT_APPROX=16

# 播放控制设置
PAUSED=0
ORIGINAL_FPS=$FPS # 存储用于提取的 FPS，在参数解析后正确设置。
CURRENT_FPS_MULTIPLIER_INDEX=3 # PLAYBACK_SPEED_MULTIPLIERS 中 1.0x 速度的索引。
declare -a PLAYBACK_SPEED_MULTIPLIERS
PLAYBACK_SPEED_MULTIPLIERS=(0.25 0.50 0.75 1.00 1.25 1.50 2.00)
SEEK_SECONDS=5 # 快进/快退秒数

# --- 辅助函数 ---
cleanup() {
    stty sane # 恢复终端设置到已知良好状态
    tput cnorm # 恢复光标
    tput rmcup # 恢复正常屏幕缓冲区

    if [ $QUIET -eq 0 ]; then echo "正在清理临时文件..." >&2; fi

    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "正在终止后台渲染进程 $RENDER_PID..." >&2; fi
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
    echo "hitvid - 使用 chafa 的终端视频播放器"
    echo ""
    echo "用法: hitvid [视频路径] [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help            显示此帮助信息"
    echo "  -f, --fps FPS         设置提取帧率 (默认: $FPS)"
    echo "  -s, --scale MODE      设置缩放模式: fit, fill, stretch (默认: $SCALE_MODE)"
    echo "                        这会影响 FFmpeg 预缩放和 Chafa 渲染。"
    echo "  -c, --colors NUM      设置颜色模式: 2, 16, 256, full (默认: $COLORS)"
    echo "  -d, --dither MODE     设置抖动模式: none, ordered, diffusion (默认: $DITHER)"
    echo "  -y, --symbols SET     设置字符集: block, ascii, space (默认: $SYMBOLS)"
    echo "  -w, --width WIDTH     设置显示宽度 (默认: 终端宽度)"
    echo "  -t, --height HEIGHT   设置显示高度 (默认: 终端高度 - 2 行)"
    echo "  -m, --mode MODE       播放模式: preload (预加载), stream (流式) (默认: $PLAY_MODE)"
    echo "      --threads N       Chafa 渲染的并行线程数 (默认: $NUM_THREADS)"
    echo "  -q, --quiet           禁止显示进度信息和交互反馈"
    echo "  -l, --loop            循环播放"
    echo ""
    echo "交互控制 (播放期间):"
    echo "  空格键                暂停/恢复"
    echo "  右箭头                快进 $SEEK_SECONDS 秒"
    echo "  左箭头                快退 $SEEK_SECONDS 秒"
    echo "  上箭头                提高播放速度"
    echo "  下箭头                降低播放速度"
    echo ""
    echo "示例:"
    echo "  hitvid video.mp4"
    echo "  hitvid video.mp4 --mode stream --threads 8"
    echo "  hitvid video.mp4 --fps 20 --colors full --scale fill"
    echo ""
    exit 0
}

check_dependencies() {
    for cmd in ffmpeg chafa tput nproc xargs awk; do
        if ! command -v $cmd &> /dev/null; then
            echo "错误: $cmd 未安装。请先安装。" >&2
            exit 1
        fi
    done
}

setup_temp_dir() {
    local temp_base_path="/tmp" # 默认
    local use_shm=0
    local temp_dir_attempt=""

    if [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && [ -x "/dev/shm" ]; then
        temp_dir_attempt=$(mktemp -d "/dev/shm/hitvid.XXXXXX" 2>/dev/null)
        if [ -n "$temp_dir_attempt" ] && [ -d "$temp_dir_attempt" ]; then
            TEMP_DIR="$temp_dir_attempt"
            if [ $QUIET -eq 0 ]; then echo "使用 tmpfs (/dev/shm) 存放临时文件: $TEMP_DIR" >&2; fi
            use_shm=1
        else
            if [ $QUIET -eq 0 ]; then echo "警告: 未能在于 /dev/shm 创建临时目录。回退到 $temp_base_path。" >&2; fi
        fi
    elif [ $QUIET -eq 0 ]; then
        echo "警告: /dev/shm 不可用或不可写/执行。使用 $temp_base_path 存放临时文件。性能可能会受影响。" >&2
    fi

    if [ $use_shm -eq 0 ]; then
        TEMP_DIR=$(mktemp -d "${temp_base_path}/hitvid.XXXXXX")
    fi

    if [ ! -d "$TEMP_DIR" ]; then
        echo "错误: 创建临时目录失败。" >&2
        exit 1
    fi

    JPG_FRAMES_DIR="$TEMP_DIR/jpg_frames"
    CHAFA_FRAMES_DIR="$TEMP_DIR/chafa_frames"
    mkdir "$JPG_FRAMES_DIR" "$CHAFA_FRAMES_DIR"
    if [ ! -d "$JPG_FRAMES_DIR" ] || [ ! -d "$CHAFA_FRAMES_DIR" ]; then
        echo "错误: 创建临时子目录失败。" >&2
        if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
        exit 1
    fi
    trap "cleanup; exit" INT TERM EXIT # 捕获中断、终止、退出信号以进行清理
}


display_progress_bar() {
    local current_val=$1
    local total_val=$2
    local bar_width=$3
    local prefix_text="${4:-进度}" # 默认为 "进度"
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
            percent=100 # 如果总数为0但当前值大于0，则视为100%
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
    if [ $QUIET -eq 0 ]; then echo "正在分析视频文件..."; fi
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration,nb_frames -of csv=p=0 "$VIDEO_PATH" 2>/dev/null)
    if [ -z "$VIDEO_INFO" ]; then echo "错误: 无法提取视频信息。" >&2; cleanup; exit 1; fi

    VIDEO_WIDTH=$(echo "$VIDEO_INFO" | cut -d',' -f1)
    VIDEO_HEIGHT=$(echo "$VIDEO_INFO" | cut -d',' -f2)
    VIDEO_DURATION_FLOAT_STR=$(echo "$VIDEO_INFO" | cut -d',' -f3)
    VIDEO_NB_FRAMES_STR=$(echo "$VIDEO_INFO" | cut -d',' -f4)

    VIDEO_DURATION_FLOAT="0"
    if [[ "$VIDEO_DURATION_FLOAT_STR" != "N/A" && "$VIDEO_DURATION_FLOAT_STR" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then
        VIDEO_DURATION_FLOAT="$VIDEO_DURATION_FLOAT_STR"
        VIDEO_DURATION=$(printf "%.0f" "$VIDEO_DURATION_FLOAT")
    else
        VIDEO_DURATION="N/A" # 若时长不可用
    fi

    if ! [[ "$VIDEO_NB_FRAMES_STR" =~ ^[0-9]+$ ]]; then
        VIDEO_NB_FRAMES_STR="N/A" # 若总帧数不可用
    fi

    if [ $QUIET -eq 0 ]; then
        echo "视频分辨率: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}, 时长: ${VIDEO_DURATION}秒, 总输入帧数: ${VIDEO_NB_FRAMES_STR}"
    fi
}

extract_frames() {
    local ffmpeg_output_file="$TEMP_DIR/ffmpeg_extract.log"
    local progress_file="$TEMP_DIR/ffmpeg_progress.log"
    rm -f "$progress_file" # 清理旧的进度文件

    local ffmpeg_input_arg="$VIDEO_PATH"
    # 如果视频路径以 '-' 开头且不是标准输入 '-'，也不是 URL 或绝对路径，则在其前面加上 './'
    if [[ "$VIDEO_PATH" == -* && "$VIDEO_PATH" != "-" && "$VIDEO_PATH" != http* && "$VIDEO_PATH" != /* ]]; then
        ffmpeg_input_arg="./$VIDEO_PATH"
    fi

    local ffmpeg_target_pixel_width=$((WIDTH * CHAR_PIXEL_WIDTH_APPROX))
    local ffmpeg_target_pixel_height=$((HEIGHT * CHAR_PIXEL_HEIGHT_APPROX))
    local scale_vf_option="" # FFmpeg 缩放视频滤镜选项

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
        echo "正在提取帧 (可能需要一段时间)..."
        echo "FFmpeg 视频滤镜选项: $vf_opts"
        ffmpeg -nostdin -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" \
               -progress "$progress_file" > "$ffmpeg_output_file" 2>&1 &
        local ffmpeg_pid=$!

        local last_progress_update_time=$(date +%s%N)
        while ps -p "$ffmpeg_pid" > /dev/null; do
            local current_time=$(date +%s%N)
            # 每 200ms 更新一次进度
            if (( (current_time - last_progress_update_time) > 200000000 )); then
                if [ -f "$progress_file" ]; then
                    local current_input_frame_progress=$(grep '^frame=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local current_out_time_us=$(grep '^out_time_us=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')
                    local progress_status=$(grep '^progress=' "$progress_file" | tail -n1 | cut -d'=' -f2 | tr -d '[:space:]')

                    if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0.0)}"; then # 如果视频时长有效
                        local total_duration_us=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * 1000000.0)}")
                        if [[ -n "$current_out_time_us" && "$total_duration_us" -gt 0 ]]; then
                             display_progress_bar "$current_out_time_us" "$total_duration_us" 30 "FFmpeg 提取中 (时间)"
                        elif [[ -n "$current_input_frame_progress" ]]; then
                            printf "FFmpeg 提取中... 输入帧: %s \r" "${current_input_frame_progress}"
                        else
                            printf "FFmpeg 提取中... \r"
                        fi
                    elif [[ "$VIDEO_NB_FRAMES_STR" != "N/A" && "$VIDEO_NB_FRAMES_STR" -gt 0 ]]; then # 如果总帧数有效
                        if [[ -n "$current_input_frame_progress" ]]; then
                            display_progress_bar "$current_input_frame_progress" "$VIDEO_NB_FRAMES_STR" 30 "FFmpeg 提取中 (帧数)"
                        else
                            printf "FFmpeg 提取中... \r"
                        fi
                    else # 如果时长和总帧数都无效，仅显示当前处理的输入帧
                        if [[ -n "$current_input_frame_progress" ]]; then
                            printf "FFmpeg 提取中... (PID: %s) 输入帧: %s \r" "$ffmpeg_pid" "${current_input_frame_progress:-?}"
                        else
                            printf "FFmpeg 提取中... (PID: %s) \r" "$ffmpeg_pid"
                        fi
                    fi
                    if [[ "$progress_status" == "end" ]]; then break; fi # 如果 ffmpeg 报告结束，则跳出循环
                fi
                last_progress_update_time=$current_time
            fi
            sleep 0.05 # 短暂休眠以减少 CPU 占用
        done
        wait "$ffmpeg_pid" # 等待 ffmpeg 进程结束
        FFMPEG_EXIT_CODE=$?

        TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
        local expected_output_frames=0
        if awk "BEGIN {exit !($VIDEO_DURATION_FLOAT > 0.0)}"; then
            expected_output_frames=$(awk "BEGIN {print int($VIDEO_DURATION_FLOAT * $ORIGINAL_FPS)}")
        fi

        if [ "$expected_output_frames" -le 0 ]; then # 如果预期帧数计算不出来或为0
            if [ "$TOTAL_FRAMES" -gt 0 ]; then
                expected_output_frames=$TOTAL_FRAMES # 使用实际提取的帧数
            else
                expected_output_frames=1 # 避免除以零 (如果没有帧)
            fi
        fi
        display_progress_bar "$TOTAL_FRAMES" "$expected_output_frames" 30 "FFmpeg 已提取"
        echo # 换行，完成进度条显示
    else # 安静模式
        ffmpeg -nostdin -i "$ffmpeg_input_arg" -vf "$vf_opts" -q:v 2 "$JPG_FRAMES_DIR/frame-%05d.jpg" &>/dev/null
        FFMPEG_EXIT_CODE=$?
    fi

    if [ "$FFMPEG_EXIT_CODE" -ne 0 ]; then
        if [ $QUIET -eq 0 ]; then
            echo "ffmpeg 提取过程中出错。日志:" >&2
            cat "$ffmpeg_output_file" >&2
        else
            echo "ffmpeg 提取过程中出错。不带 --quiet 运行时查看详情。" >&2
        fi
        cleanup; exit 1;
    fi

    TOTAL_FRAMES=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$TOTAL_FRAMES" -eq 0 ]; then echo "错误: 没有提取到任何帧。请检查视频文件和 ffmpeg 输出。" >&2; cleanup; exit 1; fi
    if [ $QUIET -eq 0 ]; then echo "已提取 $TOTAL_FRAMES 帧，目标帧率 $ORIGINAL_FPS fps。"; fi
}

# 此函数直接调用，也由 xargs 调用。
# 它依赖于 CHAFA_OPTS_RENDER, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR 可用。
# - 直接调用时作为 shell 变量。
# - xargs 调用时作为导出的环境变量。
render_single_frame_for_xargs() {
    local frame_jpg_basename="$1" # JPG 帧文件名 (例如 frame-00001.jpg)
    local frame_num_str="${frame_jpg_basename%.jpg}" # 帧编号字符串 (例如 frame-00001)
    local jpg_path="$JPG_FRAMES_DIR/$frame_jpg_basename"
    local txt_path="$CHAFA_FRAMES_DIR/${frame_num_str}.txt"

    if [ ! -f "$jpg_path" ]; then
        return 1 # 如果 JPG 文件不存在则返回错误
    fi
    # 使用 Chafa 将 JPG 转换为文本艺术并保存
    chafa $CHAFA_OPTS_RENDER "$jpg_path" > "$txt_path"
    local chafa_status=$?
    return $chafa_status
}
export -f render_single_frame_for_xargs # 导出函数定义供 xargs 使用

render_all_chafa_frames_parallel() {
    if [ $QUIET -eq 0 ]; then
        local mode_msg="预渲染"
        if [ "$PLAY_MODE" == "stream" ]; then
            mode_msg="开始后台 Chafa 渲染"
        fi
        echo "$mode_msg $TOTAL_FRAMES 个 Chafa 帧，使用最多 $NUM_THREADS 个线程..."
    fi

    # CHAFA_OPTS_RENDER 已全局定义。
    # 为 xargs 生成的子 shell 导出必要的变量。
    export CHAFA_OPTS_RENDER JPG_FRAMES_DIR CHAFA_FRAMES_DIR QUIET

    # 使用 find 和 xargs 并行处理所有 JPG 帧
    find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -printf "%f\n" | \
        xargs -P "$NUM_THREADS" -I {} bash -c 'render_single_frame_for_xargs "$@"' _ {} &
    local xargs_pid=$! # 获取 xargs 进程的 PID

    if [ "$PLAY_MODE" == "preload" ]; then # 如果是预加载模式，则等待渲染完成并显示进度
        if [ $QUIET -eq 0 ]; then
            local rendered_count=0
            local last_progress_update_time=$(date +%s%N)
            while ps -p "$xargs_pid" > /dev/null; do
                local current_time=$(date +%s%N)
                if (( (current_time - last_progress_update_time) > 200000000 )); then # 每 200ms 更新一次
                    rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
                    display_progress_bar "$rendered_count" "$TOTAL_FRAMES" 30 "Chafa 渲染中"
                    last_progress_update_time=$current_time
                fi
                sleep 0.05
            done
            # 确保最后显示最终进度
            rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')
            display_progress_bar "$rendered_count" "$TOTAL_FRAMES" 30 "Chafa 渲染中"
            echo # 换行
        fi
    fi

    wait "$xargs_pid" # 等待所有 Chafa 渲染子进程完成

    local final_rendered_count=$(find "$CHAFA_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.txt" 2>/dev/null | wc -l | tr -d '[:space:]')

    if [ "$PLAY_MODE" == "preload" ] && [ $QUIET -eq 0 ]; then
        echo "并行 Chafa 渲染完成。已渲染 $final_rendered_count 帧。"
    fi

    # 检查渲染的帧数是否与提取的 JPG 帧数匹配
    if [ "$final_rendered_count" -ne "$TOTAL_FRAMES" ]; then
        echo "警告: 期望渲染 $TOTAL_FRAMES 个 Chafa 帧，但实际找到 $final_rendered_count 个。" >&2
    fi
}

play_chafa_frames() {
    local current_playback_fps # 当前播放帧率
    local frame_delay # 每帧之间的延迟 (秒)
    current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
    frame_delay=$(awk "BEGIN {print 1.0 / $current_playback_fps}")

    local info_line_row # 信息行的行号
    info_line_row=$(($(tput lines) - 1)) # 通常是最后一行

    tput smcup # 保存当前屏幕内容并切换到备用屏幕缓冲区
    tput civis # 隐藏光标
    clear # 清屏

    local current_loop=1 # 当前循环次数
    while true; do # 主播放循环 (用于支持循环播放)
        if [ $QUIET -eq 0 ] && [ $LOOP -eq 1 ] && [ $current_loop -gt 1 ]; then
            tput cup "$info_line_row" 0; printf "开始循环: %d " "$current_loop"; tput el; sleep 1;
        fi

        local i_seq=1 # 当前帧序号 (从1开始)
        while [ "$i_seq" -le "$TOTAL_FRAMES" ]; do # 遍历所有帧
            local frame_start_time_ns=$(date +%s%N) # 记录帧开始处理的时间 (纳秒)

            if [ $QUIET -eq 0 ]; then # 如果不是安静模式，则处理用户输入
                local key=""
                # 非阻塞方式读取单个字符 (包括转义序列)
                if read -s -r -N1 -t 0.001 pressed_key; then
                    key="$pressed_key"
                    if [[ "$key" == $'\e' ]]; then # 如果是转义字符
                        if read -s -r -N1 -t 0.001 next_char; then
                            key+="$next_char"
                            if [[ "$next_char" == "[" ]]; then # CSI 序列 (如箭头键)
                                if read -s -r -N1 -t 0.001 final_char; then
                                    key+="$final_char"
                                fi
                            fi
                        fi
                    fi
                fi

                # 处理按键
                case "$key" in
                    ' ') # 空格键: 暂停/恢复
                        PAUSED=$((1 - PAUSED))
                        ;;
                    $'\e[A') # 上箭头: 加速
                        if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -lt $((${#PLAYBACK_SPEED_MULTIPLIERS[@]} - 1)) ]; then
                            CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX + 1))
                        fi
                        ;;
                    $'\e[B') # 下箭头: 减速
                        if [ "$CURRENT_FPS_MULTIPLIER_INDEX" -gt 0 ]; then
                            CURRENT_FPS_MULTIPLIER_INDEX=$((CURRENT_FPS_MULTIPLIER_INDEX - 1))
                        fi
                        ;;
                    $'\e[C') # 右箭头: 快进
                        local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                        i_seq=$((i_seq + frames_to_skip))
                        if [ "$i_seq" -gt "$TOTAL_FRAMES" ]; then i_seq=$TOTAL_FRAMES; fi # 不超过总帧数
                        ;;
                    $'\e[D') # 左箭头: 快退
                        local frames_to_skip=$(awk "BEGIN {print int($SEEK_SECONDS * $ORIGINAL_FPS)}")
                        i_seq=$((i_seq - frames_to_skip))
                        if [ "$i_seq" -lt 1 ]; then i_seq=1; fi # 不小于第1帧
                        ;;
                esac
                # 根据新的速度倍率更新播放帧率和帧延迟
                current_playback_fps=$(awk "BEGIN {print $ORIGINAL_FPS * ${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}}")
                frame_delay=$(awk "BEGIN {print 1.0 / $current_playback_fps}")
            fi

            if [ "$PAUSED" -eq 1 ]; then # 如果已暂停
                if [ $QUIET -eq 0 ]; then
                    tput cup "$info_line_row" 0 # 移动光标到信息行
                    printf "[已暂停] 按空格键恢复。帧 %d/%d。速度: %.2fx" \
                        "$i_seq" "$TOTAL_FRAMES" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
                    tput el # 清除行尾剩余内容
                fi
                sleep 0.1 # 短暂休眠
                continue # 继续下一轮循环 (保持暂停状态)
            fi

            local frame_num_padded
            frame_num_padded=$(printf "frame-%05d" "$i_seq") # 格式化帧文件名
            local chafa_frame_file="$CHAFA_FRAMES_DIR/${frame_num_padded}.txt"

            if [ "$PLAY_MODE" == "stream" ]; then # 流式播放模式
                local wait_count=0
                # 等待当前帧的 Chafa 文件生成
                while [ ! -f "$chafa_frame_file" ]; do
                    # 检查后台渲染进程是否意外退出
                    if [[ -n "$RENDER_PID" ]] && ! ps -p "$RENDER_PID" > /dev/null; then
                        if [ ! -f "$chafa_frame_file" ]; then # 如果帧文件仍不存在
                           echo -e "\n错误: 后台渲染器 (PID $RENDER_PID) 已终止，且帧 $chafa_frame_file 缺失。" >&2
                           # cleanup 由 trap EXIT 处理
                           exit 1
                        fi
                    fi
                    sleep 0.01 # 短暂等待
                    wait_count=$((wait_count + 1))
                    if [ $QUIET -eq 0 ] && (( wait_count % 20 == 0 )); then # 每 ~200ms 更新等待信息
                        tput cup "$info_line_row" 0
                        printf "播放中: 等待帧 %s/%d (渲染器 PID: %s)..." "$frame_num_padded" "$TOTAL_FRAMES" "${RENDER_PID:-N/A}"
                        tput el
                    fi
                    # 在等待帧时也允许暂停
                    if [ $QUIET -eq 0 ]; then
                        local key_wait=""
                        if read -s -r -N1 -t 0.001 pressed_key_wait; then
                            if [[ "$pressed_key_wait" == ' ' ]]; then PAUSED=1; break; fi
                        fi
                    fi
                done
                if [ "$PAUSED" -eq 1 ]; then continue; fi # 如果在等待期间暂停了
            elif [ ! -f "$chafa_frame_file" ]; then # 预加载模式下帧文件缺失 (不应发生)
                if [ $QUIET -eq 0 ]; then echo -e "\n错误: 在预加载模式下帧 $chafa_frame_file 缺失。" >&2; fi
                sleep "$frame_delay" # 仍然等待以大致保持时间同步
                i_seq=$((i_seq + 1))
                continue
            fi

            tput cup 0 0 # 将光标移到屏幕左上角 (0,0)
            cat "$chafa_frame_file" # 显示 Chafa 渲染的帧

            if [ $QUIET -eq 0 ]; then # 更新信息行
                tput cup "$info_line_row" 0
                local bar_width_chars=20 # 进度条宽度
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
                printf "%${filled_width_chars}s" "" | tr ' ' '=' # 打印填充部分
                printf "%${empty_width_chars}s" "" | tr ' ' ' ' # 打印空白部分
                printf "] %d/%d (%d%%)" "$i_seq" "$TOTAL_FRAMES" "$percent_done_val"

                printf " | 速度: %.2fx" "${PLAYBACK_SPEED_MULTIPLIERS[$CURRENT_FPS_MULTIPLIER_INDEX]}"
                if [ $LOOP -eq 1 ]; then printf " | 循环 %d" "$current_loop"; fi
                tput el # 清除行尾
            fi

            local frame_end_time_ns=$(date +%s%N) # 记录帧结束处理的时间
            local processing_time_ns=$((frame_end_time_ns - frame_start_time_ns)) # 计算处理时间
            # 计算需要休眠的时间以达到目标帧率
            local sleep_duration_s=$(awk "BEGIN {sd = $frame_delay - ($processing_time_ns / 1000000000.0); if (sd < 0) sd = 0; print sd}")
            sleep "$sleep_duration_s" # 休眠

            i_seq=$((i_seq + 1)) # 下一帧
        done

        if [ $LOOP -eq 0 ]; then break; fi # 如果不循环，则退出主播放循环
        current_loop=$((current_loop + 1)) # 增加循环次数
        PAUSED=0 # 重置暂停状态
    done

    if [ $QUIET -eq 0 ]; then tput cup "$info_line_row" 0; tput el; echo -e "\n播放完成。"; fi
}

# --- 参数解析 ---
if [ $# -eq 0 ]; then show_help; fi # 如果没有参数，显示帮助信息
VIDEO_PATH=""
USER_FPS="" # 用户指定的FPS，用于后续判断是否使用了默认值

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
            else echo "错误: 未知选项 $1" >&2; show_help; fi ;;
    esac
done

# --- 验证输入 ---
if [ -z "$VIDEO_PATH" ]; then echo "错误: 未指定视频文件。" >&2; show_help; fi
# 如果视频路径不是 URL、标准输入或绝对路径，并且文件不存在，则报错
if [[ "$VIDEO_PATH" != http* && "$VIDEO_PATH" != ftp* && "$VIDEO_PATH" != rtmp* && "$VIDEO_PATH" != "-" ]]; then
    if [ ! -f "$VIDEO_PATH" ]; then echo "错误: 视频文件 '$VIDEO_PATH' 未找到。" >&2; exit 1; fi
fi

if ! [[ "$FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk "BEGIN {exit !($FPS > 0)}"; then echo "错误: FPS 必须为正数。" >&2; exit 1; fi
MAX_FPS=60; if awk "BEGIN {exit !($FPS > $MAX_FPS)}"; then echo "警告: FPS $FPS 对于提取而言过高，已限制为 $MAX_FPS。" >&2; FPS=$MAX_FPS; fi
ORIGINAL_FPS=$FPS # 将最终确定的FPS存为原始提取FPS

if [[ "$SCALE_MODE" != "fit" && "$SCALE_MODE" != "fill" && "$SCALE_MODE" != "stretch" ]]; then echo "错误: 无效的缩放模式。" >&2; exit 1; fi
if [[ "$COLORS" != "2" && "$COLORS" != "16" && "$COLORS" != "256" && "$COLORS" != "full" ]]; then echo "错误: 无效的颜色模式。" >&2; exit 1; fi
if [[ "$DITHER" != "none" && "$DITHER" != "ordered" && "$DITHER" != "diffusion" ]]; then echo "错误: 无效的抖动模式。" >&2; exit 1; fi
if [[ "$SYMBOLS" != "block" && "$SYMBOLS" != "ascii" && "$SYMBOLS" != "space" ]]; then echo "错误: 无效的字符集。" >&2; exit 1; fi
if ! [[ "$WIDTH" =~ ^[0-9]+$ ]] || [ "$WIDTH" -le 0 ]; then echo "错误: 宽度必须为正数。" >&2; exit 1; fi
if ! [[ "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -le 0 ]; then echo "错误: 高度必须为正数。" >&2; exit 1; fi
if [[ "$PLAY_MODE" != "preload" && "$PLAY_MODE" != "stream" ]]; then echo "错误: 无效的播放模式。使用 'preload' (预加载) 或 'stream' (流式)。" >&2; exit 1; fi
if ! [[ "$NUM_THREADS" =~ ^[0-9]+$ ]] || [ "$NUM_THREADS" -le 0 ]; then echo "错误: 线程数必须为正整数。" >&2; exit 1; fi

# --- 主执行 ---
check_dependencies
setup_temp_dir # TEMP_DIR, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR 在此处设置

get_video_info
extract_frames # TOTAL_FRAMES 在此处设置

# 定义 CHAFA_OPTS_RENDER 一次，供直接调用和 xargs (通过导出) 使用
# 这些选项直接传递给 chafa 工具，不应翻译
CHAFA_OPTS_RENDER="--clear --size=${WIDTH}x${HEIGHT} --colors=$COLORS --dither=$DITHER"
case $SCALE_MODE in
    "fill") CHAFA_OPTS_RENDER+=" --zoom";;      # Chafa 的 --zoom 对应这里的 fill 模式
    "stretch") CHAFA_OPTS_RENDER+=" --stretch";; # Chafa 的 --stretch 对应这里的 stretch 模式
    # "fit" 是 Chafa 的默认行为，当指定 --size 时，它会适应尺寸
esac
case $SYMBOLS in
    "block") CHAFA_OPTS_RENDER+=" --symbols=block";;
    "ascii") CHAFA_OPTS_RENDER+=" --symbols=ascii";;
    "space") CHAFA_OPTS_RENDER+=" --symbols=space";;
esac

RENDER_PID="" # 后台渲染进程的PID

if [ "$PLAY_MODE" == "preload" ]; then # 预加载模式
    render_all_chafa_frames_parallel # 渲染所有帧
    play_chafa_frames                # 然后播放
elif [ "$PLAY_MODE" == "stream" ]; then # 流式模式
    if [ $QUIET -eq 0 ]; then
        echo "为加快启动速度，正在预渲染第一帧..."
    fi
    
    # 查找第一个提取的 JPG 帧 (按时间排序，取最早的)
    first_jpg_basename=$(find "$JPG_FRAMES_DIR" -maxdepth 1 -type f -name "frame-*.jpg" -print0 2>/dev/null | xargs -0 -r ls -1tr 2>/dev/null | head -n 1 | xargs basename 2>/dev/null)

    if [ -n "$first_jpg_basename" ] && [ -f "$JPG_FRAMES_DIR/$first_jpg_basename" ]; then
        # render_single_frame_for_xargs 使用全局的 CHAFA_OPTS_RENDER, JPG_FRAMES_DIR, CHAFA_FRAMES_DIR
        render_single_frame_for_xargs "$first_jpg_basename"
        if [ $QUIET -eq 0 ]; then echo "第一帧已预渲染。"; fi
    else
        if [ $QUIET -eq 0 ]; then
            if [ "$TOTAL_FRAMES" -eq 0 ]; then # 再次检查以提供更具体的警告
                 echo "警告: 未提取任何帧。无法预渲染第一帧。" >&2
            else
                 echo "警告: 无法找到/预渲染第一个 JPG 帧 ('${first_jpg_basename:-未找到}')。启动可能会较慢。" >&2
            fi
        fi
    fi

    render_all_chafa_frames_parallel & # 后台开始渲染所有（剩余的）帧
    RENDER_PID=$!
    
    play_chafa_frames # 开始播放，同时后台在渲染

    # 播放结束后，检查后台渲染是否仍在运行
    if [[ -n "$RENDER_PID" ]] && ps -p "$RENDER_PID" > /dev/null; then
        if [ $QUIET -eq 0 ]; then echo "等待任何剩余的后台渲染 (PID: $RENDER_PID) 完成..."; fi
        wait "$RENDER_PID" # 等待后台渲染完成
        if [ $QUIET -eq 0 ]; then echo "后台渲染已完全完成。"; fi
    elif [ $QUIET -eq 0 ]; then # 如果 RENDER_PID 为空或进程已不存在
        echo "后台渲染已完成。"
    fi
    RENDER_PID="" # 清空 PID
fi

# cleanup 函数会由 trap EXIT 调用，无需在此显式调用
exit 0