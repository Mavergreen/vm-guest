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
// SIGTERM and SIGHUP, on the other hand, stay caught after the first
// signal: a second hangup must not kill a `run` before it has removed its
// run directory.
//
// The child is `vmavs fetch esd` with VMAVS_HOME's media/InstallESD.dmg a
// FIFO: adoption opens it and blocks reading it, before any handshake,
// so nothing touches the network (and HTTP(S)_PROXY point at a closed
// port in case something did).
//
// The scenario needs the child blocked in read(2) when the first SIGINT
// arrives, and only the child knows when it is: if the signal lands
// before its first read, it notices the cancellation (ctxReader looks at
// ctx before its first read) and exits 1, cleanly -- correct behaviour,
// but not what this test is about. Such a run is inconclusive, and the
// scenario is tried again, up to five times.
func TestASecondInterruptKillsAStuckVmavs(t *testing.T) {
	const attempts = 5
	for i := 1; i <= attempts; i++ {
		if secondInterruptScenario(t) {
			return
		}
		t.Logf("attempt %d of %d inconclusive: vmavs saw the first interrupt before it blocked", i, attempts)
	}
	t.Fatalf("all %d attempts inconclusive: vmavs never blocked in its read before the first interrupt", attempts)
}

// secondInterruptScenario runs the scenario once. It reports false when
// the run was inconclusive (the child exited 1 on its own, having noticed
// the first interrupt), and fails the test on anything else that is not
// the child dying of the second SIGINT.
func secondInterruptScenario(t *testing.T) (conclusive bool) {
	t.Helper()
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
	defer func() {
		cmd.Process.Kill()
		<-exited
	}()

	// Opening the FIFO for writing blocks until the child has opened it
	// for reading, long after its signal handling was installed.
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
		// One byte, and a moment to read it: the child's next look at
		// its context is 4 MiB away, so from here it sits in read(2).
		if _, err := w.Write([]byte{0}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(250 * time.Millisecond)
	case err := <-exited:
		t.Fatalf("vmavs exited before reaching the FIFO: %v", err)
	case <-time.After(30 * time.Second):
		t.Fatal("vmavs never opened the FIFO")
	}

	// verdict classifies an exit: a clean exit 1 is the child having
	// noticed the cancellation (inconclusive); death by want passes;
	// anything else fails.
	verdict := func(err error, want syscall.Signal, when string) bool {
		var xe *exec.ExitError
		if !errors.As(err, &xe) {
			t.Fatalf("%s: vmavs exited with %v", when, err)
		}
		ws, ok := xe.Sys().(syscall.WaitStatus)
		switch {
		case ok && ws.Exited() && ws.ExitStatus() == 1:
			return false
		case ok && want != 0 && ws.Signaled() && ws.Signal() == want:
			return true
		}
		t.Fatalf("%s: vmavs exited with %v", when, err)
		return false
	}

	signal := func(s os.Signal) {
		if err := cmd.Process.Signal(s); err != nil {
			t.Fatal(err)
		}
	}

	signal(os.Interrupt)
	select {
	case err := <-exited:
		exited <- err // for the deferred cleanup
		return verdict(err, 0, "after the first interrupt")
	case <-time.After(200 * time.Millisecond):
	}

	signal(syscall.SIGTERM)
	signal(syscall.SIGHUP)
	signal(syscall.SIGHUP)
	select {
	case err := <-exited:
		exited <- err
		return verdict(err, 0, "after a SIGTERM and two SIGHUPs following the first interrupt (they must stay caught)")
	case <-time.After(300 * time.Millisecond):
	}

	signal(os.Interrupt)
	select {
	case err := <-exited:
		exited <- err
		return verdict(err, syscall.SIGINT, "after the second interrupt")
	case <-time.After(10 * time.Second):
		t.Fatal("a second interrupt did not kill vmavs")
	}
	return false
}
