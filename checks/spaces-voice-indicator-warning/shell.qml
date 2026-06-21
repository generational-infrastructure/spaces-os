// Headless host for the voice-indicator WARNING visual-mapping test.
//
// Instantiates the plugin's real BarWidget.qml (staged next to this file, so
// `BarWidget {}` resolves locally) against stub noctalia singletons
// (qs.Commons/Color+Style, qs.Services.UI/TooltipService, qs.Widgets/NIcon,
// staged as the `qs` shell root). A stub pluginApi lets the driver set the
// service's voiceState / qualityWarning and the hideWhenIdle setting, then
// read back the derived glyph / stateColor / tooltipKey / shown so the
// colour-and-tooltip contract is asserted in a real QML engine — the part
// agent-vm would otherwise screenshot.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: host

  // Stand-in for the plugin's Main.qml service instance.
  QtObject {
    id: mainStub
    property string voiceState: "idle"
    property string qualityWarning: ""
  }

  // Stand-in for the injected plugin host.
  QtObject {
    id: apiStub
    property var mainInstance: mainStub
    property var pluginSettings: ({
        "hideWhenIdle": false
      })
    function tr(key) {
      return key;
    }
  }

  BarWidget {
    id: widget
    pluginApi: apiStub
  }

  IpcHandler {
    target: "test:bar"

    function setVoice(s: string): void {
      mainStub.voiceState = s;
    }
    function setWarning(w: string): void {
      mainStub.qualityWarning = w;
    }
    function setHideWhenIdle(b: string): void {
      apiStub.pluginSettings = {
        "hideWhenIdle": b === "true"
      };
    }

    function color(): string {
      return widget.stateColor.toString();
    }
    function tooltip(): string {
      return widget.tooltipKey;
    }
    function glyph(): string {
      return widget.glyph;
    }
    function shown(): string {
      return widget.shown ? "1" : "0";
    }
  }
}
