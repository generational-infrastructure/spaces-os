// contacts-cli is a small, server-agnostic CardDAV command-line client.
//
// It talks to any standards-compliant CardDAV server directly over HTTP (no
// local mirror) and emits JSON, so it is convenient to drive from scripts and
// agents. Discovery follows RFC 6764; writes use conditional requests
// (If-Match / If-None-Match) for safe concurrent edits.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/emersion/go-vcard"
	"github.com/emersion/go-webdav/carddav"
)

const usage = `contacts-cli — server-agnostic CardDAV client

Usage:
  contacts <command> [flags]

Commands:
  discover                 List address books on the server
  search <query>           Search contacts (server-side); empty query lists all
  get <path>               Fetch a single contact by its href/path
  new                      Create a contact from a vCard on stdin
  edit <path>              Replace a contact from a vCard on stdin
  delete <path>            Delete a contact
  backup --out DIR         Export every contact as raw .vcf files (vdir)

Global flags (also via env / config file):
  --server        Domain (RFC 6764 discovery) or full endpoint URL  [CONTACTS_SERVER]
  --username      HTTP Basic auth user                              [CONTACTS_USERNAME]
  --password      HTTP Basic auth password                          [CONTACTS_PASSWORD]
  --password-cmd  Command printing the password, e.g. 'passage show carddav' [CONTACTS_PASSWORD_CMD]
  --book          Address book path (default: first discovered)     [CONTACTS_ADDRESSBOOK]

Config file: $XDG_CONFIG_HOME/contacts-cli/config.json (keys: server, username,
password, passwordCmd, addressbook). Precedence: flags > env > file.
`

// objectOutput is the JSON shape emitted for a contact.
type objectOutput struct {
	Path  string `json:"path"`
	ETag  string `json:"etag,omitempty"`
	UID   string `json:"uid,omitempty"`
	FN    string `json:"fn,omitempty"`
	VCard string `json:"vcard"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "discover":
		err = cmdDiscover(args)
	case "search":
		err = cmdSearch(args)
	case "get":
		err = cmdGet(args)
	case "new":
		err = cmdNew(args)
	case "edit":
		err = cmdEdit(args)
	case "delete":
		err = cmdDelete(args)
	case "backup":
		err = cmdBackup(args)
	case "-h", "--help", "help":
		fmt.Fprint(os.Stdout, usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// globalFlags registers the shared connection flags on fs and returns the
// partially-filled Config to merge over env/file in loadConfig.
func globalFlags(fs *flag.FlagSet) *Config {
	c := &Config{}
	fs.StringVar(&c.Server, "server", "", "CardDAV domain or endpoint URL")
	fs.StringVar(&c.Username, "username", "", "HTTP Basic auth username")
	fs.StringVar(&c.Password, "password", "", "HTTP Basic auth password")
	fs.StringVar(&c.PasswordCmd, "password-cmd", "", "command that prints the password")
	fs.StringVar(&c.AddressBook, "book", "", "address book path")
	return c
}

// parseConfig registers global flags, parses args, and loads the merged config.
// It performs no network I/O, so cheap validation can run before connecting.
func parseConfig(fs *flag.FlagSet, args []string) (Config, error) {
	flags := globalFlags(fs)
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	return loadConfig(*flags)
}

func cmdDiscover(args []string) error {
	fs := flag.NewFlagSet("discover", flag.ContinueOnError)
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	books, err := sess.listAddressBooks(ctx)
	if err != nil {
		return err
	}
	out := make([]map[string]any, 0, len(books))
	for _, b := range books {
		out = append(out, map[string]any{
			"path":        b.Path,
			"name":        b.Name,
			"description": b.Description,
		})
	}
	return emitJSON(out)
}

func cmdSearch(args []string) error {
	fs := flag.NewFlagSet("search", flag.ContinueOnError)
	field := fs.String("field", "FN", "vCard property to match (e.g. FN, EMAIL, TEL, N)")
	match := fs.String("match", "contains", "match type: contains|equals|starts-with|ends-with")
	limit := fs.Int("limit", 0, "max results (0 = unlimited)")
	photos := fs.Bool("photos", false, "include inline-encoded photos/logos/sounds in output")
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	query := strings.TrimSpace(strings.Join(fs.Args(), " "))
	includePhotos := resolveIncludePhotos(fs, *photos, cfg)

	matchType, err := parseMatchType(*match)
	if err != nil {
		return err
	}
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	book, err := sess.resolveAddressBook(ctx, cfg.AddressBook)
	if err != nil {
		return err
	}

	q := &carddav.AddressBookQuery{
		DataRequest: carddav.AddressDataRequest{AllProp: true},
		Limit:       *limit,
	}
	if query != "" {
		q.PropFilters = []carddav.PropFilter{{
			Name:        *field,
			TextMatches: []carddav.TextMatch{{Text: query, MatchType: matchType}},
		}}
	}

	objs, err := sess.client.QueryAddressBook(ctx, book, q)
	if err != nil {
		return fmt.Errorf("querying address book: %w", err)
	}
	out := make([]objectOutput, 0, len(objs))
	for _, o := range objs {
		if !includePhotos {
			stripEncodedPhotos(o.Card)
		}
		rec, err := toOutput(o.Path, o.ETag, o.Card)
		if err != nil {
			return err
		}
		out = append(out, rec)
	}
	return emitJSON(out)
}

func cmdGet(args []string) error {
	fs := flag.NewFlagSet("get", flag.ContinueOnError)
	photos := fs.Bool("photos", false, "include inline-encoded photos/logos/sounds in output")
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	path := fs.Arg(0)
	if path == "" {
		return fmt.Errorf("get requires a contact path argument")
	}
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	obj, err := sess.client.GetAddressObject(ctx, path)
	if err != nil {
		return fmt.Errorf("getting %s: %w", path, err)
	}
	if !resolveIncludePhotos(fs, *photos, cfg) {
		stripEncodedPhotos(obj.Card)
	}
	rec, err := toOutput(obj.Path, obj.ETag, obj.Card)
	if err != nil {
		return err
	}
	return emitJSON(rec)
}

func cmdNew(args []string) error {
	fs := flag.NewFlagSet("new", flag.ContinueOnError)
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	card, err := readCard(os.Stdin)
	if err != nil {
		return err
	}
	ensureVersion(card)
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	uid := card.Value(vcard.FieldUID)
	if uid == "" {
		uid = newUID()
		card.SetValue(vcard.FieldUID, uid)
	}
	book, err := sess.resolveAddressBook(ctx, cfg.AddressBook)
	if err != nil {
		return err
	}
	path := strings.TrimRight(book, "/") + "/" + uid + ".vcf"

	etag, err := sess.put(ctx, path, card, "", true)
	if err != nil {
		return fmt.Errorf("creating contact: %w", err)
	}
	rec, err := toOutput(path, etag, card)
	if err != nil {
		return err
	}
	return emitJSON(rec)
}

func cmdEdit(args []string) error {
	fs := flag.NewFlagSet("edit", flag.ContinueOnError)
	etag := fs.String("etag", "", "ETag to guard the write (If-Match); fetched automatically if empty")
	force := fs.Bool("force", false, "skip the If-Match guard and overwrite unconditionally")
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	path := fs.Arg(0)
	if path == "" {
		return fmt.Errorf("edit requires a contact path argument")
	}
	card, err := readCard(os.Stdin)
	if err != nil {
		return err
	}
	ensureVersion(card)
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}

	guard := *etag
	if !*force && guard == "" {
		obj, err := sess.client.GetAddressObject(ctx, path)
		if err != nil {
			return fmt.Errorf("fetching current ETag for %s: %w", path, err)
		}
		guard = obj.ETag
	}
	if *force {
		guard = ""
	}

	newETag, err := sess.put(ctx, path, card, guard, false)
	if err != nil {
		return fmt.Errorf("editing contact: %w", err)
	}
	rec, err := toOutput(path, newETag, card)
	if err != nil {
		return err
	}
	return emitJSON(rec)
}

func cmdDelete(args []string) error {
	fs := flag.NewFlagSet("delete", flag.ContinueOnError)
	etag := fs.String("etag", "", "ETag to guard the delete (If-Match); fetched automatically if empty")
	force := fs.Bool("force", false, "skip the If-Match guard and delete unconditionally")
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	path := fs.Arg(0)
	if path == "" {
		return fmt.Errorf("delete requires a contact path argument")
	}
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	guard := *etag
	if !*force && guard == "" {
		obj, err := sess.client.GetAddressObject(ctx, path)
		if err != nil {
			return fmt.Errorf("fetching current ETag for %s: %w", path, err)
		}
		guard = obj.ETag
	}
	if *force {
		guard = ""
	}
	if err := sess.del(ctx, path, guard); err != nil {
		return fmt.Errorf("deleting contact: %w", err)
	}
	return emitJSON(map[string]string{"path": path, "status": "deleted"})
}

func cmdBackup(args []string) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	out := fs.String("out", "", "output directory for the vdir (required)")
	cfg, err := parseConfig(fs, args)
	if err != nil {
		return err
	}
	if *out == "" {
		return fmt.Errorf("backup requires --out DIR")
	}
	ctx := context.Background()
	sess, err := newSession(ctx, cfg)
	if err != nil {
		return err
	}
	book, err := sess.resolveAddressBook(ctx, cfg.AddressBook)
	if err != nil {
		return err
	}

	// One REPORT returns every contact with its full card. The cards are
	// re-encoded on write, yielding canonical (deterministically ordered)
	// vCards that diff cleanly when this vdir is tracked in git.
	objs, err := sess.client.QueryAddressBook(ctx, book, &carddav.AddressBookQuery{
		DataRequest: carddav.AddressDataRequest{AllProp: true},
	})
	if err != nil {
		return fmt.Errorf("downloading contacts: %w", err)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", *out, err)
	}

	files := make([]string, 0, len(objs))
	for _, o := range objs {
		text, err := encodeCard(o.Card)
		if err != nil {
			return fmt.Errorf("encoding %s: %w", o.Path, err)
		}
		name := fileNameFor(o.Path)
		dest := filepath.Join(*out, name)
		if err := os.WriteFile(dest, []byte(text), 0o644); err != nil {
			return fmt.Errorf("writing %s: %w", dest, err)
		}
		files = append(files, name)
	}

	return emitJSON(map[string]any{
		"format": "vdir",
		"book":   book,
		"dir":    *out,
		"count":  len(files),
		"files":  files,
	})
}

// --- helpers ---

// fileNameFor derives a safe vdir filename from a resource href: the
// URL-decoded last path segment (typically "<UID>.vcf"), stripped of any
// directory components so it cannot escape the output directory.
func fileNameFor(href string) string {
	base := path.Base(strings.TrimRight(href, "/"))
	if unesc, err := url.PathUnescape(base); err == nil {
		base = unesc
	}
	base = filepath.Base(base) // collapse any separators introduced by decoding
	if base == "" || base == "." || base == string(filepath.Separator) {
		base = "contact"
	}
	if !strings.HasSuffix(strings.ToLower(base), ".vcf") {
		base += ".vcf"
	}
	return base
}

// mediaFields are properties that commonly carry large inline base64 blobs.
var mediaFields = []string{vcard.FieldPhoto, vcard.FieldLogo, vcard.FieldSound}

// stripEncodedPhotos removes inline-encoded media (base64-encoded values or
// data: URIs) from the card, while keeping small URL/URI references intact.
// This keeps bulky binary blobs out of search/get output.
func stripEncodedPhotos(card vcard.Card) {
	for _, name := range mediaFields {
		fields := card[name]
		if len(fields) == 0 {
			continue
		}
		kept := fields[:0]
		for _, f := range fields {
			if !isEncodedBlob(f) {
				kept = append(kept, f)
			}
		}
		if len(kept) == 0 {
			delete(card, name)
		} else {
			card[name] = kept
		}
	}
}

// isEncodedBlob reports whether a field carries an inline binary value, either
// as a data: URI (vCard 4.0) or via ENCODING=b/base64 (vCard 3.0).
func isEncodedBlob(f *vcard.Field) bool {
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(f.Value)), "data:") {
		return true
	}
	switch strings.ToLower(f.Params.Get("ENCODING")) {
	case "b", "base64":
		return true
	}
	return false
}

// flagWasSet reports whether the named flag was explicitly provided, so a
// command-line --photos can override the config/env default in either
// direction (--photos / --photos=false).
func flagWasSet(fs *flag.FlagSet, name string) bool {
	set := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			set = true
		}
	})
	return set
}

// resolveIncludePhotos applies precedence flag > env/file for the photo toggle.
func resolveIncludePhotos(fs *flag.FlagSet, flagVal bool, cfg Config) bool {
	if flagWasSet(fs, "photos") {
		return flagVal
	}
	return cfg.IncludePhotos
}

func parseMatchType(s string) (carddav.MatchType, error) {
	switch s {
	case "contains":
		return carddav.MatchContains, nil
	case "equals":
		return carddav.MatchEquals, nil
	case "starts-with":
		return carddav.MatchStartsWith, nil
	case "ends-with":
		return carddav.MatchEndsWith, nil
	default:
		return "", fmt.Errorf("invalid --match %q (want contains|equals|starts-with|ends-with)", s)
	}
}

// readCard decodes exactly one vCard from r.
func readCard(r io.Reader) (vcard.Card, error) {
	card, err := vcard.NewDecoder(r).Decode()
	if err != nil {
		return nil, fmt.Errorf("decoding vcard from stdin: %w", err)
	}
	return card, nil
}

// ensureVersion guarantees the card carries a VERSION, upgrading to 4.0 when
// absent (go-vcard's encoder requires it).
func ensureVersion(card vcard.Card) {
	if card.Value(vcard.FieldVersion) == "" {
		vcard.ToV4(card)
	}
}

// newUID returns a random URN-style UID for a new contact.
func newUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return "urn:uuid:" + hex.EncodeToString(b[:])
}

// toOutput renders a vCard plus its metadata into the JSON output shape.
func toOutput(path, etag string, card vcard.Card) (objectOutput, error) {
	text, err := encodeCard(card)
	if err != nil {
		return objectOutput{}, err
	}
	return objectOutput{
		Path:  path,
		ETag:  etag,
		UID:   card.Value(vcard.FieldUID),
		FN:    card.Value(vcard.FieldFormattedName),
		VCard: text,
	}, nil
}

// encodeCard serialises a card to its textual vCard representation.
func encodeCard(card vcard.Card) (string, error) {
	var sb strings.Builder
	if err := vcard.NewEncoder(&sb).Encode(card); err != nil {
		return "", fmt.Errorf("encoding vcard: %w", err)
	}
	return sb.String(), nil
}

// emitJSON writes v as indented JSON to stdout.
func emitJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
