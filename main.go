package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/schollz/progressbar/v3"
	"golang.org/x/sync/errgroup"
	"golang.org/x/term"
)

var version = "1.1.0 (Go port)"

type config struct {
	VideoPath   string
	FPS         float64
	ScaleMode   string
	Colors      string
	Dither      string
	Symbols     string
	Width       int
	Height      int
	PlayMode    string
	NumThreads  int
	Quiet       bool
	Loop        bool
	SeekSeconds int
}

type videoInfo struct {
	Width          int
	Height         int
	Duration       float64
	AvgFrameRate   float64
	TotalFrames    int
	NbFramesStream int
}

type playerState struct {
	sync.Mutex
	paused         bool
	speedIndex     int
	currentFrame   int
	quit           bool
	playbackSpeeds []float64
}

var (
	tempDir        string
	jpgFramesDir   string
	chafaFramesDir string
)

const (
	charPixelWidthApprox  = 8
	charPixelHeightApprox = 16
	maxFpsCap             = 60
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg := parseAndValidateFlags()

	if err := checkDependencies("ffmpeg", "ffprobe", "chafa", "stty"); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}

	var err error
	tempDir, err = setupTempDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	defer cleanup()

	vInfo, err := getVideoInfo(ctx, cfg.VideoPath, cfg.FPS)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error getting video info:", err)
		os.Exit(1)
	}

	if !cfg.Quiet {
		fmt.Printf("Mode: %s, FPS: %.2f, Size: %dx%d, Threads: %d, File: %s\n",
			cfg.PlayMode, cfg.FPS, cfg.Width, cfg.Height, cfg.NumThreads, cfg.VideoPath)
		fmt.Printf("Video Info: %.2fs duration, expecting %d frames.\n", vInfo.Duration, vInfo.TotalFrames)
	}

	eg, gCtx := errgroup.WithContext(ctx)

	switch cfg.PlayMode {
	case "preload":
		runPreload(gCtx, eg, cfg, vInfo)
	case "stream":
		runStream(gCtx, eg, cfg, vInfo)
	default:
		fmt.Fprintf(os.Stderr, "Invalid play mode: %s\n", cfg.PlayMode)
		os.Exit(1)
	}

	if err := eg.Wait(); err != nil {
		if !errors.Is(err, context.Canceled) {
			fmt.Fprintf(os.Stderr, "\nAn error occurred during processing: %v\n", err)
		}
	}

	fmt.Println("\nPlayback finished.")
}

func parseAndValidateFlags() config {
	var cfg config
	var showHelp bool

	termWidth, termHeight, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil {
		termWidth = 80
		termHeight = 24
	}

	flag.StringVar(&cfg.VideoPath, "videopath", "", "Path to the video file (required)")
	flag.Float64Var(&cfg.FPS, "fps", 15, "Set extraction frames per second")
	flag.StringVar(&cfg.ScaleMode, "scale", "fit", "Set scaling mode: fit, fill, stretch")
	flag.StringVar(&cfg.Colors, "colors", "256", "Set color mode: 2, 16, 256, full")
	flag.StringVar(&cfg.Dither, "dither", "ordered", "Set dither mode: none, ordered, diffusion")
	flag.StringVar(&cfg.Symbols, "symbols", "block", "Set symbol set: block, ascii, space")
	flag.IntVar(&cfg.Width, "width", termWidth, "Set display width (default: terminal width)")
	flag.IntVar(&cfg.Height, "height", termHeight-2, "Set display height (default: terminal height - 2)")
	flag.StringVar(&cfg.PlayMode, "mode", "stream", "Playback mode: preload, stream")
	flag.IntVar(&cfg.NumThreads, "threads", runtime.NumCPU(), "Number of parallel threads for Chafa rendering")
	flag.BoolVar(&cfg.Quiet, "quiet", false, "Suppress loading progress bars")
	flag.BoolVar(&cfg.Loop, "loop", false, "Loop playback")
	flag.IntVar(&cfg.SeekSeconds, "seek", 5, "Seconds to seek forward/backward")
	flag.BoolVar(&showHelp, "help", false, "Show this help message")
	flag.BoolVar(&showHelp, "h", false, "Show this help message (shorthand)")

	flag.Usage = func() {
		fmt.Println("hitvid - Terminal-based video player using chafa (Go Version)")
		fmt.Printf("\nUsage: go run main.go [VIDEO_PATH] [OPTIONS]\n")
		fmt.Println("\nOptions:")
		flag.PrintDefaults()
		fmt.Println("\nInteractive Controls (during playback):")
		fmt.Println("  Spacebar      Pause/Resume")
		fmt.Println("  Right Arrow   Seek forward")
		fmt.Println("  Left Arrow    Seek backward")
		fmt.Println("  Up Arrow      Increase playback speed")
		fmt.Println("  Down Arrow    Decrease playback speed")
		fmt.Println("  q / Ctrl+C    Quit")
	}

	flag.Parse()

	if len(flag.Args()) > 0 {
		cfg.VideoPath = flag.Args()[0]
	}

	if showHelp || cfg.VideoPath == "" {
		flag.Usage()
		os.Exit(0)
	}

	if _, err := os.Stat(cfg.VideoPath); os.IsNotExist(err) && !strings.HasPrefix(cfg.VideoPath, "http") {
		fmt.Fprintf(os.Stderr, "Error: Video file '%s' not found.\n", cfg.VideoPath)
		os.Exit(1)
	}
	if cfg.FPS <= 0 {
		fmt.Fprintln(os.Stderr, "Error: FPS must be a positive number.")
		os.Exit(1)
	}
	if cfg.FPS > maxFpsCap {
		fmt.Fprintf(os.Stderr, "Warning: Requested FPS %.2f is high, capping at %d for extraction.\n", cfg.FPS, maxFpsCap)
		cfg.FPS = maxFpsCap
	}

	return cfg
}

func checkDependencies(cmds ...string) error {
	for _, cmd := range cmds {
		if _, err := exec.LookPath(cmd); err != nil {
			return fmt.Errorf("dependency not found: '%s'. Please install it and ensure it's in your PATH", cmd)
		}
	}
	return nil
}

func setupTempDir() (string, error) {
	shmDir := "/dev/shm"
	baseDir := ""
	if info, err := os.Stat(shmDir); err == nil && info.IsDir() {
		testFile := filepath.Join(shmDir, ".hitvid_test")
		if f, err := os.Create(testFile); err == nil {
			f.Close()
			os.Remove(testFile)
			baseDir = shmDir
		}
	}

	dir, err := os.MkdirTemp(baseDir, "hitvid.*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp directory: %w", err)
	}

	jpgFramesDir = filepath.Join(dir, "jpg_frames")
	chafaFramesDir = filepath.Join(dir, "chafa_frames")

	if err := os.Mkdir(jpgFramesDir, 0755); err != nil {
		return "", err
	}
	if err := os.Mkdir(chafaFramesDir, 0755); err != nil {
		return "", err
	}
	return dir, nil
}

func cleanup() {
	if tempDir != "" {
		fmt.Print("\033[?1049l\033[?25h")
		stty("sane")
		if err := os.RemoveAll(tempDir); err != nil {
			fmt.Fprintln(os.Stderr, "Warning: failed to remove temp directory:", err)
		}
	}
}

func stty(args ...string) {
	cmd := exec.Command("stty", args...)
	cmd.Stdin = os.Stdin
	_ = cmd.Run()
}

func runPreload(ctx context.Context, eg *errgroup.Group, cfg config, vInfo videoInfo) {
	var bar *progressbar.ProgressBar
	if !cfg.Quiet {
		bar = progressbar.NewOptions(
			vInfo.TotalFrames,
			progressbar.OptionSetDescription("Extracting frames (FFmpeg)"),
			progressbar.OptionSetWriter(os.Stderr),
			progressbar.OptionShowCount(),
			progressbar.OptionSetWidth(40),
			progressbar.OptionClearOnFinish(),
		)
	}

	err := extractFrames(ctx, cfg, vInfo, bar)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Frame extraction failed:", err)
		return
	}

	if !cfg.Quiet {
		bar = progressbar.NewOptions(
			vInfo.TotalFrames,
			progressbar.OptionSetDescription("Rendering frames (Chafa) "),
			progressbar.OptionSetWriter(os.Stderr),
			progressbar.OptionShowCount(),
			progressbar.OptionSetWidth(40),
			progressbar.OptionClearOnFinish(),
		)
	}
	renderFrames(ctx, eg, cfg.NumThreads, vInfo.TotalFrames, bar)

	if err := eg.Wait(); err != nil {
		if !errors.Is(err, context.Canceled) {
			fmt.Fprintf(os.Stderr, "\nAn error occurred during rendering: %v\n", err)
		}
		return
	}

	playerEg, playerCtx := errgroup.WithContext(ctx)
	playerEg.Go(func() error {
		return playFrames(playerCtx, cfg, vInfo)
	})
	_ = playerEg.Wait()
}

func runStream(ctx context.Context, eg *errgroup.Group, cfg config, vInfo videoInfo) {
	eg.Go(func() error {
		return extractFrames(ctx, cfg, vInfo, nil)
	})

	eg.Go(func() error {
		renderFrames(ctx, nil, cfg.NumThreads, vInfo.TotalFrames, nil)
		return nil
	})

	eg.Go(func() error {
		select {
		case <-time.After(500 * time.Millisecond):
		case <-ctx.Done():
			return ctx.Err()
		}
		return playFrames(ctx, cfg, vInfo)
	})
}

func getVideoInfo(ctx context.Context, videoPath string, targetFPS float64) (videoInfo, error) {
	var info videoInfo

	cmd := exec.CommandContext(ctx, "ffprobe",
		"-v", "error",
		"-select_streams", "v:0",
		"-show_entries", "stream=width,height,duration,avg_frame_rate,nb_frames",
		"-of", "csv=p=0",
		videoPath,
	)

	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return info, fmt.Errorf("ffprobe failed: %s\n%s", err, stderr.String())
	}

	parts := strings.Split(strings.TrimSpace(out.String()), ",")
	if len(parts) < 5 {
		return info, fmt.Errorf("unexpected ffprobe output: %s", out.String())
	}

	info.Width, _ = strconv.Atoi(parts[0])
	info.Height, _ = strconv.Atoi(parts[1])

	if parts[2] != "N/A" {
		info.Duration, _ = strconv.ParseFloat(parts[2], 64)
	}

	info.NbFramesStream, _ = strconv.Atoi(parts[4])

	if parts[3] != "N/A" {
		rateParts := strings.Split(parts[3], "/")
		if len(rateParts) == 2 {
			num, _ := strconv.ParseFloat(rateParts[0], 64)
			den, _ := strconv.ParseFloat(rateParts[1], 64)
			if den > 0 {
				info.AvgFrameRate = num / den
			}
		}
	}

	if info.Duration > 0 {
		info.TotalFrames = int(math.Ceil(info.Duration * targetFPS))
	} else if info.NbFramesStream > 0 && info.AvgFrameRate > 0 {
		estimatedDuration := float64(info.NbFramesStream) / info.AvgFrameRate
		info.TotalFrames = int(math.Ceil(estimatedDuration * targetFPS))
	} else {
		return info, errors.New("could not determine video duration or frame count")
	}

	if info.TotalFrames <= 0 {
		return info, errors.New("calculated total frames is zero or less")
	}

	return info, nil
}

func extractFrames(ctx context.Context, cfg config, vInfo videoInfo, bar *progressbar.ProgressBar) error {
	pixelWidth := cfg.Width * charPixelWidthApprox
	pixelHeight := cfg.Height * charPixelHeightApprox

	var scaleVf string
	switch cfg.ScaleMode {
	case "fit":
		scaleVf = fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=decrease", pixelWidth, pixelHeight)
	case "fill":
		scaleVf = fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d", pixelWidth, pixelHeight, pixelWidth, pixelHeight)
	case "stretch":
		scaleVf = fmt.Sprintf("scale=%d:%d", pixelWidth, pixelHeight)
	}

	vfArg := fmt.Sprintf("fps=%.2f,%s", cfg.FPS, scaleVf)
	outputPath := filepath.Join(jpgFramesDir, "frame-%05d.jpg")

	args := []string{
		"-nostdin",
		"-loglevel", "error",
		"-i", cfg.VideoPath,
		"-vf", vfArg,
		"-q:v", "2",
		outputPath,
	}

	if bar != nil {
		args = append(args, "-progress", "pipe:1")
	}

	cmd := exec.CommandContext(ctx, "ffmpeg", args...)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if bar != nil {
		progressPipe, err := cmd.StdoutPipe()
		if err != nil {
			return fmt.Errorf("failed to create progress pipe: %w", err)
		}

		if err := cmd.Start(); err != nil {
			return fmt.Errorf("ffmpeg failed to start: %w\n%s", err, stderr.String())
		}

		go func() {
			scanner := bufio.NewScanner(progressPipe)
			for scanner.Scan() {
				line := scanner.Text()
				if strings.HasPrefix(line, "frame=") {
					parts := strings.Split(strings.TrimSpace(line), "=")
					if len(parts) == 2 {
						frameNum, _ := strconv.Atoi(strings.TrimSpace(parts[1]))
						bar.Set(frameNum)
					}
				}
				if strings.Contains(line, "progress=end") {
					return
				}
			}
		}()

	} else {
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("ffmpeg failed to start: %w\n%s", err, stderr.String())
		}
	}

	if err := cmd.Wait(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("ffmpeg execution failed: %w\n%s", err, stderr.String())
	}

	if bar != nil {
		bar.Finish()
	}
	return nil
}

func renderFrames(ctx context.Context, eg *errgroup.Group, numWorkers, totalFrames int, bar *progressbar.ProgressBar) {
	if eg != nil {
		for i := 1; i <= totalFrames; i++ {
			frameNum := i
			eg.Go(func() error {
				return renderSingleFrame(ctx, frameNum, true, bar)
			})
		}
	} else {
		var wg sync.WaitGroup
		sem := make(chan struct{}, numWorkers)

		for i := 1; i <= totalFrames; i++ {
			if ctx.Err() != nil {
				break
			}
			wg.Add(1)
			go func(frameNum int) {
				defer wg.Done()
				select {
				case sem <- struct{}{}:
					defer func() { <-sem }()
				case <-ctx.Done():
					return
				}
				_ = renderSingleFrame(ctx, frameNum, false, nil)
			}(i)
		}
		wg.Wait()
	}
}

func renderSingleFrame(ctx context.Context, frameNum int, isPreload bool, bar *progressbar.ProgressBar) error {
	jpgPath := filepath.Join(jpgFramesDir, fmt.Sprintf("frame-%05d.jpg", frameNum))
	txtPath := filepath.Join(chafaFramesDir, fmt.Sprintf("frame-%05d.txt", frameNum))

	if !isPreload {
		for {
			if _, err := os.Stat(jpgPath); err == nil {
				break
			}
			select {
			case <-time.After(10 * time.Millisecond):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}

	if _, err := os.Stat(jpgPath); err == nil {
		w := flag.Lookup("width").Value.(flag.Getter).Get().(int)
		h := flag.Lookup("height").Value.(flag.Getter).Get().(int)
		err := runChafa(ctx, jpgPath, txtPath, w, h)
		if err != nil && ctx.Err() == nil {
			fmt.Fprintf(os.Stderr, "Chafa failed for frame %d: %v\n", frameNum, err)
			return err
		}
		if bar != nil {
			bar.Add(1)
		}
	}
	return nil
}

func runChafa(ctx context.Context, inputPath, outputPath string, width, height int) error {
	colors := flag.Lookup("colors").Value.String()
	dither := flag.Lookup("dither").Value.String()
	symbols := flag.Lookup("symbols").Value.String()

	sizeArg := fmt.Sprintf("%dx%d", width, height)

	args := []string{
		"--size", sizeArg,
		"--colors", colors,
		"--dither", dither,
		"--symbols", symbols,
		inputPath,
	}

	cmd := exec.CommandContext(ctx, "chafa", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	outfile, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("failed to create chafa output file: %w", err)
	}
	defer outfile.Close()
	cmd.Stdout = outfile

	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %s", err, stderr.String())
	}
	return nil
}

func playFrames(ctx context.Context, cfg config, vInfo videoInfo) error {
	fmt.Print("\033[?1049h\033[H\033[2J")
	fmt.Print("\033[?25l")
	defer func() {
		fmt.Print("\033[?1049l\033[?25h")
		stty("sane")
	}()
	stty("-echo", "cbreak")

	state := &playerState{
		playbackSpeeds: []float64{0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 2.00},
		speedIndex:     3,
		currentFrame:   1,
	}

	kbdCtx, cancelKbd := context.WithCancel(ctx)
	defer cancelKbd()
	go func() {
		var buf [3]byte
		for {
			select {
			case <-kbdCtx.Done():
				return
			default:
				n, err := os.Stdin.Read(buf[:])
				if err != nil || n == 0 {
					continue
				}

				key := string(buf[:n])
				state.Lock()
				if key == " " {
					state.paused = !state.paused
				} else if key == "\x1b[A" {
					if state.speedIndex < len(state.playbackSpeeds)-1 {
						state.speedIndex++
					}
				} else if key == "\x1b[B" {
					if state.speedIndex > 0 {
						state.speedIndex--
					}
				} else if key == "\x1b[C" {
					framesToSeek := int(cfg.FPS * float64(cfg.SeekSeconds))
					state.currentFrame += framesToSeek
					if state.currentFrame > vInfo.TotalFrames {
						state.currentFrame = vInfo.TotalFrames
					}
				} else if key == "\x1b[D" {
					framesToSeek := int(cfg.FPS * float64(cfg.SeekSeconds))
					state.currentFrame -= framesToSeek
					if state.currentFrame < 1 {
						state.currentFrame = 1
					}
				} else if key == "q" || key == "\x03" {
					state.quit = true
				}
				state.Unlock()
			}
		}
	}()

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		state.Lock()
		if state.quit {
			state.Unlock()
			return context.Canceled
		}

		if state.paused {
			drawInfoLine(cfg.Width, cfg.Height+1, "PAUSED", state, vInfo)
			state.Unlock()
			time.Sleep(100 * time.Millisecond)
			continue
		}

		speed := state.playbackSpeeds[state.speedIndex]
		frameDelay := time.Duration(1_000_000_000 / (cfg.FPS * speed))
		ticker.Reset(frameDelay)

		frameToPlay := state.currentFrame
		state.Unlock()

		if frameToPlay > vInfo.TotalFrames {
			if cfg.Loop {
				state.Lock()
				state.currentFrame = 1
				state.Unlock()
				continue
			}
			break
		}

		txtPath := filepath.Join(chafaFramesDir, fmt.Sprintf("frame-%05d.txt", frameToPlay))

		for {
			if _, err := os.Stat(txtPath); err == nil {
				break
			}
			select {
			case <-time.After(10 * time.Millisecond):
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		content, err := os.ReadFile(txtPath)
		if err == nil {
			fmt.Print("\033[H", string(content))
		}

		drawInfoLine(cfg.Width, cfg.Height+1, "Playing", state, vInfo)

		state.Lock()
		state.currentFrame++
		state.Unlock()

		select {
		case <-ticker.C:
		case <-ctx.Done():
			return ctx.Err()
		}
	}

	return nil
}

func drawInfoLine(width, row int, status string, state *playerState, vInfo videoInfo) {
	fmt.Printf("\033[s\033[%d;0H\033[K", row)

	percent := 0
	if vInfo.TotalFrames > 0 {
		percent = (state.currentFrame * 100) / vInfo.TotalFrames
	}
	info := fmt.Sprintf("[%s] %d/%d (%d%%) | Speed: %.2fx | q/Ctrl+C to quit",
		status, state.currentFrame, vInfo.TotalFrames, percent, state.playbackSpeeds[state.speedIndex])

	fmt.Print(info)

	fmt.Print("\033[u")
}
