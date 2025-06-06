## `hitvid` Version Improvement Technical Report

**Project Name:** `hitvid` - Terminal Video Player

**Version:** From `v1.0.2` to `v1.1.0`

**Date:** June 1, 2025

**Core Maintainer:** Hitmux

---

### 1. Overview

`hitvid v1.1.0` represents a significant iteration in the `hitvid` project concerning performance and architectural stability. The primary goal of this version is to address the synchronization issues between Chafa rendering and video playback present in `v1.0.2`, and to significantly enhance the user experience, particularly playback fluidity under high frame rate and resource-constrained environments. By introducing Chafa rendering daemonization and optimizing the frame processing pipeline, we have successfully decoupled the rendering logic from the main playback loop, achieving a more truly streaming playback experience.

### 2. Key Improvements

#### 2.1 Chafa Rendering Architecture Refactor

This is the most crucial improvement in `v1.1.0`.

* **`v1.0.2` (Old Architecture):**
    In `v1.0.2`, Chafa frame generation was initiated in the background as a parallel process via the `render_all_chafa_frames_parallel &` function. The main playback function `play_chafa_frames` relied on these background rendering processes to complete the generation of text frames. Although background execution was used, implicit synchronization points (via the file system) between the rendering and playback processes, and the eventual `wait "$RENDER_PID"` command, could still lead to blocking and stuttering during playback, especially if rendering speed could not keep up with playback speed.

    ```bash
    # v1.0.2 Core Rendering Startup Logic
    render_all_chafa_frames_parallel &
    RENDER_PID=$!
    # ...
    play_chafa_frames
    # ...
    wait "$RENDER_PID" # Wait for rendering process to complete
    ```

* **`v1.1.0` (New Architecture):**
    `v1.1.0` introduces the `render_chafa_daemon` function, fundamentally changing how Chafa frames are generated. Now, `render_chafa_daemon` operates as an independent, long-running daemon process (`CHAFA_RENDER_DAEMON_PID`). It continuously reads the latest JPG frames from the `JPG_FRAMES_DIR` (generated by FFmpeg) and converts them in real-time into Chafa text frames, storing them in `CHAFA_FRAMES_DIR`.

    The main playback function `play_chafa_frames` no longer directly waits for rendering completion. Instead, it independently reads available text frames from `CHAFA_FRAMES_DIR` for display. This design achieves complete decoupling of rendering and playback, with `play_chafa_frames` acting as a "consumer" and `render_chafa_daemon` as a "producer."

    ```bash
    # v1.1.0 Core Rendering Startup Logic
    render_chafa_daemon "$EXPECTED_TOTAL_FRAMES" "$FFMPEG_PID" # Start the daemon
    # ...
    play_chafa_frames "$EXPECTED_TOTAL_FRAMES" # Play independently, reading from files output by the daemon
    # ...
    # At the end of playback, clean up the daemon
    if [[ -n "$CHAFA_RENDER_DAEMON_PID" ]] && ps -p "$CHAFA_RENDER_DAEMON_PID" > /dev/null; then
        kill -TERM "$CHAFA_RENDER_DAEMON_PID"
        wait "$CHAFA_RENDER_DAEMON_PID" 2>/dev/null
    fi
    ```

* **Technical Advantages:**
    * **High Throughput & Low Latency:** The rendering process can work continuously, unblocked by the playback process, maximizing Chafa conversion throughput. The playback process can consume the latest rendered frames immediately, reducing display latency.
    * **Playback Fluidity:** Eliminates playback stuttering caused by rendering bottlenecks in the old version, achieving smoother video streams.
    * **Improved Resource Utilization:** The rendering process can continuously utilize idle CPU cycles in the background, improving overall system resource efficiency.
    * **Robustness:** A crash in the rendering process no longer directly leads to the failure of the main playback logic, enhancing application stability.

#### 2.2 First Frame Pre-rendering Optimization

To provide more immediate visual feedback at the start of video playback, `v1.1.0` improves the pre-rendering logic for the first frame.

* **`v1.0.2`:** Simply called `render_single_frame_for_xargs "$first_jpg_basename"` and expected it to complete quickly. The first frame output went directly to standard output.
* **`v1.1.0`:**
    * Added a loop (`wait_first_jpg_count`) to wait for the first JPG frame to be generated, ensuring the JPG file exists before attempting to render it.
    * Redirects the Chafa rendering result of the first frame directly to the `first_txt_to_create` file, rather than standard output. This ensures the first text file is available before playback.
    * Provides more explicit error and warning messages, e.g., when the FFmpeg process fails to generate the first JPG frame in time.

    ```bash
    # v1.1.0 First Frame Pre-rendering Logic
    wait_first_jpg_count=0
    while [ ! -f "$first_jpg_to_check" ] && [ "$wait_first_jpg_count" -lt 50 ] && [[ -n "$FFMPEG_PID" ]] && ps -p "$FFMPEG_PID" >/dev/null; do
        sleep 0.01
        wait_first_jpg_count=$((wait_first_jpg_count + 1))
    done

    if [ -f "$first_jpg_to_check" ]; then
        (chafa $CHAFA_OPTS_RENDER "$first_jpg_to_check" > "$first_txt_to_create")
        if [ $QUIET -eq 0 ] && [ -f "$first_txt_to_create" ]; then echo "First frame pre-rendered to $first_txt_to_create."; fi
    elif [ $QUIET -eq 0 ]; then
        echo "Warning: Could not pre-render first frame quickly. FFmpeg PID: ${FFMPEG_PID:-N/A}. File: $first_jpg_to_check"
    fi
    ```

* **Technical Advantages:** Reduces the startup latency of video playback, improving the perceived responsiveness for the user.

#### 2.3 Process ID (PID) Management and Cleanup

`v1.1.0` introduces clearer PID management for background processes.

* **`v1.0.2`:** Primarily focused on `RENDER_PID`.
* **`v1.1.0`:** Explicitly defines and uses `FFMPEG_PID` and `CHAFA_RENDER_DAEMON_PID` as two key background process IDs. At the end of the script, `kill -TERM` and `wait` commands are used to ensure these background processes are correctly terminated and cleaned up, preventing zombie processes.

* **Technical Advantages:** Enhances script robustness and resource management capabilities, reducing the risk of system resource leaks.

### 3. Future Work

* **"preload" Playback Mode:** The `PLAY_MODE="preload"` option is commented out in the code but not yet implemented. Future work could include implementing this mode, where all Chafa frames are fully rendered before playback begins, suitable for short videos or scenarios requiring the highest possible fluidity.
* **More Granular Error Handling:** Enhance error handling for abnormal exits of FFmpeg and Chafa processes, providing more user-friendly error messages.
* **Interactive Control Optimization:** Further optimize the responsiveness and user experience of playback controls (pause, fast-forward, rewind).
