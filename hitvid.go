// Copyright (C) 2025 Hitmux
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.


package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/term"
)

// --- Command-line Flags ---
var (
	videoPath  string
	fps        int
	symbols    string
	colors     string
	dither     string
	width      int
	height     int
	numThreads int
	showHelp   bool
)

// --- Global Playback State & Config ---
var (
	// Playback state
	isPaused                    = false
	currentFrameIndex           = 0
	totalFrames                 = 0
	extractionComplete          = false
	currentSpeedMultiplierIndex = 3 // Index for 1.0x speed

	// Playback configuration
	playbackSpeedMultipliers = []float64{0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0}
	seekAmountInFrames       = 0

	// Concurrency
	stateMutex        sync.Mutex
	frameReadyCond    *sync.Cond
	renderedFrames    [][]byte
	lastRenderedFrame = -1
	userAction        = ""
)

const seekSeconds = 5

var supportedVideoExtensions = map[string]bool{
	".mp4": true, ".mkv": true, ".mov": true, ".avi": true, ".webm": true, ".flv": true,
}

// getPlaylist scans a directory for video files and returns a sorted list.
func getPlaylist(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var playlist []string
	for _, entry := range entries {
		if !entry.IsDir() {
			ext := strings.ToLower(filepath.Ext(entry.Name()))
			if supportedVideoExtensions[ext] {
				playlist = append(playlist, filepath.Join(dir, entry.Name()))
			}
		}
	}
	sort.Strings(playlist)
	return playlist, nil
}

// getVideoDuration uses ffprobe to get the video duration in seconds.
func getVideoDuration(ctx context.Context, videoPath string) (float64, error) {
	cmd := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", videoPath)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return 0, fmt.Errorf("ffprobe failed: %w", err)
	}
	durationStr := strings.TrimSpace(out.String())
	duration, err := strconv.ParseFloat(durationStr, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse duration from ffprobe: %w", err)
	}
	return duration, nil
}

// formatTime converts a frame index into a MM:SS time string.
func formatTime(frameIndex int, frameRate int) string {
	if frameRate <= 0 {
		return "00:00"
	}
	seconds := frameIndex / frameRate
	minutes := seconds / 60
	seconds = seconds % 60
	return fmt.Sprintf("%02d:%02d", minutes, seconds)
}

// handleInput processes keyboard events for playback control.
func handleInput(cancel context.CancelFunc) {
	buf := make([]byte, 3)
	for {
		// Check if the input handler should terminate
		stateMutex.Lock()
		action := userAction
		stateMutex.Unlock()
		if action == "quit" {
			return
		}

		n, err := os.Stdin.Read(buf)
		if err != nil {
			return
		}

		stateMutex.Lock()
		switch {
		case n == 1 && (buf[0] == 'q' || buf[0] == 3): // 'q' or Ctrl+C
			userAction = "quit"
			cancel()
		case n == 1 && buf[0] == ' ':
			isPaused = !isPaused
		case n == 1 && buf[0] == '+': // Increase speed
			if currentSpeedMultiplierIndex < len(playbackSpeedMultipliers)-1 {
				currentSpeedMultiplierIndex++
			}
		case n == 1 && buf[0] == '-': // Decrease speed
			if currentSpeedMultiplierIndex > 0 {
				currentSpeedMultiplierIndex--
			}
		case n == 3 && buf[0] == '\x1b' && buf[1] == '[': // Arrow keys
			switch buf[2] {
			case 'A': // Up Arrow: Previous video
				userAction = "prev"
				cancel()
			case 'B': // Down Arrow: Next video
				userAction = "next"
				cancel()
			case 'C': // Right Arrow: Seek forward
				currentFrameIndex += seekAmountInFrames
				if totalFrames > 0 && currentFrameIndex >= totalFrames {
					currentFrameIndex = totalFrames - 1
				}
			case 'D': // Left Arrow: Seek backward
				currentFrameIndex -= seekAmountInFrames
				if currentFrameIndex < 0 {
					currentFrameIndex = 0
				}
			}
		}
		stateMutex.Unlock()
	}
}

// playVideo handles the entire lifecycle of playing one video.
// It returns the action the user took (e.g., "next", "prev", "quit") or "finished".
func playVideo(ctx context.Context, path string) string {
	// --- Reset state for the new video ---
	stateMutex.Lock()
	isPaused = false
	currentFrameIndex = 0
	totalFrames = 0
	extractionComplete = false
	renderedFrames = make([][]byte, 0, 2048)
	lastRenderedFrame = -1
	userAction = "" // Clear previous action
	stateMutex.Unlock()

	// --- Get video info ---
	videoDuration, err := getVideoDuration(ctx, path)
	if err != nil {
		log.Printf("Warning: Could not get video duration for %s: %v\r\n", path, err)
	} else {
		stateMutex.Lock()
		totalFrames = int(videoDuration * float64(fps))
		stateMutex.Unlock()
	}

	// --- Setup temp dir ---
	tempDir, err := os.MkdirTemp("", "hitvid-go-*")
	if err != nil {
		log.Fatalf("Failed to create temp directory: %v", err)
	}
	defer os.RemoveAll(tempDir)
	jpgDir := filepath.Join(tempDir, "jpg_frames")
	os.Mkdir(jpgDir, 0755)

	// --- Setup rendering pipeline ---
	type renderJob struct {
		index   int
		jpgPath string
	}
	var wgRender sync.WaitGroup
	jobs := make(chan renderJob, 100)
	for i := 0; i < numThreads; i++ {
		wgRender.Add(1)
		go func() {
			defer wgRender.Done()
			for job := range jobs {
				chafaArgs := []string{"--size", fmt.Sprintf("%dx%d", width, height), "--symbols", symbols, "--colors", colors, "--dither", dither, job.jpgPath}
				chafaCmd := exec.CommandContext(ctx, "chafa", chafaArgs...)
				output, err := chafaCmd.Output()
				if err != nil {
					if ctx.Err() == nil {
						log.Printf("chafa failed for %s: %v\r\n", job.jpgPath, err)
					}
					output = nil
				}
				if runtime.GOOS != "windows" && output != nil {
					output = bytes.ReplaceAll(output, []byte("\n"), []byte("\r\n"))
				}
				// CRITICAL FIX: This section is now simplified to remove the faulty conditional check.
				// It now guarantees a broadcast for every job received, fixing the deadlock.
				stateMutex.Lock()
				renderedFrames[job.index] = output
				lastRenderedFrame = job.index
				frameReadyCond.Broadcast()
				stateMutex.Unlock()
			}
		}()
	}

	// --- Start dispatcher and ffmpeg ---
	go func() {
		dispatchedFrameIndex := 0
		for {
			if ctx.Err() != nil {
				break
			}
			framePath := filepath.Join(jpgDir, fmt.Sprintf("frame-%05d.jpg", dispatchedFrameIndex+1))
			if _, err := os.Stat(framePath); err == nil {
				stateMutex.Lock()
				if len(renderedFrames) <= dispatchedFrameIndex {
					renderedFrames = append(renderedFrames, nil)
				}
				stateMutex.Unlock()
				jobs <- renderJob{index: dispatchedFrameIndex, jpgPath: framePath}
				dispatchedFrameIndex++
			} else {
				stateMutex.Lock()
				isDone := extractionComplete
				stateMutex.Unlock()
				if isDone {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
		}
		close(jobs)
	}()

	ffmpegVF := fmt.Sprintf("fps=%d,scale='min(iw,%d)':-1", fps, width*8)
	ffmpegArgs := []string{"-nostdin", "-hide_banner", "-loglevel", "warning", "-i", path, "-vf", ffmpegVF, "-q:v", "2", filepath.Join(jpgDir, "frame-%05d.jpg")}
	ffmpegCmd := exec.CommandContext(ctx, "ffmpeg", ffmpegArgs...)
	var ffmpegErr bytes.Buffer
	ffmpegCmd.Stderr = &ffmpegErr
	if err := ffmpegCmd.Start(); err != nil {
		log.Fatalf("Failed to start ffmpeg: %v", err)
	}
	go func() {
		ffmpegCmd.Wait()
		stateMutex.Lock()
		extractionComplete = true
		frameReadyCond.Broadcast()
		stateMutex.Unlock()
	}()

	// --- Playback Loop ---
	playbackLoop(ctx)

	wgRender.Wait()

	stateMutex.Lock()
	finalAction := userAction
	stateMutex.Unlock()

	if finalAction != "" {
		return finalAction
	}
	return "finished"
}

func playbackLoop(ctx context.Context) {
	for {
		stateMutex.Lock()
		// Check for exit conditions first
		if ctx.Err() != nil {
			stateMutex.Unlock()
			return
		}
		if extractionComplete && totalFrames > 0 && currentFrameIndex >= totalFrames {
			stateMutex.Unlock()
			return // Video finished naturally
		}

		// Wait for the current frame to be rendered
		for lastRenderedFrame < currentFrameIndex && ctx.Err() == nil {
			printInfoUnlocked("BUFFERING", currentFrameIndex, height, fps, -1, totalFrames)
			frameReadyCond.Wait()
		}

		if ctx.Err() != nil {
			stateMutex.Unlock()
			return
		}

		speed := playbackSpeedMultipliers[currentSpeedMultiplierIndex]
		if isPaused {
			printInfo("PAUSED", currentFrameIndex, height, fps, speed)
			stateMutex.Unlock()
			time.Sleep(100 * time.Millisecond)
			continue
		}

		frameStartTime := time.Now()
		var content []byte
		frameIdx := currentFrameIndex
		if frameIdx < len(renderedFrames) {
			content = renderedFrames[frameIdx]
		}
		currentFrameIndex++
		stateMutex.Unlock()

		if content == nil {
			continue
		}

		fmt.Print("\x1b[H")
		fmt.Print(string(content))
		printInfo("PLAYING", frameIdx, height, fps, speed)

		frameDelay := time.Duration(float64(time.Second) / (float64(fps) * speed))
		elapsed := time.Since(frameStartTime)
		sleepDuration := frameDelay - elapsed
		if sleepDuration > 0 {
			time.Sleep(sleepDuration)
		}
	}
}

func printHelp() {
	fmt.Println(`
        hitvid v1.1.3 - High-performance terminal video player

        Description:
            hitvid is a tool that uses ffmpeg and chafa to render and play videos in your terminal.
        It supports playlists, rich playback controls, and highly customizable rendering options.

        Dependencies:
            ffmpeg: Must be installed and in your system's PATH.
            - chafa: Must be installed and in your system's PATH.

        Usage:
            go run hitvid.go [options] <video file path>

        Example:
            go run hitvid.go -fps 24 -colors full ./my_video.mp4

        Command-line options:
            -video <path>
               Path to the video file. Can also be given as the last positional argument.
            -fps <integer>
               Frame rate (FPS) for video extraction and playback. (Default: 15)
            -symbols <string>
               Symbol set to use for chafa (e.g., block, ascii, legacy). (Default: "block")
            -colors <string>
               Color mode used by chafa (e.g., 16, 256, full). (Default: "256")
            -dither <string>
               Dithering algorithm used by chafa (e.g., ordered, diffusion, none). (Default: "ordered")
            -w <integer>
               Render width. (Default: terminal width)
            -h <integer>
               Render height. (Default: terminal height - 1)
            -threads <integer>
               Number of parallel threads to use for rendering. (Default: 4)
            -help, -help
               Display this help message and exit.

        Playback Controls (Keyboard Shortcuts):
            Q / Ctrl+C : Exit the program.
        Spacebar : Pause or resume playback.
            + : Increase playback speed.
            - : Decrease playback speed.
            → (right arrow) : Jump forward 5 seconds.
            ← (left arrow) : Jump back 5 seconds.
            ↑ (up arrow) : Previous video in the playlist.
            ↓ (Down arrow): Next video in the playlist.
        `)
}

func main() {
	flag.StringVar(&videoPath, "video", "", "Path to the video file. Can also be provided as a positional argument.")
	flag.IntVar(&fps, "fps", 15, "Frames per second for extraction")
	flag.StringVar(&symbols, "symbols", "block", "Symbols to use for rendering")
	flag.StringVar(&colors, "colors", "256", "Color mode")
	flag.StringVar(&dither, "dither", "ordered", "Dithering mode")
	flag.IntVar(&width, "w", 0, "Display width (default: terminal width)")
	flag.IntVar(&height, "h", 0, "Display height (default: terminal height - 1)")
	flag.IntVar(&numThreads, "threads", 4, "Number of parallel threads for Chafa rendering")
	flag.BoolVar(&showHelp, "help", false, "Show detailed program description")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] /path/to/video\n", os.Args[0])
		fmt.Fprintln(os.Stderr, "A high-performance terminal video player.")
		fmt.Fprintln(os.Stderr, "\nOptions:")
		flag.PrintDefaults()
	}

	flag.Parse()

	if showHelp {
		printHelp()
		os.Exit(0)
	}

	if videoPath == "" {
		if flag.NArg() > 0 {
			videoPath = flag.Arg(0)
		} else {
			fmt.Print("Error: Video file path is required.\r\n")
			flag.Usage()
			os.Exit(1)
		}
	}

	seekAmountInFrames = seekSeconds * fps
	frameReadyCond = sync.NewCond(&stateMutex)

	playlist, err := getPlaylist(filepath.Dir(videoPath))
	if err != nil || len(playlist) == 0 {
		log.Fatalf("Failed to find any videos in the directory: %v", err)
	}

	currentVideoIndex := -1
	for i, path := range playlist {
		if path == videoPath {
			currentVideoIndex = i
			break
		}
	}
	if currentVideoIndex == -1 {
		log.Fatalf("Could not find the specified video in the playlist.")
	}

	// --- Setup Terminal ---
	var termErr error
	termWidth, termHeight, termErr := term.GetSize(int(os.Stdout.Fd()))
	if termErr != nil {
		termWidth, termHeight = 80, 24
	}
	if width == 0 {
		width = termWidth
	}
	if height == 0 {
		height = termHeight - 1
	}

	oldState, termErr := term.MakeRaw(int(os.Stdin.Fd()))
	if termErr != nil {
		log.Fatalf("Failed to set terminal to raw mode: %v", err)
	}
	defer term.Restore(int(os.Stdin.Fd()), oldState)

	fmt.Print("\x1b[?25l\x1b[?1049h")
	defer fmt.Print("\x1b[?1049l\x1b[?25h")
	defer fmt.Print("\r\nPlayback finished. Thank you for using hitvid!\r\n")

	// --- Main Control Loop ---
	for {
		ctx, cancel := context.WithCancel(context.Background())

		// Start the single input handler for the entire application lifecycle
		inputDone := make(chan struct{})
		go func() {
			handleInput(cancel)
			close(inputDone)
		}()

		action := playVideo(ctx, playlist[currentVideoIndex])
		cancel() // Ensure everything from the previous video is stopped

		switch action {
		case "next":
			currentVideoIndex = (currentVideoIndex + 1) % len(playlist)
		case "prev":
			currentVideoIndex = (currentVideoIndex - 1 + len(playlist)) % len(playlist)
		case "quit":
			stateMutex.Lock()
			userAction = "quit" // Signal input handler to exit
			stateMutex.Unlock()
			<-inputDone // Wait for input handler to finish
			return
		case "finished":
			printInfoUnlocked("FINISHED", 0, height, fps, 0, 0)
			// Post-playback input loop
		postLoop:
			for {
				buf := make([]byte, 3)
				os.Stdin.Read(buf)
				switch {
				case buf[0] == 'q' || buf[0] == 3:
					stateMutex.Lock()
					userAction = "quit"
					stateMutex.Unlock()
					<-inputDone
					return
				case buf[0] == '\x1b' && buf[1] == '[' && buf[2] == 'A': // Up
					currentVideoIndex = (currentVideoIndex - 1 + len(playlist)) % len(playlist)
					break postLoop
				case buf[0] == '\x1b' && buf[1] == '[' && buf[2] == 'B': // Down
					currentVideoIndex = (currentVideoIndex + 1) % len(playlist)
					break postLoop
				}
			}
		}
	}
}

// printInfo displays the playback status. It locks the mutex to safely get state.
func printInfo(status string, current, termH, frameRate int, speed float64) {
	stateMutex.Lock()
	total := totalFrames
	stateMutex.Unlock()
	printInfoUnlocked(status, current, termH, frameRate, speed, total)
}

// printInfoUnlocked is the core display logic without mutex locking.
func printInfoUnlocked(status string, currentFrame, termH, frameRate int, speed float64, totalFrames int) {
	currentTimeStr := formatTime(currentFrame, frameRate)
	var totalTimeStr string
	if totalFrames > 0 {
		totalTimeStr = formatTime(totalFrames, frameRate)
	} else {
		totalTimeStr = "??:??"
	}
	infoLine := termH + 1
	controls := "Spc:Pause, +/-:Speed, L/R:Seek, U/D:Track, Q:Quit"
	var info string
	switch status {
	case "PLAYING", "PAUSED":
		info = fmt.Sprintf("[%s] %s / %s | Speed: %.2fx | %s", status, currentTimeStr, totalTimeStr, speed, controls)
	case "BUFFERING":
		info = fmt.Sprintf("[%s] %s / %s...", status, currentTimeStr, totalTimeStr)
	case "FINISHED":
		info = "Playback finished. Press UP/DOWN for next/prev, or Q to quit."
	}
	fmt.Printf("\x1b[%d;1H\x1b[K%s", infoLine, info)
}
