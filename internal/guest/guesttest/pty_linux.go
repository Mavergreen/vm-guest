package guesttest

import (
	"fmt"
	"os"
	"syscall"
	"testing"
	"unsafe"
)

// Pty is the terminal end of a fresh pseudo-terminal, for a test that
// needs guest.Shell to see a real terminal (and so request a pty). Linux
// only: it uses /dev/ptmx's own ioctls, from the standard library.
func Pty(t testing.TB) *os.File {
	t.Helper()
	ptmx, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Skipf("no /dev/ptmx here: %v", err)
	}
	t.Cleanup(func() { ptmx.Close() })
	var unlock int32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); e != 0 {
		t.Fatalf("unlocking the pty: %v", e)
	}
	var n uint32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); e != 0 {
		t.Fatalf("naming the pty: %v", e)
	}
	pts, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pts.Close() })
	return pts
}
