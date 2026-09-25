package cli

import (
	"flag"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
)

func TestMachineFlagsOverrideOnlyWhatWasSet(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	flagged := config.DefaultMachine()
	registerMachine(fs, &flagged)
	if err := fs.Parse([]string{"--memory", "8192"}); err != nil {
		t.Fatal(err)
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	fromImage := config.DefaultMachine()
	fromImage.NIC = "usb-net"
	fromImage.Override(flagged, func(n string) bool { return set[n] })
	if fromImage.MemoryMB != 8192 || fromImage.NIC != "usb-net" {
		t.Fatalf("got %+v", fromImage)
	}
}

func TestEveryMachineFlagIsRegistered(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	m := config.DefaultMachine()
	registerMachine(fs, &m)
	for _, name := range []string{"accel", "cpu", "memory", "smp", "nic", "ssh-port", "display"} {
		if fs.Lookup(name) == nil {
			t.Errorf("no --%s", name)
		}
	}
}
