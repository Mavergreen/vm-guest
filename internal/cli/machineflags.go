package cli

import (
	"flag"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
)

// registerMachine adds the machine flags every machine-using subcommand
// shares, bound to m. It lives here, not in config, because flags are the
// command line's business: config owns the defaults, cli owns argv.
func registerMachine(fs *flag.FlagSet, m *config.Machine) {
	fs.StringVar(&m.Accel, "accel", m.Accel, "accelerator: kvm, hvf, nvmm or tcg")
	fs.StringVar(&m.CPU, "cpu", m.CPU, "QEMU -cpu line (docs/decisions/0009)")
	fs.IntVar(&m.MemoryMB, "memory", m.MemoryMB, "guest memory in MiB")
	fs.IntVar(&m.SMP, "smp", m.SMP, "guest CPUs")
	fs.StringVar(&m.NIC, "nic", m.NIC, "network device: "+strings.Join(config.NICChoices, ", "))
	fs.IntVar(&m.SSHPort, "ssh-port", m.SSHPort, "host port forwarded to the guest's port 22")
	fs.StringVar(&m.Display, "display", m.Display, "QEMU -display: none, gtk, sdl or cocoa")
}
