package emit

import (
	"flag"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/machine"
)

var update = flag.Bool("update", false, "rewrite testdata/packer.pkr.hcl")

func template(t *testing.T) string {
	t.Helper()
	b, err := Packer(config.DefaultMachine(), config.DefaultDiskGB)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTheTemplateIsValidHCL(t *testing.T) {
	src := template(t)
	f, diags := hclsyntax.ParseConfig([]byte(src), "packer.pkr.hcl", hcl.InitialPos)
	if diags.HasErrors() {
		t.Fatalf("%v\n%s", diags, src)
	}
	body := f.Body.(*hclsyntax.Body)
	kinds := map[string]int{}
	for _, b := range body.Blocks {
		kinds[b.Type]++
	}
	if kinds["packer"] != 1 || kinds["variable"] != len(Variables) || kinds["source"] != 1 || kinds["build"] != 1 {
		t.Fatalf("blocks %v", kinds)
	}
}

func TestTheTemplateMatchesTheGoldenFile(t *testing.T) {
	src := template(t)
	if *update {
		os.WriteFile("testdata/packer.pkr.hcl", []byte(src), 0o644)
	}
	want, _ := os.ReadFile("testdata/packer.pkr.hcl")
	if src != string(want) {
		t.Fatalf("differs from testdata/packer.pkr.hcl; run go test ./internal/emit -update and review the diff")
	}
}

func TestWhatPackerValidateTaughtUs(t *testing.T) {
	src := template(t)
	for _, want := range []string{
		`"github.com/hashicorp/vagrant"`, `"github.com/hashicorp/qemu"`,
		`host_port_min`, `machine_type`, `"q35,vmport=off"`,
		`${var.ovmf_code}`, `${var.opencore_media}`, `${var.media}`, `output-mavericks/mavericks.qcow2`,
		`post-processor "vagrant"`, `mavericks-{{.Provider}}.box`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("template lacks %s", want)
		}
	}
	for _, bad := range []string{"ssh_host_port_min", "boot_command =", "vagrantcloud"} {
		if strings.Contains(src, bad) {
			t.Errorf("template contains %s", bad)
		}
	}
}

func TestTheTemplateCarriesNoAppleBytes(t *testing.T) {
	src := template(t)
	for _, bad := range []string{"osk=", "isa-applesmc", "InstallESD", "BaseSystem"} {
		if strings.Contains(src, bad) {
			t.Errorf("template contains %s", bad)
		}
	}
}

func TestTheHeaderSaysWhatValidationProves(t *testing.T) {
	src := template(t)
	if !strings.Contains(src, "packer validate") || !strings.Contains(strings.ToLower(src), "no packer build has ever run") {
		t.Fatal("header must say it validates and has never been built")
	}
}

func TestQuotedTemplateEscapesLiteralText(t *testing.T) {
	got := string(templateTokens(`a "b" ${var.x} $${lit}`).Bytes())
	if got != `"a \"b\" ${var.x} $$${lit}"` {
		t.Fatalf("got %s", got)
	}
}

// TestNetDeviceMatchesTheNICInQemuargs guards packer-plugin-qemu issue
// #6804 (step_run.go, applyUserOverrides): the plugin only skips its own
// automatic netdev=user.0 -device append when net_device is a substring of
// some -device argument already in qemuargs. net_device must therefore
// name exactly the NIC machine.NICDevice already put there, for every NIC
// vmavs supports -- not just the default.
func TestNetDeviceMatchesTheNICInQemuargs(t *testing.T) {
	for _, nic := range config.NICChoices {
		hw := config.DefaultMachine()
		hw.NIC = nic
		b, err := Packer(hw, config.DefaultDiskGB)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		netDevice := regexp.MustCompile(`net_device\s*=\s*"([^"]*)"`).FindStringSubmatch(src)
		if netDevice == nil || netDevice[1] != nic {
			t.Errorf("%s: net_device = %v, want %q", nic, netDevice, nic)
		}
		if !strings.Contains(src, machine.NICDevice(nic)) {
			t.Errorf("%s: qemuargs lacks the -device line %q that net_device must be a substring of", nic, machine.NICDevice(nic))
		}
		if !strings.Contains(machine.NICDevice(nic), nic) {
			t.Errorf("%s: machine.NICDevice's own -device line %q does not contain the NIC name", nic, machine.NICDevice(nic))
		}
	}
}
