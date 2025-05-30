# Hitmux `hitvid` - 终端视频播放器

[简体中文](https://github.com/Hitmux/hitvid/blob/main/README_zh.md) [English](https://github.com/Hitmux/hitvid/blob/main/README.md)

[hitvid_zh.sh](https://github.com/Hitmux/hitvid/blob/main/hitvid_zh.sh)是中文版源代码

## [Hitmux 官方网站 https://hitmux.top](https://hitmux.top)

`hitvid` 是一个基于 Bash 脚本的终端视频播放器，它使用 `ffmpeg` 提取视频帧，并利用 `chafa` 将这些帧渲染成字符画，从而在终端中实现视频播放。


## 功能特性

*   **终端内播放:** 直接在你的终端窗口中观看视频。
*   **多种渲染选项:** 支持自定义 FPS、缩放模式、颜色数量、抖动算法和字符集。
*   **两种播放模式:**
    *   **`preload` (预加载模式 - 默认):** 先提取所有视频帧并将其全部转换为 Chafa 文本帧，然后开始播放。这种模式初始处理时间较长，但播放过程最流畅。
    *   **`stream` (流式模式):** 提取所有视频帧后，在后台并行处理 Chafa 文本帧的转换，同时开始播放。播放器会等待当前需要的帧渲染完成。这种模式可以更快开始播放，但如果渲染速度跟不上播放速度，可能会出现卡顿。
*   **并行处理:** 利用多核心 CPU 并行渲染 Chafa 帧，显著加快预加载模式的处理速度和流式模式的帧生成速度。
*   **循环播放:** 支持视频循环播放。
*   **静默模式:** 隐藏进度信息，仅显示视频内容。
*   **自动清理:** 脚本退出时自动清理产生的临时文件。

## 依赖项

在运行 `hitvid` 之前，请确保你的系统已安装以下工具：

*   **`ffmpeg`:** 用于视频解码和帧提取。
*   **`chafa`:** 用于将图像帧转换为终端字符画。
*   **`tput`:** 用于终端控制 (如清屏、隐藏/显示光标)。
*   **`nproc`:** (可选，推荐) 用于获取 CPU核心数，以优化并行处理线程数。如果未安装，默认使用4个线程。
*   **`xargs`:** 用于并行执行命令。

**安装示例 (Debian/Ubuntu):**
```bash
sudo apt update
sudo apt install ffmpeg chafa coreutils util-linux
```
(`coreutils` 通常包含 `nproc`，`util-linux` 通常包含 `tput`，`xargs` 通常是 `findutils` 或 `coreutils` 的一部分，一般系统都会自带。)

## 使用方法

```bash
./hitvid.sh [视频路径] [选项]
```

**视频路径:**
可以是本地视频文件的路径 (例如 `video.mp4`, `/path/to/my/video.avi`)，或者是一个可直接访问的视频 URL (例如 `http://example.com/video.mp4`)。

## 选项

| 短选项      | 长选项        | 参数        | 描述                                                                 | 默认值                               |
| :---------- | :------------ | :---------- | :------------------------------------------------------------------- | :----------------------------------- |
| `-h`        | `--help`      |             | 显示此帮助信息并退出。                                                       |                                      |
| `-f`        | `--fps`       | `FPS`       | 设置播放的每秒帧数。                                                         | `15`                                 |
| `-s`        | `--scale`     | `MODE`      | 设置缩放模式: `fit` (适应), `fill` (填充), `stretch` (拉伸)。                 | `fit`                                |
| `-c`        | `--colors`    | `NUM`       | 设置颜色模式: `2`, `16`, `256`, `full` (全彩)。                           | `256`                                |
| `-d`        | `--dither`    | `MODE`      | 设置抖动模式: `none` (无), `ordered` (有序), `diffusion` (扩散)。           | `ordered`                            |
| `-y`        | `--symbols`   | `SET`       | 设置字符集: `block` (方块), `ascii` (ASCII), `space` (空格)。              | `block`                              |
| `-w`        | `--width`     | `WIDTH`     | 设置显示宽度 (字符数)。                                                      | 当前终端宽度                         |
| `-t`        | `--height`    | `HEIGHT`    | 设置显示高度 (行数)。                                                        | 当前终端高度 - 2 行                  |
| `-m`        | `--mode`      | `MODE`      | 设置播放模式: `preload` (预加载), `stream` (流式)。                        | `stream`                            |
|             | `--threads`   | `N`         | 设置 Chafa 并行渲染的线程数。                                                | 系统 CPU 核心数 (或 4)               |
| `-q`        | `--quiet`     |             | 静默模式，禁止输出进度等信息。                                                 | 关闭                                 |
| `-l`        | `--loop`      |             | 循环播放视频。                                                             | 关闭                                 |

## 示例

1.  **基本播放:**
    ```bash
    ./hitvid.sh my_video.mp4
    ```

2.  **以 24 FPS 播放，使用全彩色，并填充屏幕:**
    ```bash
    ./hitvid.sh my_video.mp4 --fps 24 --colors full --scale fill
    ```

3.  **使用流式模式，并指定 8 个线程进行 Chafa 渲染:**
    ```bash
    ./hitvid.sh my_video.mp4 --mode stream --threads 8
    ```

4.  **循环播放，并使用 ASCII 字符集:**
    ```bash
    ./hitvid.sh animation.gif --loop --symbols ascii
    ```

5.  **静默播放，并自定义宽度和高度:**
    ```bash
    ./hitvid.sh short_clip.mkv --quiet --width 80 --height 24
    ```

## 工作流程

`hitvid` 的工作流程根据选择的播放模式有所不同：

**1. 通用步骤 (所有模式):**
   *   **参数解析:** 读取用户提供的命令行选项。
   *   **依赖检查:** 确认 `ffmpeg`, `chafa` 等必要工具已安装。
   *   **临时目录设置:** 创建一个临时目录 (例如 `/tmp/hitvid.XXXXXX`) 用于存放中间文件。脚本退出时会自动清理此目录。
   *   **视频信息获取:** 使用 `ffprobe` 获取视频的原始分辨率、时长等信息。
   *   **帧提取 (FFmpeg):** 使用 `ffmpeg` 将视频按指定的 FPS 提取为一系列 JPG 图像帧，并存放在临时目录的 `jpg_frames` 子目录中。

**2. `preload` (预加载) 模式 (默认):**
   *   **Chafa 帧并行渲染:**
        *   脚本会遍历所有提取的 JPG 图像帧。
        *   使用 `xargs -P` 启动多个 `chafa` 进程，并行地将每个 JPG 帧转换为包含 ANSI 转义序列的文本文件。这些文本文件代表了终端上显示的字符画。
        *   转换后的文本帧存储在临时目录的 `chafa_frames` 子目录中。
        *   此步骤会等待所有帧都渲染完成后才继续。
   *   **播放:**
        *   清空屏幕，隐藏光标。
        *   按顺序读取 `chafa_frames` 目录中的文本帧文件，并使用 `cat` 命令将其内容输出到终端。由于 `chafa` 在生成文本帧时已包含 `--clear` 选项，每个新帧会覆盖前一帧的区域。
        *   根据设定的 FPS，在每帧之间进行短暂 `sleep`。
        *   播放完成后，恢复光标，显示完成信息。

**3. `stream` (流式) 模式:**
   *   **后台 Chafa 帧并行渲染:**
        *   在 JPG 帧提取完成后，脚本会**在后台**启动 `render_all_chafa_frames_parallel` 函数。这个函数同样使用 `xargs -P` 并行渲染 Chafa 文本帧。
        *   主脚本**不会**等待所有帧渲染完成，而是立即进入播放阶段。
   *   **播放 (同时渲染):**
        *   清空屏幕，隐藏光标。
        *   当需要播放第 N 帧时：
            *   检查对应的 Chafa 文本帧文件 (`chafa_frames/frame-XXXXN.txt`) 是否已存在。
            *   如果文件不存在，播放器会暂停并等待，直到后台渲染进程生成该文件。期间会检查后台渲染进程是否意外中止。
            *   一旦文件存在，立即 `cat` 其内容到终端。
        *   根据设定的 FPS，在每帧之间进行短暂 `sleep`。
        *   播放完成后，如果后台渲染进程仍在运行，脚本会等待其完成后再退出。

**4. 清理:**
   *   无论脚本如何退出 (正常完成、用户中断 Ctrl+C、发生错误)，`trap` 机制会确保执行 `cleanup` 函数。
   *   `cleanup` 函数会恢复终端光标的显示，并删除整个临时目录及其内容。如果后台渲染进程仍在运行，会尝试终止它。

## 注意事项与故障排除

*   **性能:** 播放非常高分辨率或高比特率的视频可能会比较卡顿，即使在 `preload` 模式下，初始处理时间也会很长。终端本身的处理能力也是一个限制因素。
*   **终端兼容性:** 效果最好的终端是那些对 ANSI 转义序列（尤其是颜色和光标控制）支持良好的终端，例如 `gnome-terminal`, `konsole`, `xterm` (配置正确时), `iTerm2` (macOS), Windows Terminal。
*   **字体:** 终端使用的字体会影响字符画的显示效果。等宽字体通常效果更好。
*   **临时文件:** 脚本会产生较多临时文件 (JPG 图像帧和 Chafa 文本帧)。确保 `/tmp` 目录有足够的空间。这些文件会在脚本结束时自动删除。
*   **`--threads` 选项:** `NUM_THREADS` 的最佳值通常是 CPU 的核心数。设置过高可能因上下文切换过多而降低效率。
*   **流式模式卡顿:** 如果在 `stream` 模式下遇到频繁卡顿，意味着 Chafa 渲染速度跟不上 FPS。可以尝试：
    *   降低 `--fps`。
    *   减少 `--colors` (例如从 `full` 改为 `256`)。
    *   增加 `--threads` (如果 CPU 未充分利用)。
    *   切换回 `preload` 模式以获得最流畅的播放体验（但初始等待时间更长）。
*   **错误: `command not found`:** 确保所有依赖项都已正确安装并且在系统的 `PATH` 环境变量中。
*   **FFmpeg 错误:** 如果视频文件损坏或格式不受 `ffmpeg` 支持，帧提取可能会失败。脚本会尝试显示 `ffmpeg` 的错误日志。

