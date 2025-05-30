## `hitvid` v1.0.1 Modification Report: Terminal Alternate Screen Buffer & Security Enhancements

The main contents of this modification include the implementation of the "alternate screen buffer" feature, addressing potential security vulnerabilities, enhancing code robustness, and adjusting default options to improve user experience.

---

### I. Terminal Alternate Screen Buffer Feature Implementation

**Goal:**
Modify the `hitvid` script to play videos in the terminal's **"alternate screen buffer."** This provides a "full-screen" application-like experience where the video player occupies the entire terminal window without affecting previous command output. When the player exits, the original terminal screen and its scroll history will be restored.

**Summary of Changes:**

The core changes involve using `tput` commands to manage the terminal's screen buffers:
* `tput smcup`: Switches to the alternate screen buffer.
* `tput rmcup`: Switches back to the normal screen buffer.

These commands have been integrated into the script's playback and cleanup routines.

**Detailed Modifications:**

1.  **`play_chafa_frames()` function:**
    * **Added `tput smcup`:** At the beginning of this function, `tput smcup` is now called. This command instructs the terminal to switch to its alternate screen buffer *before* displaying any video playback content (such as the initial `clear` or the frames themselves).
    * **Context of `clear` command:** The existing `clear` command in this function now clears the alternate screen buffer, preparing it for video playback.
    * **Removed Redundant Cleanup:** `tput cnorm` (restore cursor) and the `echo -e "\nPlayback complete."` at the end of the function (which might implicitly clear the screen if it's the last output) have been adjusted or are now effectively handled by the `cleanup` function upon exit, ensuring a clean switch back to the normal screen. The "Playback complete" message now briefly appears on the alternate screen's info line, then `cleanup` takes over.

2.  **`cleanup()` function:**
    * **Added `tput rmcup`:** This command has been added to the `cleanup` function. It is responsible for switching the terminal from the alternate screen buffer back to the normal screen buffer.
    * **Order of Operations:** `tput rmcup` is called *after* `tput cnorm` (restoring the cursor). This ensures the cursor is visible first, then the screen is switched. Any subsequent `echo` commands within the `cleanup` function (e.g., "Cleaning up temporary files...") will now display on the restored normal terminal screen.

3.  **`trap` command (in `setup_temp_dir()`):**
    * **Modified to include `EXIT`:** The `trap` command has been updated to `trap "cleanup; exit" INT TERM EXIT`.
    * Adding `EXIT` is crucial. It ensures that the `cleanup` function (and thus `tput cnorm` and `tput rmcup`) is executed not only when the script is interrupted (e.g., `INT` via `Ctrl+C`, or `TERM` via `kill`) but also when the script terminates normally (e.g., when video playback completes and the script reaches its natural end or executes an `exit 0` command).

**Results:**

* When `hitvid` starts, initial messages (e.g., "Analyzing video file...") are displayed on the standard terminal screen.
* Before video playback begins, the terminal switches to an alternate screen. The video will play within this "new" screen.
* When playback ends or the script is interrupted, the `cleanup` function is triggered. This function restores the cursor, switches back to the normal terminal screen (restoring all prior output and scroll history), and then deletes temporary files.
* The user experience is now similar to applications like `vim`, `nano`, or `less`, which use the alternate screen buffer to provide a dedicated interface without interfering with existing terminal content.

---

### II. Security Vulnerability Fixes and Code Enhancements

This section details the security fixes and general code enhancements made to the `hitvid` script. The primary goals were to address potential command injection vulnerabilities and TOCTOU (Time-of-Check, Time-of-Use) race conditions in temporary file handling.

**Overview of Addressed Vulnerabilities:**

1.  **Command Injection:** The original script directly passed user-controlled input (`$VIDEO_PATH`) as arguments to external commands (`ffmpeg`, `ffprobe`) without proper separation. If an attacker could control the value of `VIDEO_PATH` (e.g., by crafting a filename starting with `-`), this could allow them to inject arbitrary command-line options or even execute arbitrary commands.
2.  **TOCTOU (Time-of-Check, Time-of-Use) Race Condition:** The temporary directory created with `mktemp -d` was subsequently removed using `rm -rf "$TEMP_DIR"`. In a multi-user environment, a brief window exists between directory creation and the execution of the `rm` command, which a malicious actor could exploit to replace `$TEMP_DIR` with a symlink pointing to a sensitive directory (e.g., `/home/user/.ssh`), leading to unintended file deletion.

---

#### Detailed Modifications:

#### 1. Command Injection Mitigation

* **Issue:** The `ffprobe`, `ffmpeg`, and `chafa` commands were vulnerable to argument injection if `$VIDEO_PATH` or `$jpg_path` contained malicious characters or started with a hyphen (`-`).
* **Solution:**
    * In the `ffprobe` and `ffmpeg` commands (`get_video_info` and `extract_frames` functions), `--` (double-hyphen) has been added before the `$VIDEO_PATH` argument. The `--` convention tells the command-line parser that all subsequent arguments are non-options (i.e., filenames), preventing them from being interpreted as command flags.
    * Similarly, in the `chafa` command (`render_single_frame_for_xargs` function), `--` has also been added before the `$jpg_path` argument for consistency and best practice, even though `$jpg_path` is internally generated.

#### 2. TOCTOU Vulnerability Mitigation in Temporary Directory Handling

* **Issue:** The `rm -rf "$TEMP_DIR"` command in the `cleanup()` function was vulnerable to TOCTOU attacks.
* **Solution:**
    * **In `setup_temp_dir()`:**
        * Immediately after creating the temporary directory with `mktemp -d`, `chmod 700 "$TEMP_DIR"` has been added. This sets permissions to owner-only read, write, and execute, significantly reducing the window and opportunity for other users to tamper with the directory (e.g., by creating symlinks) before it's used or deleted.
    * **In `cleanup()`:**
        * Robust validation has been implemented before executing `rm -rf`: `if [ -d "$TEMP_DIR" ] && [[ "$TEMP_DIR" == /tmp/hitvid.* ]]`. This check ensures that `$TEMP_DIR` still points to an actual directory and its path matches the expected pattern generated by `mktemp` (`/tmp/hitvid.XXXXXX`). If the path has been tampered with or is not a directory, a warning will be issued, and the deletion operation will be skipped.
        * Used `rm -rf -- "$TEMP_DIR"`: Added `--` to the `rm` command to prevent `$TEMP_DIR` (if maliciously modified to start with `-`) from being interpreted as an option for `rm`.
        * To be foolproof, the `TEMP_DIR` variable is now emptied after cleanup (`TEMP_DIR=""`).
        * For consistency, `--` has also been added for `rm -f -- "$XARGS_FIFO"`, although `XARGS_FIFO` is not actually used in the currently provided script.

#### 3. General Code Enhancements (Non-Security Related but Improves Robustness)

* **Improved Argument Parsing:** The argument parsing loop has been made more robust, capable of handling various input scenarios, including the `--` option separator.
* **Enhanced Input Validation:** More specific error messages and `show_help` calls have been added for invalid command-line options and arguments, making the script easier to use and debug.
* **`ffmpeg` Exit Status Check:** A check for the `ffmpeg` command's exit status has been added in `extract_frames` to provide clearer error reporting if frame extraction fails.
* **Use of `printf`:** Some `echo -e` calls have been replaced with `printf` to improve portability across different shell environments, as `echo -e` behavior can vary.
* **URL Support:** Explicitly stated that `VIDEO_PATH` can be an `http` or `https` URL, as `ffmpeg` supports this functionality.

---

### Impact and Benefits:

These modifications significantly enhance the security of the `hitvid` script by preventing common attack vectors such as command injection and TOCTOU race conditions. The general code enhancements also make the application more robust, reliable, and user-friendly. Users can now run the script with greater confidence, knowing it is less susceptible to malicious input or environmental manipulation.

---

### III. Default Option Modifications

Please compare the changes yourself, as they are not detailed here.