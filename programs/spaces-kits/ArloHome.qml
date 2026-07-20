// Spaces OS — Arlo home UI kit (QML port of ArloHome.jsx / home/main.ts).
// The "Space" desktop: OS top bar, a centred conversation with Arlo, the
// orb + tagline, suggested prompts, and the ask bar.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  readonly property var clan: [
    {
      "n": "Saori",
      "s": "online"
    },
    {
      "n": "Matt",
      "s": "online"
    },
    {
      "n": "Fiona",
      "s": "busy"
    },
    {
      "n": "Christa",
      "s": "offline"
    }
  ]
  readonly property var suggestions: ["Summarise today’s Clan activity", "Build me a currency converter", "Find the Furano photos", "Start a call with Saori"]

  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop {
        position: 0.0
        color: Theme.white
      }
      GradientStop {
        position: 1.0
        color: Theme.clanSecondary50
      }
    }
  }

  // ---- top bar ----
  Rectangle {
    id: topBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: 52
    color: Qt.rgba(1, 1, 1, 0.7)

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      color: Theme.ink100
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 16

      Rectangle {
        height: 32
        width: switcher.implicitWidth + 20
        radius: Theme.radiusPill
        color: Theme.ink100
        anchors.verticalCenter: parent.verticalCenter

        Row {
          id: switcher
          anchors.centerIn: parent
          spacing: 8

          Rectangle {
            width: 16
            height: 16
            radius: 5
            color: Theme.clanPrimary700
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "Your Clan"
            font.family: Theme.fontUI
            font.pixelSize: Theme.fsSm
            font.weight: Theme.fwSemibold
            color: Theme.ink900
            anchors.verticalCenter: parent.verticalCenter
          }
          KinIcon {
            name: "chevron-down"
            size: 15
            color: Theme.ink400
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      Row {
        spacing: 4
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: ["Home", "Recents", "Help"]
          delegate: Text {
            id: navItem
            required property string modelData
            required property int index
            text: navItem.modelData
            font.family: Theme.fontUI
            font.pixelSize: Theme.fsSm
            font.weight: navItem.index === 0 ? Theme.fwSemibold : Theme.fwMedium
            color: navItem.index === 0 ? Theme.ink900 : Theme.ink400
            leftPadding: 12
            rightPadding: 12
            topPadding: 6
            bottomPadding: 6
          }
        }
      }
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 8

      Item {
        width: 28 + 3 * 20
        height: 28
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: root.clan
          delegate: KinAvatar {
            id: av
            required property var modelData
            required property int index
            dim: 28
            name: av.modelData.n
            status: av.modelData.s
            x: index * 20
          }
        }
      }
      KinIconButton {
        icon: "wifi"
        size: "sm"
        anchors.verticalCenter: parent.verticalCenter
      }
      KinIconButton {
        icon: "bluetooth"
        size: "sm"
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: "14:07"
        font.family: Theme.fontMono
        font.pixelSize: Theme.fsXs
        color: Theme.ink500
        anchors.verticalCenter: parent.verticalCenter
      }
      KinIconButton {
        icon: "settings"
        size: "sm"
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // ---- conversation ----
  Column {
    anchors.top: topBar.bottom
    anchors.topMargin: 40
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(760, parent.width - 48)
    spacing: 0

    Column {
      width: parent.width
      spacing: 0

      ArloOrb {
        dim: 96
        pulse: true
        anchors.horizontalCenter: parent.horizontalCenter
      }
      Item {
        width: parent.width
        height: 4
      }
      KinBadge {
        label: "Arlo · local agent"
        tone: "glass"
        anchors.horizontalCenter: parent.horizontalCenter
      }
      Item {
        width: parent.width
        height: 18
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.RichText
        horizontalAlignment: Text.AlignHCenter
        text: "A new <i>kinder</i> computer"
        font.family: Theme.fontUI
        font.pixelSize: Theme.fsDisplay
        font.weight: Theme.fwBold
        color: Theme.ink900
      }
    }

    Item {
      width: parent.width
      height: 36
    }

    // Arlo's opening message
    Row {
      width: parent.width
      spacing: 12

      ArloOrb {
        dim: 36
      }
      Rectangle {
        width: Math.min(520, parent.width - 48)
        implicitHeight: msgText.implicitHeight + 28
        radius: 18
        color: Theme.ink100

        Text {
          id: msgText
          anchors.fill: parent
          anchors.margins: 14
          anchors.leftMargin: 18
          anchors.rightMargin: 18
          wrapMode: Text.WordWrap
          text: "Good afternoon. I’m Arlo — your agent for this Space. What shall we make today?"
          font.family: Theme.fontUI
          font.pixelSize: 15
          color: Theme.ink900
        }
      }
    }
  }

  // ---- ask dock ----
  Column {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 22
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(760, parent.width - 48)
    spacing: 12

    Flow {
      width: parent.width
      spacing: 8

      Repeater {
        model: root.suggestions
        delegate: Rectangle {
          id: chip
          required property string modelData
          height: 34
          width: chipText.implicitWidth + 28
          radius: Theme.radiusPill
          color: Theme.white
          border.width: 1
          border.color: Qt.rgba(0, 0, 0, 0.06)

          Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.modelData
            font.family: Theme.fontUI
            font.pixelSize: Theme.fsXs
            color: Theme.ink700
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: 10

      KinInput {
        id: ask
        width: parent.width - voice.width - sendBtn.width - 20
        size: "lg"
        iconLeft: "sparkle"
        placeholder: "Ask Arlo anything…"
      }
      KinIconButton {
        id: voice
        icon: "phone"
        variant: "filled"
        size: "lg"
        anchors.verticalCenter: parent.verticalCenter
      }
      KinButton {
        id: sendBtn
        label: "Send"
        intent: "primary"
        size: "lg"
        iconRight: "arrow-up-right"
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 8

      KinIcon {
        name: "lock"
        size: 14
        color: Theme.ink400
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: "Runs locally on hardware you own. Your data stays in this Space."
        font.family: Theme.fontUI
        font.pixelSize: Theme.fsXs
        color: Theme.ink400
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
