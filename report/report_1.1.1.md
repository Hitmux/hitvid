**Subject: feat: Enhance streaming playback, error handling, and quiet mode (v1.1.1)**

This release introduces significant improvements to `hitvid`, focusing on more robust streaming playback, better error handling, and a refined user experience, especially when using the `--quiet` flag.

**Key Changes & Improvements:**

1.  **Dedicated FFmpeg Monitoring Subshell (`ffmpeg_monitor_subshell`)**:
    *   **Old:** FFmpeg progress monitoring and error logging were intertwined with the `extract_frames_daemon` function, sometimes leading to cluttered output or less reliable error detection.
    *   **New:** A new, dedicated `ffmpeg_monitor_subshell` is introduced. This subshell runs in the background, specifically monitoring the FFmpeg process for health and logging any errors to a file.
    *   **Benefit:** Decouples FFmpeg management from the main script flow, making the playback loop cleaner and more resilient. It also ensures FFmpeg errors are captured and reported even if the main script is busy rendering.

2.  **Improved `--quiet` Mode Behavior**:
    *   **Old:** The `--quiet` flag suppressed *some* progress bars and interactive feedback, but not all, and some daemon messages could still appear. Interactive controls (like pause/seek) were also disabled in quiet mode.
    *   **New:**
        *   `display_progress_bar` now explicitly checks the `QUIET` flag, ensuring no progress bars are shown when quiet.
        *   `render_chafa_daemon` no longer prints verbose progress messages to `stderr` during operation, respecting the quiet mode.
        *   **Crucially, interactive controls (Spacebar for pause/resume, arrow keys for seek/speed) now function even in `--quiet` mode.** Only the *visual feedback* on the info line is suppressed.
        *   The `q` key for quitting has been removed, standardizing on `Ctrl+C` for exiting, which is universally handled by the improved `trap` mechanism.
    *   **Benefit:** Provides a truly "quiet" experience while retaining essential interactive control, offering a better user experience for those who prefer minimal output.

3.  **Enhanced Error Handling and Cleanup**:
    *   **Old:** Cleanup was generally effective but could be improved, and `trap` handling was less specific.
    *   **New:**
        *   The `cleanup` function now explicitly attempts to terminate the new `FFMPEG_MONITOR_PID` in addition to FFmpeg and Chafa daemons.
        *   `trap` commands are more specific (`exit 130` for `INT` / Ctrl+C, `exit 1` for `TERM`/`EXIT`), providing clearer exit codes.
        *   Warning messages during playback (e.g., "Frame missing") are now printed cleanly above the info line using `tput cup` and `tput el`, preventing screen corruption.
    *   **Benefit:** More robust and reliable termination of background processes, cleaner error reporting, and better overall script stability.

4.  **More Accurate Video Information Parsing**:
    *   **Old:** `get_video_info` sometimes struggled with `N/A` or fractional duration/frame rate values from `ffprobe`, potentially leading to incorrect `EXPECTED_TOTAL_FRAMES`.
    *   **New:** The logic for parsing `VIDEO_DURATION_FLOAT` and `EXPECTED_TOTAL_FRAMES` has been refined to better handle various `ffprobe` outputs (decimal, fractional, N/A), providing more accurate frame counts.
    *   **Benefit:** Improves the reliability of frame extraction and playback duration, especially for videos with non-standard metadata.

5.  **Streamlined Playback Initialization**:
    *   **Old:** The `tput smcup; tput civis; clear` commands were executed early, potentially clearing initial FFmpeg loading messages in stream mode.
    *   **New:** These screen manipulation commands are now executed *after* any initial loading messages (including the FFmpeg progress bar from the monitor subshell) have been displayed and cleared.
    *   **Benefit:** Ensures a smoother transition from loading to playback, preventing flicker or premature screen clearing.

This update significantly enhances `hitvid`'s stability, user experience, and internal architecture, making it more reliable and pleasant to use.
