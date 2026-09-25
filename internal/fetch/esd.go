package fetch

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

const (
	ESDSource       = "apple-installesd-10.9.5"
	DefaultRecovery = "http://osrecovery.apple.com"
	// From Mavericks Forever's get.sh, donated by dosdude1 from a broken
	// Mac (INHERITED; media/fetch-installesd.sh records the credit). They
	// are not this machine's and are not secrets.
	boardSerial = "C0243070168G3M91F"
	boardID     = "Mac-3CBD00234E554E41"
	rom         = "003EE1E6AC14"
)

// Recovery is Apple's osrecovery service. The transfer is plain HTTP by
// Apple's design (the token is a cookie and the payload is unencrypted),
// so the checksum is the only thing between this and a middlebox.
type Recovery struct {
	Base   string       // "" means DefaultRecovery
	Client *http.Client // nil means http.DefaultClient
	Rand   io.Reader    // nil means crypto/rand
}

func (rc Recovery) base() string {
	if rc.Base == "" {
		return DefaultRecovery
	}
	return rc.Base
}

func (rc Recovery) client() *http.Client {
	if rc.Client == nil {
		return http.DefaultClient
	}
	return rc.Client
}

// deriveKey is SHA-256 over client id, the server id's hex half, the ROM,
// SHA-256(serial+board id) and ten 0xCC bytes, as uppercase hex.
func deriveKey(clientID, serverID string) (string, error) {
	_, half, ok := strings.Cut(serverID, "~")
	if !ok {
		return "", fmt.Errorf("osrecovery returned no usable session id (got %q)", serverID)
	}
	h := sha256.New()
	for _, x := range []string{clientID, half, rom} {
		b, err := hex.DecodeString(x)
		if err != nil {
			return "", fmt.Errorf("bad hex %q: %w", x, err)
		}
		h.Write(b)
	}
	inner := sha256.Sum256([]byte(boardSerial + boardID))
	h.Write(inner[:])
	h.Write([]byte(strings.Repeat("\xcc", 10)))
	return strings.ToUpper(hex.EncodeToString(h.Sum(nil))), nil
}

// Handshake asks osrecovery for the installer's URL and a download token.
func (rc Recovery) Handshake(ctx context.Context) (assetURL, token string, err error) {
	rnd := rc.Rand
	if rnd == nil {
		rnd = rand.Reader
	}
	cid := make([]byte, 8)
	if _, err := io.ReadFull(rnd, cid); err != nil {
		return "", "", err
	}
	clientID := strings.ToUpper(hex.EncodeToString(cid))

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, rc.base()+"/", nil)
	resp, err := rc.client().Do(req)
	if err != nil {
		return "", "", fmt.Errorf("cannot reach osrecovery for a session id: %w", err)
	}
	resp.Body.Close()
	serverID := ""
	for _, c := range resp.Cookies() {
		serverID = c.Value // the shell took the jar's last cookie; prefer "session"
		if c.Name == "session" {
			break
		}
	}
	key, err := deriveKey(clientID, serverID)
	if err != nil {
		return "", "", err
	}
	body := fmt.Sprintf("cid=%s\nsn=%s\nbid=%s\nk=%s", clientID, boardSerial, boardID, key)
	req, _ = http.NewRequestWithContext(ctx, http.MethodPost, rc.base()+"/InstallationPayload/OSInstaller", strings.NewReader(body))
	req.Header.Set("Content-Type", "text/plain")
	req.AddCookie(&http.Cookie{Name: "session", Value: serverID})
	resp, err = rc.client().Do(req)
	if err != nil {
		return "", "", fmt.Errorf("InstallationPayload request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("InstallationPayload request was refused: %s", resp.Status)
	}
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "AU: "); ok {
			assetURL = v
		}
		if v, ok := strings.CutPrefix(sc.Text(), "AT: "); ok {
			token = v
		}
	}
	if assetURL == "" || token == "" {
		return "", "", fmt.Errorf("apple's installation payload had no asset URL or token")
	}
	return assetURL, token, nil
}

func (rc Recovery) offer(ctx context.Context, reg *pins.Registry) (pins.Source, string, error) {
	src, err := reg.Lookup(ESDSource)
	if err != nil {
		return pins.Source{}, "", err
	}
	url, token, err := rc.Handshake(ctx)
	if err != nil {
		return pins.Source{}, "", err
	}
	// The same handshake serves whatever OS Apple decides that board is
	// entitled to; silently installing a different one would be a long
	// afternoon (get.sh checks this too).
	if url != src.URL {
		return pins.Source{}, "", fmt.Errorf("apple offered %s, not the Mavericks InstallESD URL %s", url, src.URL)
	}
	return src, token, nil
}

// InstallESD is Apple's InstallESD.dmg, verified: from the cache, else
// adopted from an earlier download, else fetched from Apple.
func (g *Getter) InstallESD(ctx context.Context, reg *pins.Registry, rc Recovery, adopt []string) (string, error) {
	src, err := reg.Lookup(ESDSource)
	if err != nil {
		return "", err
	}
	fn, err := Filename(src.URL)
	if err != nil {
		return "", err
	}
	// Cache and adoption first: no handshake for a file already here. A
	// rotten cached file is an error, never a reason to fetch 5 GB again.
	p, err := g.Get(ctx, Item{Name: ESDSource, SHA256: src.SHA256, Filename: fn, Adopt: adopt, noFetch: true})
	if err == nil {
		return p, nil
	}
	if !errors.Is(err, errNotCached) {
		return "", err
	}
	_, token, err := rc.offer(ctx, reg)
	if err != nil {
		return "", err
	}
	h := http.Header{}
	h.Set("Cookie", "AssetToken="+token)
	g.logf("downloading InstallESD.dmg (about 5.2 GB, over plain HTTP)")
	return g.Get(ctx, Item{Name: ESDSource, URL: src.URL, SHA256: src.SHA256, Filename: fn, Header: h})
}

// Probe performs the handshake and asks the CDN for the size, downloading
// nothing: a measurement of Apple's side without 5 GB of traffic.
func (rc Recovery) Probe(ctx context.Context, reg *pins.Registry, c *http.Client) (string, int64, error) {
	src, token, err := rc.offer(ctx, reg)
	if err != nil {
		return "", 0, err
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodHead, src.URL, nil)
	req.Header.Set("Cookie", "AssetToken="+token)
	if c == nil {
		c = rc.client()
	}
	resp, err := c.Do(req)
	if err != nil {
		return "", 0, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("HEAD %s: %s", src.URL, resp.Status)
	}
	return src.URL, resp.ContentLength, nil
}
