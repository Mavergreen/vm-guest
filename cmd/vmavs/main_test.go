//go:build unix

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// TestMain lets a test run this binary's main in a child process: the
// signal handling under test is main's, and only a real process can be
// sent a real SIGINT.
func TestMain(m *testing.M) {
	if os.Getenv("VMAVS_TEST_RUN_MAIN") == "1" {
		os.Args = append([]string{"vmavs"}, os.Args[1:]...)
		main()
		return
	}
	os.Exit(m.Run())
}

// TestASecondInterruptKillsAStuckVmavs: the first Ctrl-C cancels the
// command in progress (spec §2), but something that cannot notice a
// cancelled context -- here, reading a FIFO that never delivers -- can
// keep vmavs alive after it. A second Ctrl-C must then still kill it,
// which it cannot while signal.NotifyContext is still catching SIGINT.
//
// The child is `vmavs fetch esd` with VMAVS_HOME's media/InstallESD.dmg a
// FIFO: adoption opens it and blocks reading it, before any handshake,
// so nothing touches the network (and HTTP(S)_PROXY point at a closed
// port in case something did).
func TestASecondInterruptKillsAStuckVmavs(t *testing.T) {
	home := t.TempDir()
	fifo := filepath.Join(home, "media", "InstallESD.dmg")
	if err := os.MkdirAll(filepath.Dir(fifo), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(os.Args[0], "fetch", "esd")
	cmd.Env = []string{
		"VMAVS_TEST_RUN_MAIN=1",
		"VMAVS_HOME=" + home,
		"HOME=" + t.TempDir(),
		"HTTP_PROXY=http://127.0.0.1:9",
		"HTTPS_PROXY=http://127.0.0.1:9",
		"PATH=" + os.Getenv("PATH"),
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	t.Cleanup(func() { cmd.Process.Kill() })

	// Opening the FIFO for writing blocks until the child has opened it
	// for reading: from then on, the child is stuck in adoption's hash,
	// with its signal handling installed long since.
	opened := make(chan *os.File, 1)
	go func() {
		w, err := os.OpenFile(fifo, os.O_WRONLY, 0)
		if err == nil {
			opened <- w
		}
	}()
	select {
	case w := <-opened:
		defer w.Close()
	case err := <-exited:
		t.Fatalf("vmavs exited before reaching the FIFO: %v", err)
	case <-time.After(30 * time.Second):
		t.Fatal("vmavs never opened the FIFO")
	}

	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-exited:
		t.Fatalf("vmavs exited on the first interrupt while blocked in a read (%v): this test proves nothing", err)
	case <-time.After(200 * time.Millisecond):
	}

	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-exited:
		var xe *exec.ExitError
		if !errors.As(err, &xe) {
			t.Fatalf("vmavs exited with %v, want killed by SIGINT", err)
		}
		if ws, ok := xe.Sys().(syscall.WaitStatus); !ok || !ws.Signaled() || ws.Signal() != syscall.SIGINT {
			t.Fatalf("vmavs exited with %v, want killed by SIGINT", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("a second interrupt did not kill vmavs")
	}
}
