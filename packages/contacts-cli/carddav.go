package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/emersion/go-vcard"
	webdav "github.com/emersion/go-webdav"
	"github.com/emersion/go-webdav/carddav"
)

// Session bundles an authenticated CardDAV client with everything needed to
// also issue raw HTTP writes (PUT/DELETE) with precise conditional headers,
// which the go-webdav client does not expose.
type Session struct {
	client   *carddav.Client
	http     *http.Client
	origin   *url.URL // scheme://host used to resolve server-relative hrefs
	username string
	password string
}

// newSession authenticates and prepares a Session. The endpoint is resolved
// from cfg.Server: a value with an explicit scheme is used directly, otherwise
// it is treated as a domain and bootstrapped via RFC 6764 discovery.
func newSession(ctx context.Context, cfg Config) (*Session, error) {
	password, err := cfg.resolvePassword()
	if err != nil {
		return nil, err
	}

	endpoint, err := resolveEndpoint(ctx, cfg.Server)
	if err != nil {
		return nil, err
	}

	httpClient := webdav.HTTPClientWithBasicAuth(nil, cfg.Username, password)
	client, err := carddav.NewClient(httpClient, endpoint)
	if err != nil {
		return nil, fmt.Errorf("creating carddav client: %w", err)
	}

	origin, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parsing endpoint %q: %w", endpoint, err)
	}

	return &Session{
		client:   client,
		http:     http.DefaultClient,
		origin:   origin,
		username: cfg.Username,
		password: password,
	}, nil
}

// resolveEndpoint turns a domain or URL into a concrete CardDAV endpoint URL.
func resolveEndpoint(ctx context.Context, server string) (string, error) {
	if strings.Contains(server, "://") {
		return server, nil
	}
	endpoint, err := carddav.DiscoverContextURL(ctx, server)
	if err != nil {
		return "", fmt.Errorf("RFC 6764 discovery for %q failed: %w", server, err)
	}
	return endpoint, nil
}

// listAddressBooks performs the principal -> home-set -> books discovery chain.
func (s *Session) listAddressBooks(ctx context.Context) ([]carddav.AddressBook, error) {
	principal, err := s.client.FindCurrentUserPrincipal(ctx)
	if err != nil {
		return nil, fmt.Errorf("finding current user principal: %w", err)
	}
	homeSet, err := s.client.FindAddressBookHomeSet(ctx, principal)
	if err != nil {
		return nil, fmt.Errorf("finding address book home set: %w", err)
	}
	books, err := s.client.FindAddressBooks(ctx, homeSet)
	if err != nil {
		return nil, fmt.Errorf("finding address books: %w", err)
	}
	return books, nil
}

// resolveAddressBook returns the address book path to operate on: the
// configured one if set, otherwise the first one found via discovery.
func (s *Session) resolveAddressBook(ctx context.Context, configured string) (string, error) {
	if configured != "" {
		return configured, nil
	}
	books, err := s.listAddressBooks(ctx)
	if err != nil {
		return "", err
	}
	if len(books) == 0 {
		return "", fmt.Errorf("no address books found on server")
	}
	return books[0].Path, nil
}

// absURL resolves a possibly server-relative href against the endpoint origin.
func (s *Session) absURL(href string) string {
	ref, err := url.Parse(href)
	if err != nil {
		return href
	}
	return s.origin.ResolveReference(ref).String()
}

// put writes a vCard to path. When ifMatch is non-empty it is sent as an
// If-Match header (optimistic concurrency for edits); when ifNoneMatch is true
// an "If-None-Match: *" header is sent to refuse overwriting an existing
// resource (safe create). Returns the new ETag if the server provides one.
func (s *Session) put(ctx context.Context, path string, card vcard.Card, ifMatch string, ifNoneMatch bool) (string, error) {
	var buf bytes.Buffer
	if err := vcard.NewEncoder(&buf).Encode(card); err != nil {
		return "", fmt.Errorf("encoding vcard: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, s.absURL(path), &buf)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "text/vcard; charset=utf-8")
	if ifMatch != "" {
		req.Header.Set("If-Match", ifMatch)
	}
	if ifNoneMatch {
		req.Header.Set("If-None-Match", "*")
	}
	req.SetBasicAuth(s.username, s.password)

	resp, err := s.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if err := checkStatus(resp); err != nil {
		return "", err
	}
	return resp.Header.Get("ETag"), nil
}

// del removes the resource at path, optionally guarded by an If-Match ETag.
func (s *Session) del(ctx context.Context, path, ifMatch string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, s.absURL(path), nil)
	if err != nil {
		return err
	}
	if ifMatch != "" {
		req.Header.Set("If-Match", ifMatch)
	}
	req.SetBasicAuth(s.username, s.password)

	resp, err := s.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return checkStatus(resp)
}

// checkStatus turns a non-2xx response into an error including the body.
func checkStatus(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	msg := strings.TrimSpace(string(body))
	if msg == "" {
		msg = resp.Status
	}
	return fmt.Errorf("server returned %s: %s", resp.Status, msg)
}
