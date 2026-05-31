package main

import (
	"context"
	"strings"
	"testing"

	"github.com/emersion/go-vcard"
	"github.com/emersion/go-webdav/carddav"
)

func TestParseMatchType(t *testing.T) {
	cases := map[string]carddav.MatchType{
		"contains":    carddav.MatchContains,
		"equals":      carddav.MatchEquals,
		"starts-with": carddav.MatchStartsWith,
		"ends-with":   carddav.MatchEndsWith,
	}
	for in, want := range cases {
		got, err := parseMatchType(in)
		if err != nil {
			t.Errorf("parseMatchType(%q) unexpected error: %v", in, err)
		}
		if got != want {
			t.Errorf("parseMatchType(%q) = %q, want %q", in, got, want)
		}
	}
	if _, err := parseMatchType("nonsense"); err == nil {
		t.Error("parseMatchType(\"nonsense\") expected error, got nil")
	}
}

func TestNewUID(t *testing.T) {
	a, b := newUID(), newUID()
	if a == b {
		t.Error("newUID returned duplicate values")
	}
	if !strings.HasPrefix(a, "urn:uuid:") {
		t.Errorf("newUID() = %q, want urn:uuid: prefix", a)
	}
}

func TestEnsureVersion(t *testing.T) {
	card := vcard.Card{}
	card.SetValue(vcard.FieldFormattedName, "Ada Lovelace")
	ensureVersion(card)
	if v := card.Value(vcard.FieldVersion); v == "" {
		t.Error("ensureVersion did not set a VERSION")
	}

	// An explicit version must be preserved.
	card2 := vcard.Card{}
	card2.SetValue(vcard.FieldVersion, "3.0")
	ensureVersion(card2)
	if v := card2.Value(vcard.FieldVersion); v != "3.0" {
		t.Errorf("ensureVersion overwrote VERSION: got %q, want 3.0", v)
	}
}

func TestOverlay(t *testing.T) {
	s := "original"
	overlay(&s, "")
	if s != "original" {
		t.Errorf("overlay with empty changed value to %q", s)
	}
	overlay(&s, "new")
	if s != "new" {
		t.Errorf("overlay = %q, want new", s)
	}
}

func TestResolveEndpointURLPassthrough(t *testing.T) {
	const u = "https://dav.example.com/dav/"
	got, err := resolveEndpoint(context.Background(), u)
	if err != nil {
		t.Fatalf("resolveEndpoint(%q) error: %v", u, err)
	}
	if got != u {
		t.Errorf("resolveEndpoint(%q) = %q, want passthrough", u, got)
	}
}

func TestFileNameFor(t *testing.T) {
	cases := map[string]string{
		"/dav/users/alice/contacts/abc.vcf":    "abc.vcf",
		"/dav/users/alice/contacts/ab%20c.vcf": "ab c.vcf",
		"https://h/dav/c/urn:uuid:1234.vcf":    "urn:uuid:1234.vcf",
		"/dav/c/no-extension":                  "no-extension.vcf",
		"/dav/c/%2e%2e%2fescape.vcf":           "escape.vcf", // path traversal stripped
	}
	for in, want := range cases {
		if got := fileNameFor(in); got != want {
			t.Errorf("fileNameFor(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStripEncodedPhotos(t *testing.T) {
	card := vcard.Card{}
	card.SetValue(vcard.FieldFormattedName, "Ada Lovelace")
	// data: URI photo (vCard 4.0) — should be stripped.
	card.Add(vcard.FieldPhoto, &vcard.Field{Value: "data:image/jpeg;base64,/9j/4AAQ=="})
	// ENCODING=b photo (vCard 3.0) — should be stripped.
	card.Add(vcard.FieldLogo, &vcard.Field{Value: "SGVsbG8=", Params: vcard.Params{"ENCODING": {"b"}}})
	// URL reference — should be kept.
	card.Add(vcard.FieldSound, &vcard.Field{Value: "https://example.com/a.mp3"})

	stripEncodedPhotos(card)

	if _, ok := card[vcard.FieldPhoto]; ok {
		t.Error("data: URI PHOTO was not stripped")
	}
	if _, ok := card[vcard.FieldLogo]; ok {
		t.Error("base64 LOGO was not stripped")
	}
	if card.Value(vcard.FieldSound) != "https://example.com/a.mp3" {
		t.Error("URL SOUND reference should have been kept")
	}
	if card.Value(vcard.FieldFormattedName) != "Ada Lovelace" {
		t.Error("non-media field was disturbed")
	}
}

func TestIsEncodedBlob(t *testing.T) {
	cases := []struct {
		field *vcard.Field
		want  bool
	}{
		{&vcard.Field{Value: "data:image/png;base64,AAAA"}, true},
		{&vcard.Field{Value: "x", Params: vcard.Params{"ENCODING": {"BASE64"}}}, true},
		{&vcard.Field{Value: "x", Params: vcard.Params{"ENCODING": {"b"}}}, true},
		{&vcard.Field{Value: "https://example.com/p.jpg"}, false},
		{&vcard.Field{Value: "tel:+123"}, false},
	}
	for i, c := range cases {
		if got := isEncodedBlob(c.field); got != c.want {
			t.Errorf("case %d: isEncodedBlob = %v, want %v", i, got, c.want)
		}
	}
}

func TestToOutput(t *testing.T) {
	card := vcard.Card{}
	card.SetValue(vcard.FieldVersion, "4.0")
	card.SetValue(vcard.FieldFormattedName, "Grace Hopper")
	card.SetValue(vcard.FieldUID, "urn:uuid:abc")

	out, err := toOutput("/books/c/abc.vcf", "\"etag123\"", card)
	if err != nil {
		t.Fatalf("toOutput error: %v", err)
	}
	if out.FN != "Grace Hopper" || out.UID != "urn:uuid:abc" {
		t.Errorf("toOutput summary fields wrong: %+v", out)
	}
	if !strings.Contains(out.VCard, "FN:Grace Hopper") {
		t.Errorf("toOutput vcard text missing FN: %q", out.VCard)
	}
}
