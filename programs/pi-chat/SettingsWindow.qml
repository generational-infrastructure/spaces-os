// Standalone settings window.
//
// Replaces noctalia's plugin-settings dialog (`pluginApi`-mediated).
// Opened on demand from the panel header; persists into our own
// Commons.Settings adapter.
//
// FloatingWindow (not PanelWindow) because a settings dialog is a
// modal, transient window — it should appear in the window list
// when open, get focus, and behave like any other app dialog.
//
// The Integrations section talks straight to the per-user broker over
// $XDG_RUNTIME_DIR/spaces-integrations.sock (IntegrationsBridge). This
// panel→broker path provisions secrets and flips the enable flag; it is
// disjoint from the agent runtime, which never sees this socket. The
// form is rendered entirely from the broker's `list` reply — secret
// *names* and descriptions, never values.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

FloatingWindow {
  id: root

  title: "pi-chat settings"
  implicitWidth: 480
  implicitHeight: 420
  minimumSize: Qt.size(400, 280)

  color: Color.mSurface

  // Broker socket address; overridable so headless checks can point the
  // bridge at a fake. Production resolves the per-user runtime socket.
  property string integrationsSockPath: String(Quickshell.env("XDG_RUNTIME_DIR") || "") + "/spaces-integrations.sock"

  // Inline device-setup flow state (one integration at a time).
  // setupFor names the integration whose setup pane is open; the rest
  // mirror the broker's streamed NDJSON events (see IntegrationsBridge).
  property string setupFor: ""
  property string setupPhase: ""   // "connecting" | "qr" | "prompt" | "done" | "error"
  property string setupPng: ""
  property string setupText: ""
  property string setupErrorText: ""
  // Prompt phase (text-field/secret-field): the label to show above the input
  // and whether it is a secret (masked). Cleared by resetSetup.
  property string setupPromptLabel: ""
  property bool setupPromptSecret: false

  // Bridge setup-stream liveness, mirrored so headless checks can wait for
  // the panel to notice a dropped stream before poking at the prompt.
  readonly property bool setupStreamActive: integrations.setupActive

  // Setup-pane lifecycle phases (setupPhase). "connecting" is entered on
  // launch, then the broker's stream drives qr → done | error.
  readonly property string phaseConnecting: "connecting"
  readonly property string phaseQr: "qr"
  readonly property string phaseDone: "done"
  readonly property string phaseError: "error"
  readonly property string phasePrompt: "prompt"

  // Success pane lingers on its done state this long before auto-closing,
  // so the user registers the "linked" confirmation.
  readonly property int setupDoneCloseMs: 1200

  // Linking QR render size (square), matched to the inline pane width.
  readonly property int setupQrSize: 180

  // Reset the inline setup pane to one consistent state: every view-state
  // var assigned, so no teardown site leaves a stale subset behind.
  function resetSetup(phase, forName) {
    root.setupFor = forName || "";
    root.setupPhase = phase || "";
    root.setupPng = "";
    root.setupText = "";
    root.setupErrorText = "";
    root.setupPromptLabel = "";
    root.setupPromptSecret = false;
  }

  IntegrationsBridge {
    id: integrations
    sockPath: root.integrationsSockPath
    Component.onCompleted: refresh()
  }

  // Relay the bridge's streamed setup events into the inline pane state.
  Connections {
    target: integrations
    function onSetupEvent(ev) {
      if (!ev || !ev.event) return;
      if (ev.event === integrations.evQr) {
        root.setupPng = ev.png || "";
        root.setupPhase = root.phaseQr;
      } else if (ev.event === integrations.evMessage) {
        root.setupText = ev.text || "";
      } else if (ev.event === integrations.evDone) {
        root.setupText = "";
        root.setupPhase = root.phaseDone;
        setupAutoClose.restart();
      } else if (ev.event === integrations.evError) {
        root.setupErrorText = ev.error || "";
        root.setupPhase = root.phaseError;
      } else if (ev.event === integrations.evTextField || ev.event === integrations.evSecretField) {
        // A prompt: show a labelled input (masked for secret-field) and wait
        // for the user to submit a reply via sendSetupReply.
        root.setupPromptLabel = ev.label || "";
        root.setupPromptSecret = ev.event === integrations.evSecretField;
        root.setupText = "";
        root.setupPhase = root.phasePrompt;
      }
    }
  }

  // On success the pane shows its done state briefly, then closes.
  Timer {
    id: setupAutoClose
    interval: root.setupDoneCloseMs
    onTriggered: root.resetSetup()
  }

  // One profile's provisioning form: config fields (plain) + secret fields
  // (masked), each saved through the broker via setField. Reused for every
  // profile of a multi-account integration, for the "add account" draft, and
  // for the implicit "default" profile of a single-account integration.
  component ProfileEditor: ColumnLayout {
    id: pe
    property string intName: ""
    property string profileName: ""
    property var configSchema: []
    property var secretSchema: []
    property var configValues: ({})
    property var secretStatus: ({})
    property bool removable: false
    property bool showName: true
    // Nix-managed account (§10.7): config values render as static rows,
    // secrets as a "set" badge, and edit/remove affordances are NOT
    // instantiated (the broker rejects mutations on a managed profile).
    property bool managed: false
    // This managed account shadows a same-named locally-configured one.
    property bool shadowed: false
    Layout.fillWidth: true
    spacing: Style.marginXS

    RowLayout {
      visible: pe.showName
      Layout.fillWidth: true
      spacing: Style.marginS
      NText {
        text: pe.profileName
        font.bold: true
        color: Color.mOnSurface
        pointSize: Style.fontSizeS
      }
      Item { Layout.fillWidth: true }
      // Remove is a user-only affordance: never instantiated for a managed
      // profile, so the read-only tree carries no interactive children.
      Loader {
        active: pe.removable && !pe.managed
        visible: active
        sourceComponent: NButton {
          objectName: "profileRemove-" + pe.intName + "-" + pe.profileName
          text: I18n.tr("settings.integrations-profile-remove")
          onClicked: integrations.removeProfile(pe.intName, pe.profileName)
        }
      }
    }

    // Managed provenance: lock glyph + "managed by system configuration",
    // plus the shadow subtitle when this replaces a local account. Shown
    // even for the nameless single-account default (showName=false).
    ColumnLayout {
      visible: pe.managed
      Layout.fillWidth: true
      spacing: Style.marginXXS
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginXS
        NIcon {
          icon: "lock"
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }
        NText {
          objectName: "lockBadge-" + pe.intName + "-" + pe.profileName
          Layout.fillWidth: true
          text: I18n.tr("settings.integrations-managed")
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeXS
          wrapMode: Text.Wrap
        }
      }
      NText {
        objectName: "shadowBadge-" + pe.intName + "-" + pe.profileName
        visible: pe.shadowed
        Layout.fillWidth: true
        text: I18n.tr("settings.integrations-shadowed")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeXS
        wrapMode: Text.Wrap
      }
    }

    // Config — managed: static "name / value" rows (never editable).
    Repeater {
      model: pe.managed ? pe.configSchema : []
      delegate: RowLayout {
        id: cfgStaticRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          text: cfgStaticRow.modelData.name
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
        NText {
          objectName: "cfgRow-" + pe.intName + "-" + pe.profileName + "-" + cfgStaticRow.modelData.name
          Layout.fillWidth: true
          text: (pe.configValues && pe.configValues[cfgStaticRow.modelData.name]) || ""
          color: Color.mOnSurface
          pointSize: Style.fontSizeS
          wrapMode: Text.Wrap
        }
      }
    }

    // Config — user-editable: input + Save (unmanaged accounts only).
    Repeater {
      model: pe.managed ? [] : pe.configSchema
      delegate: RowLayout {
        id: cfgRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          text: cfgRow.modelData.name + (cfgRow.modelData.required ? " *" : "")
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
        NTextInput {
          id: cfgInput
          objectName: "cfgInput-" + pe.intName + "-" + pe.profileName + "-" + cfgRow.modelData.name
          Layout.fillWidth: true
          text: (pe.configValues && pe.configValues[cfgRow.modelData.name]) || ""
          placeholderText: cfgRow.modelData.description || cfgRow.modelData.name
        }
        NButton {
          text: I18n.tr("settings.integrations-secret-save")
          enabled: cfgInput.text.length > 0
          onClicked: integrations.setField(pe.intName, pe.profileName, cfgRow.modelData.name, cfgInput.text)
        }
      }
    }

    // Secrets — managed: static "set"/"not set" badge (never the value).
    Repeater {
      model: pe.managed ? pe.secretSchema : []
      delegate: RowLayout {
        id: secStaticRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          objectName: "secretBadge-" + pe.intName + "-" + pe.profileName + "-" + secStaticRow.modelData.name
          text: secStaticRow.modelData.name + " · " + ((pe.secretStatus && pe.secretStatus[secStaticRow.modelData.name])
            ? I18n.tr("settings.integrations-secret-set")
            : I18n.tr("settings.integrations-secret-unset"))
          color: (pe.secretStatus && pe.secretStatus[secStaticRow.modelData.name]) ? Color.mTertiary : Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
      }
    }

    // Secrets — user-editable: masked input + Save (unmanaged accounts only).
    Repeater {
      model: pe.managed ? [] : pe.secretSchema
      delegate: RowLayout {
        id: secRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          text: secRow.modelData.name + " · " + ((pe.secretStatus && pe.secretStatus[secRow.modelData.name])
            ? I18n.tr("settings.integrations-secret-set")
            : I18n.tr("settings.integrations-secret-unset"))
          color: (pe.secretStatus && pe.secretStatus[secRow.modelData.name]) ? Color.mTertiary : Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
        NTextInput {
          id: secInput
          objectName: "secInput-" + pe.intName + "-" + pe.profileName + "-" + secRow.modelData.name
          Layout.fillWidth: true
          echoMode: TextInput.Password
          placeholderText: secRow.modelData.description || secRow.modelData.name
        }
        NButton {
          text: I18n.tr("settings.integrations-secret-save")
          enabled: secInput.text.length > 0
          onClicked: {
            integrations.setField(pe.intName, pe.profileName, secRow.modelData.name, secInput.text);
            secInput.text = "";
          }
        }
      }
    }
  }

  ScrollView {
    id: scroller
    anchors.fill: parent
    anchors.margins: Style.marginL
    contentWidth: availableWidth

    ColumnLayout {
      width: scroller.availableWidth
      spacing: Style.marginM

      NText {
        Layout.fillWidth: true
        text: I18n.tr("settings.nixos-hint")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
      }

      NSpinBox {
        Layout.fillWidth: true
        label: I18n.tr("settings.history-limit-label")
        description: I18n.tr("settings.history-limit-description")
        from: 20
        to: 1000
        stepSize: 20
        value: Settings.data.maxHistory
        onValueModified: v => {
          Settings.data.maxHistory = v;
          Settings.persist();
        }
      }

      NDivider { Layout.fillWidth: true }

      NText {
        Layout.fillWidth: true
        text: I18n.tr("settings.integrations-title")
        pointSize: Style.fontSizeL
        font.bold: true
        color: Color.mOnSurface
      }

      NText {
        Layout.fillWidth: true
        visible: integrations.lastError !== ""
        text: I18n.tr("settings.integrations-error", { error: integrations.lastError })
        wrapMode: Text.Wrap
        color: Color.mError
        pointSize: Style.fontSizeS
      }

      NText {
        Layout.fillWidth: true
        visible: !integrations.loaded
        text: I18n.tr("settings.integrations-offline")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }

      NText {
        Layout.fillWidth: true
        visible: integrations.loaded && integrations.integrations.length === 0
        text: I18n.tr("settings.integrations-empty")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }

      Repeater {
        model: integrations.integrations
        delegate: ColumnLayout {
          id: intRow
          required property var modelData
          // Names of this integration's Nix-managed profiles — the add-account
          // draft refuses to reuse one (the broker rejects it anyway, §10.7).
          readonly property var managedNames: (intRow.modelData.profiles || []).filter(p => p && p.managed === true).map(p => p.name)
          // This integration's setup pane is the open one — manual
          // provisioning surfaces hide while it is.
          readonly property bool setupPaneOpen: root.setupFor === intRow.modelData.name
          // The typed-in add-account name collides with a managed profile.
          readonly property bool draftCollides: intRow.managedNames.indexOf(newProfile.text) >= 0
          // Single-account integrations: the implicit sole profile, if any.
          readonly property var defaultProfile: (intRow.modelData.profiles && intRow.modelData.profiles.length > 0) ? intRow.modelData.profiles[0] : null
          Layout.fillWidth: true
          spacing: Style.marginXS

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS
            NText {
              text: intRow.modelData.name || ""
              font.bold: true
              color: Color.mOnSurface
              pointSize: Style.fontSizeM
            }
            NText {
              visible: intRow.modelData.enabled === true
              text: I18n.tr("settings.integrations-enabled-badge")
              color: Color.mTertiary
              pointSize: Style.fontSizeXS
            }
            Item { Layout.fillWidth: true }
            NButton {
              objectName: "setupBtn-" + (intRow.modelData.name || "")
              // Setup-capable is the only gate: setup on a disabled
              // integration is the provisioning path (proton: the secret a
              // complete profile needs only exists after setup, so gating on
              // enabled would deadlock the bootstrap; the broker starts the
              // helper's daemons on demand).
              visible: intRow.modelData.setup === true
              text: I18n.tr("settings.integrations-setup")
              onClicked: {
                root.resetSetup(root.phaseConnecting, intRow.modelData.name);
                integrations.startSetup(intRow.modelData.name);
              }
            }
            // Nix owns the enable verdict? Replace the toggle with a static
            // label; neither button is instantiated. Absent verdict
            // (enabledByNix === undefined) ⇒ the user keeps control.
            Loader {
              active: intRow.modelData.enabledByNix === undefined
              visible: active
              sourceComponent: NButton {
                objectName: "enableToggle-" + (intRow.modelData.name || "")
                text: intRow.modelData.enabled
                  ? I18n.tr("settings.integrations-disable")
                  : I18n.tr("settings.integrations-enable")
                onClicked: {
                  if (intRow.modelData.enabled) integrations.disable(intRow.modelData.name);
                  else integrations.enable(intRow.modelData.name);
                }
              }
            }
            Loader {
              active: intRow.modelData.enabledByNix !== undefined
              visible: active
              sourceComponent: NText {
                objectName: "enableManagedLabel-" + (intRow.modelData.name || "")
                text: intRow.modelData.enabledByNix === true
                  ? I18n.tr("settings.integrations-enabled-by-nix")
                  : I18n.tr("settings.integrations-disabled-by-nix")
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
              }
            }
          }

          NText {
            Layout.fillWidth: true
            visible: (intRow.modelData.description || "") !== ""
            text: intRow.modelData.description || ""
            wrapMode: Text.Wrap
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeS
          }

          // Inline device-setup flow, rendered only for the integration
          // whose setup was launched (one at a time). qr paints the
          // linking QR, message events show progress, done shows success
          // then auto-closes, error surfaces the failure.
          Loader {
            Layout.fillWidth: true
            active: root.setupFor === intRow.modelData.name
            visible: active
            sourceComponent: ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.marginXS

              NText {
                text: I18n.tr("settings.integrations-setup-title")
                font.bold: true
                color: Color.mOnSurface
                pointSize: Style.fontSizeS
              }

              Image {
                objectName: "setupQr"
                visible: root.setupPhase === root.phaseQr && root.setupPng !== ""
                Layout.alignment: Qt.AlignHCenter
                sourceSize.width: root.setupQrSize
                sourceSize.height: root.setupQrSize
                fillMode: Image.PreserveAspectFit
                source: root.setupPng !== "" ? ("data:image/png;base64," + root.setupPng) : ""
              }

              NText {
                visible: root.setupPhase === root.phaseQr
                Layout.fillWidth: true
                text: I18n.tr("settings.integrations-setup-scan")
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
              }

              // Prompt phase: labelled input (masked for secret-field) + submit.
              // Submitting sends the reply and returns to the streaming state so
              // the helper's next event drives the pane.
              ColumnLayout {
                objectName: "setupPrompt"
                visible: root.setupPhase === root.phasePrompt
                Layout.fillWidth: true
                spacing: Style.marginXS

                NText {
                  Layout.fillWidth: true
                  text: root.setupPromptLabel !== ""
                    ? root.setupPromptLabel
                    : I18n.tr("settings.integrations-setup-prompt")
                  wrapMode: Text.Wrap
                  color: Color.mOnSurface
                  pointSize: Style.fontSizeS
                }
                NTextInput {
                  id: setupPromptInput
                  objectName: "setupPromptInput"
                  Layout.fillWidth: true
                  echoMode: root.setupPromptSecret ? TextInput.Password : TextInput.Normal
                  placeholderText: root.setupPromptLabel
                }
                NButton {
                  objectName: "setupSubmit"
                  text: I18n.tr("settings.integrations-setup-submit")
                  enabled: setupPromptInput.text.length > 0
                  onClicked: {
                    // A dead setup stream (broker dropped without a terminal
                    // event) must not eat the typed reply: only clear the
                    // input and leave the prompt once the reply was sent.
                    if (!integrations.sendSetupReply(setupPromptInput.text)) return;
                    setupPromptInput.text = "";
                    root.setupPhase = root.phaseConnecting;
                  }
                }
              }

              NText {
                objectName: "setupStatus"
                Layout.fillWidth: true
                visible: text !== ""
                wrapMode: Text.Wrap
                pointSize: Style.fontSizeS
                text: {
                  if (root.setupPhase === root.phaseDone) return I18n.tr("settings.integrations-setup-done");
                  if (root.setupPhase === root.phaseError) return I18n.tr("settings.integrations-setup-error", { error: root.setupErrorText });
                  // The connecting phase would otherwise render nothing —
                  // the pane must never look frozen while the helper spawns
                  // (proton takes seconds to start its transient Bridge).
                  if (root.setupText === "" && root.setupPhase === root.phaseConnecting)
                    return I18n.tr("settings.integrations-setup-connecting");
                  return root.setupText;
                }
                color: root.setupPhase === root.phaseError ? Color.mError : Color.mOnSurfaceVariant
              }

              NButton {
                visible: root.setupPhase !== root.phaseDone
                text: I18n.tr("settings.integrations-setup-cancel")
                bgColor: Color.mSurfaceVariant
                fgColor: Color.mOnSurfaceVariant
                onClicked: {
                  integrations.cancelSetup();
                  root.resetSetup();
                }
              }
            }
          }

          // Multi-account: each provisioned profile, plus an "add account" draft.
          // Manual provisioning rows hide while this integration's setup
          // pane is open: setup owns provisioning for the duration (typing
          // into the store editor mid-flow invites conflicting writes and
          // confuses the two surfaces). They return when the pane closes.
          ColumnLayout {
            visible: intRow.modelData.multiProfile === true && !intRow.setupPaneOpen
            Layout.fillWidth: true
            spacing: Style.marginS

            Repeater {
              model: intRow.modelData.profiles || []
              delegate: ProfileEditor {
                id: profRow
                required property var modelData
                Layout.fillWidth: true
                intName: intRow.modelData.name
                profileName: profRow.modelData.name
                configSchema: intRow.modelData.config || []
                secretSchema: intRow.modelData.secrets || []
                configValues: profRow.modelData.config || ({})
                secretStatus: profRow.modelData.secrets || ({})
                removable: true
                showName: true
                managed: profRow.modelData.managed === true
                shadowed: profRow.modelData.shadowed === true
              }
            }

            NTextInput {
              id: newProfile
              objectName: "addProfileInput-" + (intRow.modelData.name || "")
              Layout.fillWidth: true
              placeholderText: I18n.tr("settings.integrations-profile-add")
            }
            // Reusing a Nix-managed profile name is rejected inline (and by
            // the broker): the draft editor is suppressed while it collides.
            NText {
              objectName: "draftError-" + (intRow.modelData.name || "")
              visible: newProfile.text.length > 0 && intRow.draftCollides
              Layout.fillWidth: true
              text: I18n.tr("settings.integrations-profile-managed-conflict")
              color: Color.mError
              pointSize: Style.fontSizeS
              wrapMode: Text.Wrap
            }
            // Draft editor for the typed-in account name; saving any field
            // creates the profile (the broker materialises it on first
            // set-field). Not instantiated while the name collides with a
            // managed profile, so no stray editable rows leak into the tree.
            Loader {
              active: newProfile.text.length > 0 && !intRow.draftCollides
              visible: active
              Layout.fillWidth: true
              sourceComponent: ProfileEditor {
                intName: intRow.modelData.name
                profileName: newProfile.text
                configSchema: intRow.modelData.config || []
                secretSchema: intRow.modelData.secrets || []
                removable: false
                showName: false
              }
            }
          }

          // Single-account: the implicit "default" profile, no profile chrome.
          ProfileEditor {
            objectName: "profileEditor-" + (intRow.modelData.name || "")
            visible: intRow.modelData.multiProfile !== true && !intRow.setupPaneOpen
            Layout.fillWidth: true
            intName: intRow.modelData.name
            profileName: "default"
            configSchema: intRow.modelData.config || []
            secretSchema: intRow.modelData.secrets || []
            configValues: intRow.defaultProfile ? intRow.defaultProfile.config : ({})
            secretStatus: intRow.defaultProfile ? intRow.defaultProfile.secrets : ({})
            removable: false
            showName: false
            managed: intRow.defaultProfile ? (intRow.defaultProfile.managed === true) : false
            shadowed: intRow.defaultProfile ? (intRow.defaultProfile.shadowed === true) : false
          }
        }
      }
    }
  }
}
