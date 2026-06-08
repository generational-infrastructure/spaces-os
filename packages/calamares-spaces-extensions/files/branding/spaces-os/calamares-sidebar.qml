/* SPDX-FileCopyrightText: no
 * SPDX-License-Identifier: CC0-1.0
 *
 * Spaces OS Calamares sidebar.
 *
 * Replaces the default widget progress tree (a QTreeView + ProgressTreeDelegate
 * that center-aligns labels, can't host a wide wordmark, and ignores QSS) with
 * a QML sidebar, selected via `sidebar: qml` in branding.desc. Calamares loads
 * `calamares-sidebar.qml` from the branding component directory
 * (CalamaresWindow.cpp getQmlSidebar -> searchQmlFile, branding has precedence
 * over the QRC copy) and exposes the Branding + ViewManager singletons plus a
 * `debug` context object.
 *
 * Layout follows mockup-welcome.png: the SPACES wordmark header centered at the
 * top, then the step list with left-aligned labels and a rounded pill behind the
 * active step. Colors come from the same branding.desc `style:` entries the
 * widget delegate used, so the light monochrome palette stays single-sourced.
 *
 * Note: QSS (stylesheet.qss) does NOT reach QML items, so the Geist font is
 * selected here explicitly (font.family); it resolves through the live
 * environment's fontconfig (fonts.packages in installer-iso.nix). The wordmark
 * is the rasterised `spaces-logo-wordmark-spaces.svg`, wired through the
 * productLogo branding slot (unused elsewhere once the sidebar is QML) and
 * loaded the same way the upstream sample sidebar loads its logo.
 */
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: sideBar
    anchors.fill: parent
    color: Branding.styleString( Branding.SidebarBackground )

    ColumnLayout {
        anchors.fill: parent
        spacing: 2

        // SPACES wordmark header, centered at the top like the mockup. A left
        // margin would fight the centered alignment, so the wordmark carries
        // only vertical margins. productLogo points at the rasterised wordmark;
        // imagePath() returns an absolute path, so "file://" + path yields a
        // valid file:/// URL.
        Image {
            id: wordmark
            Layout.topMargin: 26
            Layout.bottomMargin: 22
            Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
            source: "file://" + Branding.imagePath( Branding.ProductLogo )
            fillMode: Image.PreserveAspectFit
            // Crisp raster: ask for more pixels than displayed, then pin the
            // on-screen width and let height follow the wordmark's aspect.
            sourceSize.width: 420
            Layout.preferredWidth: 140
            Layout.preferredHeight: Layout.preferredWidth * ( implicitHeight / implicitWidth )
        }

        // Step list. ViewManager is a list model whose `display` role is the
        // step name and whose rows map 1:1 to the installer steps; the active
        // row is ViewManager.currentStepIndex.
        Repeater {
            model: ViewManager

            delegate: Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 42

                property bool current: index === ViewManager.currentStepIndex

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    radius: 8
                    color: parent.current
                        ? Branding.styleString( Branding.SidebarBackgroundCurrent )
                        : "transparent"

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        text: display
                        font.family: "Geist"
                        font.pixelSize: 15
                        font.weight: parent.parent.current ? Font.DemiBold : Font.Normal
                        color: parent.parent.current
                            ? Branding.styleString( Branding.SidebarTextCurrent )
                            : Branding.styleString( Branding.SidebarText )
                    }
                }
            }
        }

        // Push the meta row to the bottom.
        Item {
            Layout.fillHeight: true
        }

        // Minimal About affordance (the widget sidebar shows one too). Kept
        // small and muted so it stays out of the way of the mockup layout.
        Text {
            Layout.leftMargin: 24
            Layout.bottomMargin: 18
            Layout.alignment: Qt.AlignLeft | Qt.AlignBottom
            text: qsTr( "About" )
            font.family: "Geist"
            font.pixelSize: 12
            color: Branding.styleString( Branding.SidebarText )

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: debug.about()
            }
        }
    }
}
