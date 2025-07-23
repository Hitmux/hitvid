## Hitmux `hitvid` - Terminal-based Video Player

## [Hitmux Official Website https://hitmux.top](https://hitmux.top)

`hitvid` is a Bash script-based terminal video player that uses `ffmpeg` to extract video frames and `chafa` to render these frames as character art, thus achieving video playback in the terminal.

### Added a version written in Go language. Go is much faster than shell, and ffmpeg and chafa are built-in, no need to install, and it is faster.
### Currently, the Go version is in the testing stage.

[Go version](https://github.com/Hitmux/hitvid/blob/main/main.go) 

-----

## Features

*   **In-terminal Playback:** Watch videos directly in your terminal window.
*   **Interactive Playback Controls:**
    *   **Pause/Resume:** Toggle playback with the `Spacebar`.
    *   **Seek:** Jump forward or backward by `5` seconds using `Right Arrow` and `Left Arrow` keys.
    *   **Playback Speed:** Adjust playback speed up or down using `Up Arrow` and `Down Arrow` keys.
*   **Multiple Rendering Options:** Supports custom FPS, scaling modes, color counts, dithering algorithms, and character sets.
*   **Optimized Frame Preparation:** Utilizes FFmpeg for intelligent pre-scaling of video frames based on terminal character dimensions, reducing Chafa's workload and improving rendering efficiency.
*   **Two Playback Modes:**
    *   **`preload` (Preload Mode):** Extracts all video frames and converts them entirely into Chafa text frames before starting playback. This mode has a longer initial processing time but offers the smoothest playback.
    *   **`stream` (Streaming Mode - Default):** After extracting all video frames, it processes the Chafa text frame conversion in the background in parallel while starting playback. The player waits for the currently needed frame to be rendered. This mode allows for faster playback initiation but may experience stuttering if rendering speed cannot keep up with playback speed.
*   **Parallel Processing:** Utilizes multi-core CPUs to render Chafa frames in parallel, significantly speeding up processing in preload mode and frame generation in streaming mode.
*   **Improved Temporary File Handling:** Prioritizes using `tmpfs` (`/dev/shm`) for temporary files when available, enhancing performance by reducing disk I/O.
*   **Enhanced Progress Feedback:** Provides clearer progress bars and status updates during frame extraction and rendering.
*   **Loop Playback:** Supports video loop playback.
*   **Quiet Mode:** Suppresses progress information and interactive feedback, displaying only the video content.
*   **Automatic Cleanup:** Automatically cleans up temporary files generated when the script exits, including restoring terminal settings.

-----

## Dependencies

Before running `hitvid`, please ensure that the following tools are installed on your system:

*   **`ffmpeg`:** For video decoding and frame extraction.
*   **`chafa`:** For converting image frames to terminal character art.
*   **`tput`:** For terminal control (e.g., clearing screen, hiding/showing cursor, restoring screen buffer).
*   **`nproc`:** (Optional, recommended) For getting the number of CPU cores to optimize parallel processing threads. If not installed, it defaults to 4 threads.
*   **`xargs`:** For executing commands in parallel.
*   **`awk`:** For floating-point arithmetic.
*   **`bc`:** For arbitrary-precision arithmetic, used in frame delay calculation.
*   **`grep`:** For text searching and filtering.

**Installation Example (Debian/Ubuntu):**

```bash
sudo apt update
sudo apt install ffmpeg chafa coreutils util-linux bc grep
```

(`coreutils` usually includes `nproc` and `xargs`, `util-linux` usually includes `tput`, `awk` is typically part of `gawk` or `mawk` and is generally pre-installed on most systems.)

-----

## Usage

```bash
./hitvid.sh [VIDEO_PATH] [OPTIONS]
```

**VIDEO_PATH:**
Can be a path to a local video file (e.g., `video.mp4`, `/path/to/my/video.avi`), or a directly accessible video URL (e.g., `http://example.com/video.mp4`).

-----

## Options

| Short Opt | Long Opt    | Argument  | Description                                                         | Default Value                 |
| :-------- | :---------- | :-------- | :------------------------------------------------------------------ | :---------------------------- |
| `-h`      | `--help`    |           | Display this help message and exit.                                 |                               |
| `-f`      | `--fps`     | `FPS`     | Set extraction frames per second. This also influences playback speed. | `15`                          |
| `-s`      | `--scale`   | `MODE`    | Set scaling mode for both FFmpeg pre-scaling and Chafa: `fit`, `fill`, `stretch`. | `fit`                         |
| `-c`      | `--colors`  | `NUM`     | Set color mode: `2`, `16`, `256`, `full`.                           | `256`                         |
| `-d`      | `--dither`  | `MODE`    | Set dithering mode: `none`, `ordered`, `diffusion`.                 | `ordered`                     |
| `-y`      | `--symbols` | `SET`     | Set character set: `block`, `ascii`, `space`.                       | `block`                       |
| `-w`      | `--width`   | `WIDTH`   | Set display width (in characters).                                  | Current terminal width        |
| `-t`      | `--height`  | `HEIGHT`  | Set display height (in lines).                                      | Current terminal height - 2 lines |
| `-m`      | `--mode`    | `MODE`    | Set playback mode: `preload`, `stream`.                             | `stream`                      |
|           | `--threads` | `N`       | Set number of parallel threads for Chafa rendering.                 | System CPU cores (or 4)       |
| `-q`      | `--quiet`   |           | Quiet mode, suppresses progress and other information.              | Off                           |
| `-l`      | `--loop`    |           | Loop video playback.                                                | Off                           |

**Interactive Controls (during playback - only active when not in `--quiet` mode):**

*   `Spacebar`: Pause/Resume playback.
*   `Right Arrow`: Seek forward `5` seconds.
*   `Left Arrow`: Seek backward `5` seconds.
*   `Up Arrow`: Increase playback speed (e.g., 1.0x -> 1.25x -> 1.5x).
*   `Down Arrow`: Decrease playback speed (e.g., 1.0x -> 0.75x -> 0.5x).

-----

## Examples

1.  **Basic Playback:**

    ```bash
    ./hitvid.sh my_video.mp4
    ```

2.  **Play at 24 FPS, using full colors, and fill the screen:**

    ```bash
    ./hitvid.sh my_video.mp4 --fps 24 --colors full --scale fill
    ```

3.  **Use streaming mode with 8 rendering threads (default is `stream` and `nproc` threads):**

    ```bash
    ./hitvid.sh my_video.mp4 --mode stream --threads 8
    ```

4.  **Loop playback and use ASCII character set:**

    ```bash
    ./hitvid.sh animation.gif --loop --symbols ascii
    ```

5.  **Quiet playback with custom width and height:**

    ```bash
    ./hitvid.sh short_clip.mkv --quiet --width 80 --height 24
    ```

During playback of these examples, you can use the interactive controls (Space, Arrow keys) to manage the experience.

-----

## Workflow

`hitvid`'s workflow varies depending on the selected playback mode:

**1. Common Steps (All Modes):**
*   **Parameter Parsing & Validation:** Reads and validates command-line options.
*   **Dependency Check:** Confirms that essential tools (`ffmpeg`, `chafa`, `tput`, `nproc`, `xargs`, `awk`, `bc`, `grep`) are installed.
*   **Temporary Directory Setup:** Creates a temporary directory (e.g., `/dev/shm/hitvid.XXXXXX` or `/tmp/hitvid.XXXXXX`) to store intermediate files. This directory is automatically cleaned up when the script exits.
*   **Video Information Retrieval:** Uses `ffprobe` to get the video's original resolution, duration, and other relevant information.
*   **Frame Extraction (FFmpeg with Pre-scaling):** Uses `ffmpeg` to extract the video into a series of JPG image frames at the specified FPS. Crucially, `ffmpeg` applies a `-vf` (video filter) to pre-scale the frames to an approximate pixel resolution that matches the requested terminal character dimensions (calculated using `CHAR_PIXEL_WIDTH_APPROX` and `CHAR_PIXEL_HEIGHT_APPROX`). This offloads significant scaling work from `chafa` and helps maintain aspect ratio and performance. The JPG frames are saved in the `jpg_frames` subdirectory.

**2. `preload` (Preload) Mode:**
*   **Parallel Chafa Frame Rendering:**
    *   The script waits for all extracted JPG image frames to be available.
    *   It then uses `xargs -P` (parallel execution) to launch multiple `chafa` processes concurrently to convert each JPG frame into a text file containing ANSI escape sequences. These text files represent the character art displayed in the terminal.
    *   The converted text frames are stored in the `chafa_frames` subdirectory.
    *   This step waits for *all* frames to be rendered completely before proceeding to playback, ensuring the smoothest possible experience. Progress is displayed during this phase.
*   **Playback:**
    *   Clears the screen and hides the cursor.
    *   Reads the pre-rendered text frame files from the `chafa_frames` directory in order and outputs their content to the terminal using the `cat` command. `chafa`'s `--clear` option ensures each new frame overwrites the previous one.
    *   Introduces a dynamic `sleep` delay between frames to maintain the desired playback FPS, accounting for the actual time taken to `cat` and display the frame.
    *   Interactive controls (pause, seek, speed change) are handled by non-blocking key reads.
    *   Playback progress and status are displayed on a dedicated line at the bottom of the terminal.

**3. `stream` (Streaming) Mode (Default):**
*   **Background Parallel Chafa Frame Rendering:**
    *   After JPG frame extraction is initiated by `ffmpeg` (running in a background daemon), the script launches a separate `render_chafa_daemon` function **in the background** (as a child process). This function also uses `xargs -P` internally to render Chafa text frames in parallel as soon as their corresponding JPG frames become available. This non-blocking rendering allows playback to begin quickly.
    *   The first frame is typically pre-rendered synchronously for faster initial display.
*   **Playback (Simultaneous Rendering):**
    *   Clears the screen and hides the cursor.
    *   When it's time to play the Nth frame:
        *   It first checks if the corresponding Chafa text frame file (`chafa_frames/frame-XXXXN.txt`) has already been generated by the background renderer.
        *   If the file does not exist, the player pauses its display and waits briefly until the background rendering process generates that file. During this waiting period, it also periodically checks if the background rendering or FFmpeg process has unexpectedly terminated.
        *   Once the frame file is available, its content is immediately `cat`ed to the terminal.
    *   Similar to `preload` mode, a dynamic `sleep` delay maintains the desired FPS, and interactive controls are processed.
    *   Playback progress and status are displayed on a dedicated line at the bottom of the terminal.

**4. Cleanup:**
*   Regardless of how the script exits (normal completion, user interruption via `Ctrl+C`, or an error), a `trap` mechanism ensures that the `cleanup` function is executed.
*   The `cleanup` function restores the terminal settings (`stty sane`), makes the cursor visible (`tput cnorm`), restores the normal screen buffer (`tput rmcup`), and then safely deletes the entire temporary directory and its contents. It also attempts to terminate any lingering background FFmpeg or Chafa rendering processes.

-----

## Notes and Troubleshooting

*   **Performance:** While FFmpeg pre-scaling and parallel Chafa rendering significantly improve performance, playing very high-resolution or high-bitrate videos can still be challenging. The ultimate display speed is limited by your CPU's processing power for `chafa`, `ffmpeg`, and the terminal's ability to render complex ANSI escape sequences quickly. Using `tmpfs` (`/dev/shm`) for temporary files helps mitigate disk I/O bottlenecks.
*   **Terminal Compatibility & Fonts:** Best results are achieved with modern terminals that have robust support for ANSI escape sequences (especially 256-color or true-color, and cursor control), such as `gnome-terminal`, `konsole`, `xterm` (when configured correctly), `iTerm2` (macOS), and Windows Terminal. Monospaced fonts generally provide a more consistent character art display.
*   **Interactive Controls:** The interactive controls work by reading single characters without waiting for Enter. This requires `hitvid` to temporarily modify terminal settings (`stty`). The `cleanup` function attempts to restore `stty sane`, but in rare cases of abnormal termination (e.g., power loss), you might need to run `stty sane` manually in your terminal. Interactive controls are disabled in `--quiet` mode.
*   **Temporary Files:** The script generates many temporary files (JPG image frames and Chafa text frames). Ensure that your chosen temporary directory location (preferably `/dev/shm` if available, otherwise `/tmp`) has enough free space. These files are automatically deleted upon script completion or interruption.
*   **`--threads` Option:** The optimal value for `NUM_THREADS` is usually the number of available CPU cores. Setting it too high might reduce efficiency due to excessive context switching overhead.
*   **Streaming Mode Stuttering:** If you encounter frequent stuttering in `stream` mode, it means that Chafa rendering speed cannot keep up with the playback FPS. You can try:
    *   Lowering the `--fps` playback rate.
    *   Reducing `--colors` (e.g., from `full` to `256`) or `--symbols` (e.g., from `block` to `ascii`).
    *   Increasing `--threads` (if the CPU is not fully utilized).
    *   Switching to `preload` mode for the smoothest playback experience (but with a longer initial waiting time).
*   **Error: `command not found`:** Ensure all dependencies are correctly installed and are in your system's `PATH` environment variable.
*   **FFmpeg Errors:** If the video file is corrupted, its format is not supported by `ffmpeg`, or `ffmpeg` encounters other issues, frame extraction might fail. The script will try to display `ffmpeg`'s error log if not in quiet mode.
*   **Chafa Errors:** If `chafa` fails to process an image (e.g., due to corrupted input), it might produce an empty frame or an error. In `stream` mode, the script is designed to skip missing frames and continue playback, but it will check if the background rendering process has terminated unexpectedly.
