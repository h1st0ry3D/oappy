import QtQuick
import qs.Commons
import qs.Ui

/*
 * The bar button that opens the Oappy panel.
 *
 * The panel is an overlay rather than a bar popup, so this button does not draw
 * it. It sends the same IPC call the keyboard shortcut sends, which keeps one
 * way to open the panel and lets the panel live on whichever monitor has focus.
 */
BarWidget {
  id: root

  moduleName: "h1st0ry3d.oappy"

  // fa-chart-bar, the glyph the bar font has for a chart. Written as an escape
  // because the character sits in the private use area and does not survive
  // being pasted into a source file.
  readonly property string glyph: "\uf201"
  readonly property string toggleCommand: "omarchy-shell shell toggle h1st0ry3d.oappy"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function openPanel() {
    if (!root.bar) return
    root.bar.run(root.toggleCommand)
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: "Oappy: running apps"
    onPressed: function(pressedButton) {
      // Left click opens or closes the panel. A right click does nothing, so a
      // stray click on the bar cannot quit an app by accident.
      if (pressedButton === 1) root.openPanel()
    }
  }
}
