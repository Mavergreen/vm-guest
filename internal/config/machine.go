package config

import (
	"flag"
	"fmt"
	"slices"
	"strings"
)

// Machine is the guest hardware, and the forwarded SSH port. The same
// values drive install, verify, run and emit.
type Machine struct {
	Accel    string
	Type     string // QEMU machine type; ",vmport=off" is added by machine.Spec
	CPU      string
	MemoryMB int
	SMP      int
	NIC      string
	SSHPort  int
	Display  string
}

func DefaultMachine() Machine {
	return Machine{
		Accel: DefaultAccel, Type: DefaultType, CPU: DefaultCPU,
		MemoryMB: DefaultMemoryMB, SMP: DefaultSMP, NIC: DefaultNIC,
		SSHPort: DefaultSSHPort, Display: DefaultDisplay,
	}
}

// Register adds the machine flags every machine-using subcommand shares.
func (m *Machine) Register(fs *flag.FlagSet) {
	fs.StringVar(&m.Accel, "accel", m.Accel, "accelerator: kvm, hvf, nvmm or tcg")
	fs.StringVar(&m.CPU, "cpu", m.CPU, "QEMU -cpu line (docs/decisions/0009)")
	fs.IntVar(&m.MemoryMB, "memory", m.MemoryMB, "guest memory in MiB")
	fs.IntVar(&m.SMP, "smp", m.SMP, "guest CPUs")
	fs.StringVar(&m.NIC, "nic", m.NIC, "network device: "+strings.Join(NICChoices, ", "))
	fs.IntVar(&m.SSHPort, "ssh-port", m.SSHPort, "host port forwarded to the guest's port 22")
	fs.StringVar(&m.Display, "display", m.Display, "QEMU -display: none, gtk, sdl or cocoa")
}

// Override copies the fields whose flags were set on the command line.
// An image's manifest says what it was installed with; a flag given
// explicitly still wins.
func (m *Machine) Override(from Machine, set func(name string) bool) {
	if set("accel") {
		m.Accel = from.Accel
	}
	if set("cpu") {
		m.CPU = from.CPU
	}
	if set("memory") {
		m.MemoryMB = from.MemoryMB
	}
	if set("smp") {
		m.SMP = from.SMP
	}
	if set("nic") {
		m.NIC = from.NIC
	}
	if set("ssh-port") {
		m.SSHPort = from.SSHPort
	}
	if set("display") {
		m.Display = from.Display
	}
}

func (m Machine) Validate() error {
	if !slices.Contains(NICChoices, m.NIC) {
		return fmt.Errorf("no such NIC %q (choices: %s)", m.NIC, strings.Join(NICChoices, ", "))
	}
	if m.MemoryMB <= 0 || m.SMP <= 0 {
		return fmt.Errorf("memory and smp must be positive (got %d MiB, %d)", m.MemoryMB, m.SMP)
	}
	if m.SSHPort <= 0 || m.SSHPort > 65535 {
		return fmt.Errorf("no such port %d", m.SSHPort)
	}
	return nil
}
