// Kin / Spaces OS design tokens for the QML port of spaces-kits.
//
// The web kits author against native design-system CSS variables
// (--clan-*, --ink-*, --kin-*, --fs-*, --radius-*). This singleton is
// the QML equivalent: the same palette, type scale, radii and motion,
// exposed as typed properties so the ported components and screens read
// like their JSX/TS originals.
pragma Singleton

import QtQuick

QtObject {
  id: root

  // ---- Clan primary (teal-slate) — the product UI anchor ----
  readonly property color clanPrimary600: "#4b6767"
  readonly property color clanPrimary700: "#345253"
  readonly property color clanPrimary800: "#2b4647"

  // ---- Clan secondary (cool sage-grey) ----
  readonly property color clanSecondary50: "#f7f9fa"
  readonly property color clanSecondary300: "#afc6ca"
  readonly property color clanSecondary400: "#90b2b7"
  readonly property color clanSecondary600: "#4f747a"

  // ---- Semantic accents ----
  readonly property color clanInfo: "#06aaf1"
  readonly property color clanError: "#d75d9f"
  readonly property color clanError600: "#c43e81"
  readonly property color clanSuccess: "#17b239"
  readonly property color clanSuccess600: "#00962e"

  // ---- True neutrals ----
  readonly property color ink900: "#171717"
  readonly property color ink700: "#323232"
  readonly property color ink500: "#6b6b6b"
  readonly property color ink400: "#9ea39e"
  readonly property color ink300: "#d9d9d9"
  readonly property color ink200: "#ebebeb"
  readonly property color ink100: "#f3f3f3"
  readonly property color ink50: "#fafafa"
  readonly property color white: "#ffffff"

  // ---- Brand ----
  readonly property color kinSage: "#8a9b6f"
  readonly property color kinSky: "#bae6ff"
  // Arlo agent gradient endpoints (pink → indigo).
  readonly property color arloFrom: "#f9328d"
  readonly property color arloTo: "#5523eb"

  // ---- Ergonomic semantic aliases ----
  readonly property color surfacePage: root.white
  readonly property color surfaceCard: root.white
  readonly property color textPrimary: root.ink900
  readonly property color textSecondary: root.ink500
  readonly property color textTertiary: root.ink400
  readonly property color borderSubtle: root.ink200
  readonly property color focusRing: root.clanInfo

  // ---- Type ----
  // Inter is the OS UI face (the system's "Inter Tight" is a tighter cut;
  // Inter is its documented fallback and what the desktop installs). DM Mono
  // for metadata. Instrument Serif is the italic accent (the "kinder" word).
  readonly property string fontUI: "Inter"
  readonly property string fontMono: "DM Mono"
  readonly property string fontSerif: "Instrument Serif"

  readonly property int fs2xs: 10
  readonly property int fsXs: 12
  readonly property int fsSm: 14
  readonly property int fsMd: 16
  readonly property int fsLg: 18
  readonly property int fsXl: 24
  readonly property int fs2xl: 32
  readonly property int fsDisplay: 34

  readonly property int fwRegular: 400
  readonly property int fwMedium: 500
  readonly property int fwSemibold: 600
  readonly property int fwBold: 700

  // ---- Radii (soft is the rule; pill for actionable chrome) ----
  readonly property int radiusSm: 8
  readonly property int radiusMd: 12
  readonly property int radiusLg: 16
  readonly property int radiusXl: 20
  readonly property int radiusPill: 9999

  // ---- Motion ----
  readonly property int durFast: 120
  readonly property int durBase: 200
}
