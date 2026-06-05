// Headless host for the NComboBox model-name truncation-tooltip test.
//
// The dropdown surfaces the full model name on hover only when the row's
// label actually elides (a trailing "…"). We can't synthesize a hover or
// realize the windowed Popup headlessly, so we instantiate the real
// delegate Component directly at a controlled width and read back the two
// ingredients the tooltip is built from:
//
//   - delegateLabel.truncated — gates `ToolTip.visible`
//   - delegateItem.fullName   — feeds `ToolTip.text`
//
// Driving the same long label through a narrow vs. wide delegate proves
// the gate flips on overflow and the tip always carries the untruncated
// string. No pi, no LLM, no compositor.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets

Item {
  id: root
  width: 1280
  height: 200

  // Provides the real delegate Component (and its `root.highlightedIndex`
  // lexical binding) we instantiate below. Its own popup is never opened.
  NComboBox {
    id: combo
  }

  // Detached instance of combo's row delegate, recreated per configure().
  property var heldDelegate: null

  IpcHandler {
    target: "test:combo"

    // Recreate the row delegate with `name` at delegate width `w`, then
    // let it lay out (truncation is computed on the next polish pass).
    function configure(name: string, w: string) {
      if (root.heldDelegate) {
        root.heldDelegate.destroy();
        root.heldDelegate = null;
      }
      root.heldDelegate = combo.delegate.createObject(root, {
        width: Number(w),
        modelData: { key: "k0", name: name },
        index: 0,
      });
    }

    // 1 once the delegate's label has been laid out (width settled), so
    // the driver knows `truncated` reflects the real geometry.
    function ready(): string {
      const d = root.heldDelegate;
      return (d && d.contentItem && d.contentItem.width > 0) ? "1" : "0";
    }

    // Report the elision flag and the full (untruncated) label source.
    function probe(): string {
      const d = root.heldDelegate;
      return JSON.stringify({
        truncated: d.contentItem.truncated,
        fullName: d.fullName,
      });
    }
  }
}
