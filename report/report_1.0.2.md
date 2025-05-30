**`hitvid` Script Modification Report**

**Overview**

The new version of the `hitvid` script introduces significant functional enhancements and user experience (UX) optimizations over its predecessor. Key changes include the introduction of interactive playback controls (pause, seek forward/backward, speed adjustment), optimized frame processing performance (e.g., attempting to use the RAM disk `/dev/shm` for temporary file storage, FFmpeg pre-scaling), considerably improved user feedback mechanisms (such as progress bars for time-consuming operations), along with several code refactorings and enhancements to error handling.

**Detailed Change Points**

1.  **New Interactive Playback Controls**
    *   **Scope of Impact**: Core logic of `play_chafa_frames` function, `show_help` message, new global variables.
    *   **Specific Changes**:
        *   In `play_chafa_frames`, user input is read non-blockingly using `read -t`.
        *   **Supported Controls**:
            *   `Spacebar`: Pause/Resume playback.
            *   `Right Arrow Key`: Seek forward (by `SEEK_SECONDS`, default 5 seconds).
            *   `Left Arrow Key`: Seek backward (by `SEEK_SECONDS`).
            *   `Up Arrow Key`: Increase playback speed.
            *   `Down Arrow Key`: Decrease playback speed.
        *   New related global variables:
            *   `PAUSED`: Flags the paused state.
            *   `ORIGINAL_FPS`: Stores the user-defined or default original extraction frame rate.
            *   `CURRENT_FPS_MULTIPLIER_INDEX`: Index to control the playback speed multiplier.
            *   `PLAYBACK_SPEED_MULTIPLIERS`: Defines an array of available playback speed multipliers (e.g., 0.25x, 0.5x, 1.0x, 2.0x).
            *   `SEEK_SECONDS`: Defines the seek duration in seconds.
        *   `show_help`: Added an "Interactive Controls" section to explain these new features.
    *   **Purpose**: Greatly enhances user flexibility and control while watching videos.

2.  **Performance Optimizations**
    *   **Temporary File Storage Optimization (`setup_temp_dir`)**:
        *   Prioritizes creating the temporary directory in `/dev/shm` (tmpfs, a memory-based file system). If successful, this can significantly improve the read/write speed of frame files, especially for many small files.
        *   If `/dev/shm` is unavailable or creation fails, it falls back to the traditional `/tmp` directory.
    *   **FFmpeg Pre-scaling (`extract_frames`)**:
        *   New constants `CHAR_PIXEL_WIDTH_APPROX` and `CHAR_PIXEL_HEIGHT_APPROX` are introduced to estimate pixel dimensions corresponding to character cells.
        *   Based on the target display character width (`WIDTH`) and height (`HEIGHT`), calculates target pixel dimensions for FFmpeg pre-scaling.
        *   Adds a `scale` filter (and potentially `crop` depending on `SCALE_MODE`) to the `ffmpeg` command's `-vf` (video filter) option. This allows FFmpeg to scale frames to a size close to what Chafa requires during extraction.
        *   **Purpose**: Reduces Chafa's scaling workload, potentially improving Chafa's rendering speed and the visual consistency of the final output.
    *   **Stream Mode First-Frame Pre-rendering (Main Execution Block for `stream` mode)**:
        *   In `stream` mode, the script now attempts to synchronously render the first frame of the video before launching the background process to render the remaining frames.
        *   **Purpose**: Reduces the waiting time for the user to see the first frame in stream mode, improving the startup experience.

3.  **User Experience (UX) Enhancements**
    *   **Progress Bar Display**:
        *   New helper function `display_progress_bar` added to generate and display text-based progress bars.
        *   `extract_frames`: In non-quiet mode, uses the `ffmpeg -progress` option to output progress information to a file. The script reads this file to display a real-time progress bar for FFmpeg frame extraction.
        *   `render_all_chafa_frames_parallel`: In `preload` mode and non-quiet mode, displays a rendering progress bar by polling the number of generated Chafa text frames.
        *   `play_chafa_frames`: The information line during playback now includes a more intuitive progress bar showing the current playback position.
    *   **Clarification of FPS Parameter Semantics**:
        *   The help description for the `--fps` command-line option is updated to "Set extraction frames per second."
        *   The `ORIGINAL_FPS` variable is introduced to store this extraction frame rate. The actual frame delay during playback is calculated based on this original FPS and the current playback speed multiplier.
    *   **More Detailed Output Information**:
        *   `get_video_info`: Output now includes the total number of input frames in the video (if provided by ffprobe).
        *   `extract_frames`: Outputs the video filter options used by FFmpeg.
        *   Richer informational messages for various stages (e.g., temporary directory location, renderer PID).
    *   **Terminal State Restoration (`cleanup`)**:
        *   Added the `stty sane` command to ensure terminal settings are restored to a "sane" known-good state upon script exit (including abnormal exits).
    *   **Help Message (`show_help`)**:
        *   Updated descriptions for `-f, --fps` and `-s, --scale` options for better accuracy.
        *   Added a note about how `-q, --quiet` mode affects interactive feedback.

4.  **Functional Improvements & Refactoring**
    *   **Dependency Check (`check_dependencies`)**:
        *   Added a dependency check for `awk`, as it's now used for floating-point arithmetic (e.g., calculating frame delay, comparing FPS values).
    *   **Argument Parsing and Validation**:
        *   The file existence check for `VIDEO_PATH` now correctly handles network stream URLs (e.g., `http*`, `ftp*`, `rtmp*`) and standard input (`-`), for which local file existence should not be checked.
        *   Parameter validations involving floating-point numbers (e.g., `FPS > 0`, `FPS > MAX_FPS`) are now implemented using `awk`, which is more suitable for floating-point operations than Bash built-ins.
        *   If an unknown option is provided, the script now shows the help message instead of directly exiting with an error.
    *   **Chafa Options and Environment**:
        *   The definition of the `CHAFA_OPTS_RENDER` variable is moved to the main execution flow, after `extract_frames` and before calling `render_all_chafa_frames_parallel` or `render_single_frame_for_xargs`.
        *   In the `render_all_chafa_frames_parallel` function, when `xargs` is used to execute `render_single_frame_for_xargs`, variables like `CHAFA_OPTS_RENDER`, `JPG_FRAMES_DIR`, `CHAFA_FRAMES_DIR`, and `QUIET` are explicitly `export`ed to ensure sub-shells correctly inherit these environment variables.
    *   **FFmpeg Invocation (`extract_frames`)**:
        *   The `ffmpeg` command now includes the `-nostdin` option to prevent it from accidentally consuming standard input, which is crucial for the subsequent interactive key reading.
    *   **Playback Timing (`play_chafa_frames`)**:
        *   The calculation of the `sleep` duration after each frame now considers the actual processing time for that frame (reading file, `cat` output, etc.), making the frame interval closer to the target frame rate.
        *   `frame_delay` calculation is now based on `ORIGINAL_FPS * PLAYBACK_SPEED_MULTIPLIER`.
    *   **Error Handling**:
        *   In stream mode, if the background renderer process (`RENDER_PID`) terminates unexpectedly and the required frame file is missing, a more specific error message is displayed before exiting.

5.  **Code Cleanup & Minor Adjustments**
    *   Removed the cleanup logic for `XARGS_FIFO` from the `cleanup` function, as it was mentioned in the old version but not actually used.
    *   In `render_single_frame_for_xargs`, when the source JPG file doesn't exist, the check for `QUIET` is removed, and it directly returns an error code (as warnings go to stderr, and the progress bar is the primary user feedback).
    *   Other minor updates to comments and code formatting for improved readability.

**Conclusion**

The new version of `hitvid`, by introducing interactive controls, optimizing performance, and improving the user interface, significantly enhances its usability and user-friendliness as a terminal video player. These modifications make the script more powerful, easier to operate, and provide a smoother experience.