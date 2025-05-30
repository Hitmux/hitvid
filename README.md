# Hitmux `hitvid` - Terminal Video Player

[简体中文](https://github.com/Hitmux/hitvid/blob/main/hitvid_zh.sh) [English](https://github.com/Hitmux/hitvid/blob/main/hitvid.sh)

## [Hitmux Official Website https://hitmux.top](https://hitmux.top)

`hitvid` is a Bash script-based terminal video player that uses `ffmpeg` to extract video frames and `chafa` to render these frames as ASCII art, thereby enabling video playback directly in your terminal.

-----

## Features

  * **In-Terminal Playback:** Watch videos directly in your terminal window.
  * **Multiple Rendering Options:** Supports custom FPS, scaling modes, color counts, dithering algorithms, and character sets.
  * **Two Playback Modes:**
      * **`preload` (Preload Mode - Default):** Extracts all video frames and converts them entirely into Chafa text frames before starting playback. This mode has a longer initial processing time but offers the smoothest playback.
      * **`stream` (Stream Mode):** Extracts all video frames, then processes Chafa text frame conversion in the background while playback begins. The player waits for the currently required frame to finish rendering. This mode allows for quicker playback initiation but may experience stuttering if rendering speed cannot keep up with playback speed.
  * **Parallel Processing:** Utilizes multi-core CPUs to parallelize Chafa frame rendering, significantly speeding up processing in `preload` mode and frame generation in `stream` mode.
  * **Loop Playback:** Supports looping video playback.
  * **Quiet Mode:** Hides progress information, displaying only video content.
  * **Automatic Cleanup:** Automatically cleans up temporary files upon script exit.

-----

## Dependencies

Before running `hitvid`, please ensure the following tools are installed on your system:

  * **`ffmpeg`:** For video decoding and frame extraction.
  * **`chafa`:** For converting image frames into terminal character art.
  * **`tput`:** For terminal control (e.g., clearing screen, hiding/showing cursor).
  * **`nproc`:** (Optional, recommended) Used to get the number of CPU cores for optimizing parallel processing threads. If not installed, it defaults to 4 threads.
  * **`xargs`:** For parallel execution of commands.

**Installation Example (Debian/Ubuntu):**

```bash
sudo apt update
sudo apt install ffmpeg chafa coreutils util-linux
```

(`coreutils` usually includes `nproc`, `util-linux` usually includes `tput`, and `xargs` is typically part of `findutils` or `coreutils`, generally pre-installed on most systems.)

-----

## Usage

```bash
./hitvid.sh [VIDEO_PATH] [OPTIONS]
```

**VIDEO\_PATH:**
Can be the path to a local video file (e.g., `video.mp4`, `/path/to/my/video.avi`) or a directly accessible video URL (e.g., `http://example.com/video.mp4`).

-----

## Options

| Short Opt | Long Opt    | Argument  | Description                                                                  | Default Value             |
| :-------- | :---------- | :-------- | :--------------------------------------------------------------------------- | :------------------------ |
| `-h`      | `--help`    |           | Display this help message and exit.                                          |                           |
| `-f`      | `--fps`     | `FPS`     | Set the playback frames per second.                                          | `15`                      |
| `-s`      | `--scale`   | `MODE`    | Set scaling mode: `fit`, `fill`, `stretch`.                                  | `fit`                     |
| `-c`      | `--colors`  | `NUM`     | Set color mode: `2`, `16`, `256`, `full` (full color).                       | `256`                     |
| `-d`      | `--dither`  | `MODE`    | Set dithering mode: `none`, `ordered`, `diffusion`.                          | `ordered`                 |
| `-y`      | `--symbols` | `SET`     | Set character set: `block`, `ascii`, `space`.                                | `block`                   |
| `-w`      | `--width`   | `WIDTH`   | Set display width (in characters).                                           | Current terminal width    |
| `-t`      | `--height`  | `HEIGHT`  | Set display height (in lines).                                               | Current terminal height - 2 lines |
| `-m`      | `--mode`    | `MODE`    | Set playback mode: `preload`, `stream`.                                      | `preload`                 |
|           | `--threads` | `N`       | Set the number of threads for parallel Chafa rendering.                      | System CPU cores (or 4)   |
| `-q`      | `--quiet`   |           | Quiet mode, suppresses progress and other information output.                | Off                       |
| `-l`      | `--loop`    |           | Loop video playback.                                                         | Off                       |

-----

## Examples

1.  **Basic Playback:**

    ```bash
    ./hitvid.sh my_video.mp4
    ```

2.  **Play at 24 FPS, using full color, and fill the screen:**

    ```bash
    ./hitvid.sh my_video.mp4 --fps 24 --colors full --scale fill
    ```

3.  **Use stream mode, and specify 8 threads for Chafa rendering:**

    ```bash
    ./hitvid.sh my_video.mp4 --mode stream --threads 8
    ```

4.  **Loop playback, and use the ASCII character set:**

    ```bash
    ./hitvid.sh animation.gif --loop --symbols ascii
    ```

5.  **Quiet playback, with custom width and height:**

    ```bash
    ./hitvid.sh short_clip.mkv --quiet --width 80 --height 24
    ```

-----

## Workflow

The `hitvid` workflow varies depending on the selected playback mode:

**1. General Steps (All Modes):**
\* **Parameter Parsing:** Reads command-line options provided by the user.
\* **Dependency Check:** Confirms that necessary tools like `ffmpeg`, `chafa` are installed.
\* **Temporary Directory Setup:** Creates a temporary directory (e.g., `/tmp/hitvid.XXXXXX`) to store intermediate files. This directory is automatically cleaned up when the script exits.
\* **Video Information Retrieval:** Uses `ffprobe` to get video original resolution, duration, etc.
\* **Frame Extraction (FFmpeg):** Uses `ffmpeg` to extract video frames as a series of JPG images at the specified FPS, storing them in a `jpg_frames` subdirectory within the temporary directory.

**2. `preload` Mode (Default):**
\* **Parallel Chafa Frame Rendering:**
\* The script iterates through all extracted JPG image frames.
\* It uses `xargs -P` to launch multiple `chafa` processes in parallel, converting each JPG frame into a text file containing ANSI escape sequences. These text files represent the character art displayed in the terminal.
\* The converted text frames are stored in the `chafa_frames` subdirectory within the temporary directory.
\* This step waits until all frames are rendered before proceeding.
\* **Playback:**
\* Clears the screen and hides the cursor.
\* Reads the text frame files from the `chafa_frames` directory in order and outputs their content to the terminal using the `cat` command. Since `chafa` includes the `--clear` option when generating text frames, each new frame overwrites the area of the previous one.
\* A brief `sleep` is performed between frames according to the set FPS.
\* After playback, the cursor is restored, and completion information is displayed.

**3. `stream` Mode:**
\* **Background Chafa Frame Parallel Rendering:**
\* After JPG frame extraction is complete, the script launches the `render_all_chafa_frames_parallel` function **in the background**. This function also uses `xargs -P` to render Chafa text frames in parallel.
\* The main script **does not** wait for all frames to render; instead, it immediately proceeds to the playback stage.
\* **Playback (Simultaneous Rendering):**
\* Clears the screen and hides the cursor.
\* When the Nth frame needs to be played:
\* It checks if the corresponding Chafa text frame file (`chafa_frames/frame-XXXXN.txt`) exists.
\* If the file does not exist, the player pauses and waits until the background rendering process generates that file. During this time, it also checks if the background rendering process has unexpectedly terminated.
\* Once the file exists, its content is immediately `cat`ed to the terminal.
\* A brief `sleep` is performed between frames according to the set FPS.
\* After playback, if the background rendering process is still running, the script waits for it to complete before exiting.

**4. Cleanup:**
\* Regardless of how the script exits (normal completion, user interruption Ctrl+C, error), a `trap` mechanism ensures that the `cleanup` function is executed.
\* The `cleanup` function restores the terminal cursor display and deletes the entire temporary directory and its contents. If the background rendering process is still running, it attempts to terminate it.

-----Sure, here's the English version of the `hitvid` terminal video player documentation:

-----

# Hitmux `hitvid` - Terminal Video Player

## [Hitmux Official Website https://hitmux.top](https://hitmux.top)

`hitvid` is a Bash script-based terminal video player that uses `ffmpeg` to extract video frames and `chafa` to render these frames as ASCII art, thereby enabling video playback directly in your terminal.

-----

## Features

  * **In-Terminal Playback:** Watch videos directly in your terminal window.
  * **Multiple Rendering Options:** Supports custom FPS, scaling modes, color counts, dithering algorithms, and character sets.
  * **Two Playback Modes:**
      * **`preload` (Preload Mode - Default):** Extracts all video frames and converts them entirely into Chafa text frames before starting playback. This mode has a longer initial processing time but offers the smoothest playback.
      * **`stream` (Stream Mode):** Extracts all video frames, then processes Chafa text frame conversion in the background while playback begins. The player waits for the currently required frame to finish rendering. This mode allows for quicker playback initiation but may experience stuttering if rendering speed cannot keep up with playback speed.
  * **Parallel Processing:** Utilizes multi-core CPUs to parallelize Chafa frame rendering, significantly speeding up processing in `preload` mode and frame generation in `stream` mode.
  * **Loop Playback:** Supports looping video playback.
  * **Quiet Mode:** Hides progress information, displaying only video content.
  * **Automatic Cleanup:** Automatically cleans up temporary files upon script exit.

-----

## Dependencies

Before running `hitvid`, please ensure the following tools are installed on your system:

  * **`ffmpeg`:** For video decoding and frame extraction.
  * **`chafa`:** For converting image frames into terminal character art.
  * **`tput`:** For terminal control (e.g., clearing screen, hiding/showing cursor).
  * **`nproc`:** (Optional, recommended) Used to get the number of CPU cores for optimizing parallel processing threads. If not installed, it defaults to 4 threads.
  * **`xargs`:** For parallel execution of commands.

**Installation Example (Debian/Ubuntu):**

```bash
sudo apt update
sudo apt install ffmpeg chafa coreutils util-linux
```

(`coreutils` usually includes `nproc`, `util-linux` usually includes `tput`, and `xargs` is typically part of `findutils` or `coreutils`, generally pre-installed on most systems.)

-----

## Usage

```bash
./hitvid.sh [VIDEO_PATH] [OPTIONS]
```

**VIDEO\_PATH:**
Can be the path to a local video file (e.g., `video.mp4`, `/path/to/my/video.avi`) or a directly accessible video URL (e.g., `http://example.com/video.mp4`).

-----

## Options

| Short Opt | Long Opt    | Argument  | Description                                                                  | Default Value             |
| :-------- | :---------- | :-------- | :--------------------------------------------------------------------------- | :------------------------ |
| `-h`      | `--help`    |           | Display this help message and exit.                                          |                           |
| `-f`      | `--fps`     | `FPS`     | Set the playback frames per second.                                          | `15`                      |
| `-s`      | `--scale`   | `MODE`    | Set scaling mode: `fit`, `fill`, `stretch`.                                  | `fit`                     |
| `-c`      | `--colors`  | `NUM`     | Set color mode: `2`, `16`, `256`, `full` (full color).                       | `256`                     |
| `-d`      | `--dither`  | `MODE`    | Set dithering mode: `none`, `ordered`, `diffusion`.                          | `ordered`                 |
| `-y`      | `--symbols` | `SET`     | Set character set: `block`, `ascii`, `space`.                                | `block`                   |
| `-w`      | `--width`   | `WIDTH`   | Set display width (in characters).                                           | Current terminal width    |
| `-t`      | `--height`  | `HEIGHT`  | Set display height (in lines).                                               | Current terminal height - 2 lines |
| `-m`      | `--mode`    | `MODE`    | Set playback mode: `preload`, `stream`.                                      | `preload`                 |
|           | `--threads` | `N`       | Set the number of threads for parallel Chafa rendering.                      | System CPU cores (or 4)   |
| `-q`      | `--quiet`   |           | Quiet mode, suppresses progress and other information output.                | Off                       |
| `-l`      | `--loop`    |           | Loop video playback.                                                         | Off                       |

-----

## Examples

1.  **Basic Playback:**

    ```bash
    ./hitvid.sh my_video.mp4
    ```

2.  **Play at 24 FPS, using full color, and fill the screen:**

    ```bash
    ./hitvid.sh my_video.mp4 --fps 24 --colors full --scale fill
    ```

3.  **Use stream mode, and specify 8 threads for Chafa rendering:**

    ```bash
    ./hitvid.sh my_video.mp4 --mode stream --threads 8
    ```

4.  **Loop playback, and use the ASCII character set:**

    ```bash
    ./hitvid.sh animation.gif --loop --symbols ascii
    ```

5.  **Quiet playback, with custom width and height:**

    ```bash
    ./hitvid.sh short_clip.mkv --quiet --width 80 --height 24
    ```

-----

## Workflow

The `hitvid` workflow varies depending on the selected playback mode:

**1. General Steps (All Modes):**
\* **Parameter Parsing:** Reads command-line options provided by the user.
\* **Dependency Check:** Confirms that necessary tools like `ffmpeg`, `chafa` are installed.
\* **Temporary Directory Setup:** Creates a temporary directory (e.g., `/tmp/hitvid.XXXXXX`) to store intermediate files. This directory is automatically cleaned up when the script exits.
\* **Video Information Retrieval:** Uses `ffprobe` to get video original resolution, duration, etc.
\* **Frame Extraction (FFmpeg):** Uses `ffmpeg` to extract video frames as a series of JPG images at the specified FPS, storing them in a `jpg_frames` subdirectory within the temporary directory.

**2. `preload` Mode (Default):**
\* **Parallel Chafa Frame Rendering:**
\* The script iterates through all extracted JPG image frames.
\* It uses `xargs -P` to launch multiple `chafa` processes in parallel, converting each JPG frame into a text file containing ANSI escape sequences. These text files represent the character art displayed in the terminal.
\* The converted text frames are stored in the `chafa_frames` subdirectory within the temporary directory.
\* This step waits until all frames are rendered before proceeding.
\* **Playback:**
\* Clears the screen and hides the cursor.
\* Reads the text frame files from the `chafa_frames` directory in order and outputs their content to the terminal using the `cat` command. Since `chafa` includes the `--clear` option when generating text frames, each new frame overwrites the area of the previous one.
\* A brief `sleep` is performed between frames according to the set FPS.
\* After playback, the cursor is restored, and completion information is displayed.

**3. `stream` Mode:**
\* **Background Chafa Frame Parallel Rendering:**
\* After JPG frame extraction is complete, the script launches the `render_all_chafa_frames_parallel` function **in the background**. This function also uses `xargs -P` to render Chafa text frames in parallel.
\* The main script **does not** wait for all frames to render; instead, it immediately proceeds to the playback stage.
\* **Playback (Simultaneous Rendering):**
\* Clears the screen and hides the cursor.
\* When the Nth frame needs to be played:
\* It checks if the corresponding Chafa text frame file (`chafa_frames/frame-XXXXN.txt`) exists.
\* If the file does not exist, the player pauses and waits until the background rendering process generates that file. During this time, it also checks if the background rendering process has unexpectedly terminated.
\* Once the file exists, its content is immediately `cat`ed to the terminal.
\* A brief `sleep` is performed between frames according to the set FPS.
\* After playback, if the background rendering process is still running, the script waits for it to complete before exiting.

**4. Cleanup:**
\* Regardless of how the script exits (normal completion, user interruption Ctrl+C, error), a `trap` mechanism ensures that the `cleanup` function is executed.
\* The `cleanup` function restores the terminal cursor display and deletes the entire temporary directory and its contents. If the background rendering process is still running, it attempts to terminate it.

-----

## Notes and Troubleshooting

  * **Performance:** Playing very high-resolution or high-bitrate videos might be choppy, and even in `preload` mode, the initial processing time can be very long. The processing capability of the terminal itself is also a limiting factor.
  * **Terminal Compatibility:** Best results are achieved with terminals that have good support for ANSI escape sequences (especially colors and cursor control), such as `gnome-terminal`, `konsole`, `xterm` (when configured correctly), `iTerm2` (macOS), and Windows Terminal.
  * **Font:** The font used by the terminal can affect the display quality of the character art. Monospaced fonts generally work better.
  * **Temporary Files:** The script generates a fair number of temporary files (JPG image frames and Chafa text frames). Ensure that the `/tmp` directory has sufficient space. These files are automatically deleted when the script finishes.
  * **`--threads` Option:** The optimal value for `NUM_THREADS` is usually the number of CPU cores. Setting it too high might reduce efficiency due to excessive context switching.
  * **Stuttering in Stream Mode:** If you experience frequent stuttering in `stream` mode, it means that Chafa rendering cannot keep up with the FPS. You can try:
      * Lowering `--fps`.
      * Reducing `--colors` (e.g., from `full` to `256`).
      * Increasing `--threads` (if the CPU is not fully utilized).
      * Switching back to `preload` mode for the smoothest playback experience (but with a longer initial waiting time).
  * **Error: `command not found`:** Ensure all dependencies are correctly installed and are in your system's `PATH` environment variable.
  * **FFmpeg Errors:** If the video file is corrupted or its format is not supported by `ffmpeg`, frame extraction might fail. The script will attempt to display `ffmpeg`'s error log.

-----

## Contribution

Improvements and feature additions to the script are welcome. You can submit your changes via Pull Requests.

## Notes and Troubleshooting

  * **Performance:** Playing very high-resolution or high-bitrate videos might be choppy, and even in `preload` mode, the initial processing time can be very long. The processing capability of the terminal itself is also a limiting factor.
  * **Terminal Compatibility:** Best results are achieved with terminals that have good support for ANSI escape sequences (especially colors and cursor control), such as `gnome-terminal`, `konsole`, `xterm` (when configured correctly), `iTerm2` (macOS), and Windows Terminal.
  * **Font:** The font used by the terminal can affect the display quality of the character art. Monospaced fonts generally work better.
  * **Temporary Files:** The script generates a fair number of temporary files (JPG image frames and Chafa text frames). Ensure that the `/tmp` directory has sufficient space. These files are automatically deleted when the script finishes.
  * **`--threads` Option:** The optimal value for `NUM_THREADS` is usually the number of CPU cores. Setting it too high might reduce efficiency due to excessive context switching.
  * **Stuttering in Stream Mode:** If you experience frequent stuttering in `stream` mode, it means that Chafa rendering cannot keep up with the FPS. You can try:
      * Lowering `--fps`.
      * Reducing `--colors` (e.g., from `full` to `256`).
      * Increasing `--threads` (if the CPU is not fully utilized).
      * Switching back to `preload` mode for the smoothest playback experience (but with a longer initial waiting time).
  * **Error: `command not found`:** Ensure all dependencies are correctly installed and are in your system's `PATH` environment variable.
  * **FFmpeg Errors:** If the video file is corrupted or its format is not supported by `ffmpeg`, frame extraction might fail. The script will attempt to display `ffmpeg`'s error log.

