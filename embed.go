// Package vmguest is the repository root. It exists to carry files into
// the vmavs binary with go:embed, which cannot reach outside the directory
// of the package that uses it.
package vmguest

import "embed"

// UpstreamVersion is this product's own version line, a bare YYYYMMDD,
// exactly as UPSTREAM_VERSION holds it (docs/decisions/0012).
//
//go:embed UPSTREAM_VERSION
var UpstreamVersion string

// Files is the data vmavs carries inside its binary, at the paths the
// repository keeps them (spec §3; the move to assets/ waits for phase 6,
// because the shell tree, Renovate and the ingredient fingerprints all
// read these paths today).
//
// pins.Ingredients globs components/*/version to find every component
// pin: naming a second component's version file here is what makes that
// glob find it, since go:embed only carries paths named explicitly below.
//
//go:embed assets/pins/sources.tsv components/openssh/version boot/config/config.plist media/apple-packages.sha256 image/payload/firstboot.sh image/payload/postinstall image/payload/com.mqg.firstboot.plist
var Files embed.FS
