package emit

import (
	"flag"
	"os"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"

	"github.com/Mavergreen/vm-guest/internal/config"
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
