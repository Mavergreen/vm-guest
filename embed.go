// Package vmguest is the repository root. It exists to carry files into
// the vmavs binary with go:embed, which cannot reach outside the directory
// of the package that uses it.
package vmguest

import _ "embed"

// UpstreamVersion is this product's own version line, a bare YYYYMMDD,
// exactly as UPSTREAM_VERSION holds it (docs/decisions/0012).
//
//go:embed UPSTREAM_VERSION
var UpstreamVersion string
