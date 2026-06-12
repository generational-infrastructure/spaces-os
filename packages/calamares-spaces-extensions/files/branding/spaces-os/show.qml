/* SPDX-FileCopyrightText: no
 * SPDX-License-Identifier: CC0-1.0
 *
 * Spaces OS install-step slideshow.
 *
 * Shown by ExecutionViewStep while the install jobs run (the only
 * branding-controlled imagery surface on that page -- branding.desc's
 * `images:` keys have no exec-page slot). Replaces the upstream NixOS
 * slideshow inherited via the `cp -r branding/nixos branding/spaces-os`
 * fork, whose slides carry NixOS-specific copy and gfx-landing-* art.
 *
 * The three frames are the Spaces hero's inner panel themed per slogan
 * (hero-inner-{declarative,reliable,reproducable}.png from the
 * spaces-logos gist, 1422x340 with rounded corners baked in). They map
 * 1:1 onto the upstream slideshow's three slogan slides, so they are
 * wired the same way: one Slide per frame, advanced by a Timer through
 * the slideshow API v2 Presentation (activatedInCalamares starts it
 * when the exec page becomes visible). A 10s interval keeps the cycle
 * visible even for the short offline install (upstream's 20s would
 * barely show a second frame).
 */
import QtQuick 2.5;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    // Deterministic white canvas behind the frames: the QQuickWidget
    // otherwise paints the ambient Qt palette, which need not match the
    // white #mainApp content area stylesheet.qss establishes.
    Rectangle {
        anchors.fill: parent
        color: "#FFFFFF"
    }

    Timer {
        id: advanceTimer
        interval: 10000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Image {
            id: artDeclarative
            source: "hero-inner-declarative.png"
            anchors.centerIn: parent
            // Cap at half the native 1422px width: the frames are
            // rendered at 2x, so ~711 logical px stays crisp at HiDPI
            // while filling the slide on the maximized window.
            width: Math.min(parent.width, 711)
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.top: artDeclarative.bottom
            anchors.topMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Declarative"
            font.family: "Geist"
            font.pixelSize: 22
            font.weight: Font.DemiBold
            color: "#18181B"
        }
    }

    Slide {
        Image {
            id: artReliable
            source: "hero-inner-reliable.png"
            anchors.centerIn: parent
            width: Math.min(parent.width, 711)
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.top: artReliable.bottom
            anchors.topMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Reliable"
            font.family: "Geist"
            font.pixelSize: 22
            font.weight: Font.DemiBold
            color: "#18181B"
        }
    }

    Slide {
        Image {
            id: artReproducible
            source: "hero-inner-reproducable.png"
            anchors.centerIn: parent
            width: Math.min(parent.width, 711)
            fillMode: Image.PreserveAspectFit
        }
        Text {
            anchors.top: artReproducible.bottom
            anchors.topMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Reproducible"
            font.family: "Geist"
            font.pixelSize: 22
            font.weight: Font.DemiBold
            color: "#18181B"
        }
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
