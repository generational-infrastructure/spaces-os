// Spaces OS — Files app UI kit (QML port of FilesApp.jsx / files/main.ts).
// Left rail, search/create top bar, and sectioned tiles (Recents / Shared /
// Favourites) in a 6-up grid.
pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  readonly property var recents: [
    {
      "name": "Project Ideas.md",
      "meta": "Just now",
      "kind": "doc"
    },
    {
      "name": "Backcountry.PDF",
      "meta": "Yesterday",
      "kind": "doc"
    },
    {
      "name": "Furano photos",
      "meta": "Folder · Photos",
      "kind": "folder"
    },
    {
      "name": "Application form",
      "meta": "Added 10 days ago",
      "kind": "doc"
    },
    {
      "name": "Dog posse",
      "meta": "Added 10 days ago",
      "kind": "image"
    },
    {
      "name": "Numazu Club",
      "meta": "Added 2 weeks ago",
      "kind": "image"
    }
  ]
  readonly property var shared: [
    {
      "name": "Create_Space_N",
      "meta": "Mov · Thursday",
      "kind": "doc"
    },
    {
      "name": "Founders Grotesk",
      "meta": "Folder · Fonts",
      "kind": "folder"
    },
    {
      "name": "Publico Banner",
      "meta": "Folder · Fonts",
      "kind": "folder"
    },
    {
      "name": "Widgets_flow.mov",
      "meta": "Thursday",
      "kind": "doc"
    },
    {
      "name": "Identity Guidelines",
      "meta": "Sep 12",
      "kind": "doc"
    },
    {
      "name": "River render",
      "meta": "Sep 10",
      "kind": "image"
    }
  ]
  readonly property var faves: [
    {
      "name": "Car research",
      "meta": "Folder · Personal",
      "kind": "folder"
    },
    {
      "name": "Rough cut 02",
      "meta": "MP3 · Aug 2",
      "kind": "audio"
    },
    {
      "name": "Sharp Sans",
      "meta": "Folder · Fonts",
      "kind": "folder"
    },
    {
      "name": "Floor plan",
      "meta": "PDF · Aug 6",
      "kind": "doc"
    },
    {
      "name": "Doc archive",
      "meta": "ZIP · Aug 3",
      "kind": "archive"
    },
    {
      "name": "Alterations",
      "meta": "PDF · Sep 3",
      "kind": "doc"
    }
  ]

  property string view: "grid"

  Rectangle {
    anchors.fill: parent
    color: Theme.white
  }

  // ---- left rail ----
  Rectangle {
    id: rail
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: 248
    color: Theme.clanSecondary50

    Column {
      anchors.fill: parent
      anchors.topMargin: 22
      anchors.leftMargin: 16
      anchors.rightMargin: 16
      spacing: 2

      Row {
        spacing: 22
        leftPadding: 8
        bottomPadding: 22

        Text {
          text: "Files"
          font.family: Theme.fontUI
          font.pixelSize: Theme.fsLg
          font.weight: Theme.fwSemibold
          color: Theme.ink900
        }
        Text {
          text: "Apps"
          font.family: Theme.fontUI
          font.pixelSize: Theme.fsLg
          font.weight: Theme.fwSemibold
          color: Theme.ink400
        }
      }

      Repeater {
        model: [
          {
            "icon": "home",
            "label": "Overview",
            "sel": true
          },
          {
            "icon": "clock",
            "label": "Recents",
            "sel": false
          },
          {
            "icon": "users",
            "label": "Clan",
            "sel": false
          },
          {
            "icon": "star",
            "label": "Favourites",
            "sel": false
          },
          {
            "icon": "folder",
            "label": "All files",
            "sel": false
          }
        ]
        delegate: KinSidebarItem {
          id: navRow
          required property var modelData
          width: parent.width
          icon: navRow.modelData.icon
          label: navRow.modelData.label
          selected: navRow.modelData.sel
        }
      }

      Text {
        text: "FAVOURITES"
        font.family: Theme.fontUI
        font.pixelSize: 11
        font.weight: Theme.fwBold
        font.letterSpacing: 1
        color: Theme.ink400
        topPadding: 22
        leftPadding: 12
        bottomPadding: 8
      }

      Repeater {
        model: ["Car research", "Rough Soundtrack 02", "Sharp Sans", "Apartment floor plan", "Doc archive"]
        delegate: Row {
          id: faveRow
          required property string modelData
          width: parent.width
          height: 32
          leftPadding: 12
          spacing: 10

          KinIcon {
            name: "folder"
            size: 17
            color: Theme.clanSecondary400
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: faveRow.modelData
            elide: Text.ElideRight
            font.family: Theme.fontUI
            font.pixelSize: 13
            color: Theme.ink700
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }

    Row {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: 28
      anchors.bottomMargin: 22
      spacing: 10

      KinIcon {
        name: "trash"
        size: 18
        color: Theme.ink500
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: "Bin"
        font.family: Theme.fontUI
        font.pixelSize: 13
        color: Theme.ink500
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // ---- main ----
  Item {
    id: main
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: rail.right
    anchors.right: parent.right

    // header
    Row {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: 20
      anchors.leftMargin: 32
      anchors.rightMargin: 32
      height: 48
      spacing: 16

      KinInput {
        id: search
        width: parent.width - createBtn.width - seg.width - 32
        size: "lg"
        iconLeft: "search"
        placeholder: "Search all your files"
        anchors.verticalCenter: parent.verticalCenter
      }
      KinButton {
        id: createBtn
        label: "Create"
        intent: "secondary"
        size: "lg"
        iconLeft: "plus"
        anchors.verticalCenter: parent.verticalCenter
      }
      KinSegmentedControl {
        id: seg
        anchors.verticalCenter: parent.verticalCenter
        value: root.view
        options: [
          {
            "value": "grid",
            "icon": "grid"
          },
          {
            "value": "list",
            "icon": "list"
          }
        ]
        onChanged: v => root.view = v
      }
    }

    Flickable {
      anchors.top: header.bottom
      anchors.topMargin: 12
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: 32
      anchors.rightMargin: 32
      contentHeight: sections.implicitHeight
      clip: true

      Column {
        id: sections
        width: parent.width
        spacing: 38
        bottomPadding: 40

        Repeater {
          model: [
            {
              "title": "Recents",
              "items": root.recents
            },
            {
              "title": "Shared",
              "items": root.shared
            },
            {
              "title": "Favourites",
              "items": root.faves
            }
          ]
          delegate: Column {
            id: section
            required property var modelData
            width: parent.width
            spacing: 18

            readonly property int tileGap: 20
            readonly property real tileW: (width - tileGap * 5) / 6

            Row {
              width: parent.width

              Text {
                text: section.modelData.title
                font.family: Theme.fontUI
                font.pixelSize: 20
                font.weight: Theme.fwSemibold
                color: Theme.ink900
              }
              Item {
                width: parent.width - viewAll.implicitWidth - sectionTitleSpacer.width
                height: 1
                id: sectionTitleSpacer
              }
              Text {
                id: viewAll
                text: "View all"
                font.family: Theme.fontUI
                font.pixelSize: 13
                color: Theme.ink400
              }
            }

            Grid {
              width: parent.width
              columns: 6
              columnSpacing: section.tileGap
              rowSpacing: section.tileGap

              Repeater {
                model: section.modelData.items
                delegate: KinFileTile {
                  id: tile
                  required property var modelData
                  width: section.tileW
                  name: tile.modelData.name
                  meta: tile.modelData.meta
                  kind: tile.modelData.kind
                }
              }
            }
          }
        }
      }
    }
  }
}
