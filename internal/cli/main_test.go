package cli

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
)

// TestMain gives every test in this package an HTTP client that refuses
// any host but this one's loopback, in place of http.DefaultClient: an
// Env whose Endpoints (or registry) still name a real server cannot reach
// it from a test, now or after some future change.
func TestMain(m *testing.M) {
	defaultHTTP = loopbackOnlyClient()
	os.Exit(m.Run())
}

func loopbackOnlyClient() *http.Client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.Proxy = nil // HTTP(S)_PROXY must not carry a request off this host either
	return &http.Client{Transport: loopbackOnly{t}}
}

type loopbackOnly struct{ next http.RoundTripper }

// RoundTrip answers a request for any other host itself, with a 403 --
// not an error, which fetch would retry with backoff, slowly.
func (l loopbackOnly) RoundTrip(r *http.Request) (*http.Response, error) {
	host := r.URL.Hostname()
	if ip := net.ParseIP(host); host == "localhost" || (ip != nil && ip.IsLoopback()) {
		return l.next.RoundTrip(r)
	}
	if r.Body != nil {
		r.Body.Close()
	}
	msg := fmt.Sprintf("the cli tests' loopback-only transport refused %s", r.URL)
	return &http.Response{
		Status:     "403 refused by the cli tests' loopback-only transport",
		StatusCode: http.StatusForbidden,
		Proto:      "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1,
		Header:        http.Header{},
		Body:          io.NopCloser(strings.NewReader(msg)),
		ContentLength: int64(len(msg)),
		Request:       r,
	}, nil
}
