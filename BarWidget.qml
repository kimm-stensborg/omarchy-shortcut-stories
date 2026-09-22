import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A glyph, a count, and a door. The widget owns no panel of its own: the
// overlay is the whole UI, and a compose form with three pickers has no
// business in a popup anchored to a button twenty pixels across.
//
// Nothing here polls. The bar instantiates this once per monitor, so a timer
// in here would be one timer per screen; the service does it once instead.
BarWidget {
  id: root
  moduleName: "io.github.kimm-stensborg.shortcut-stories"

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id)
    || "io.github.kimm-stensborg.shortcut-stories"
  // The service cannot be reached from here -- the shell never injects `shell`
  // into a bar widget, and pluginServiceFor refuses a caller with no id -- so
  // the service publishes what the bar needs and this watches the file.
  readonly property string statusPath: (Quickshell.env("XDG_CACHE_HOME")
    || Quickshell.env("HOME") + "/.cache") + "/omarchy-shortcut-stories/status.json"
  property var status: ({ count: 0, started: 0, locked: false, stale: false, top: [], error: "" })

  readonly property bool needsToken: root.status.locked === true

  readonly property string labelMode: Model.readSetting(root.settings, "barLabel")
  readonly property string label: {
    if (root.needsToken || root.labelMode === "none") return ""
    var n = root.labelMode === "started" ? root.status.started : root.status.count
    return n ? String(n) : ""
  }

  FileView {
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.status = JSON.parse(text()) } catch (e) {}
    }
  }

  readonly property color foreground: root.bar ? root.bar.foreground : Color.bar.text
  readonly property string fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family

  // The shell injects `shell` into the bar itself, into services and into
  // panel loaders -- but never into a bar widget, so root.shell is always
  // null here and calling summon on it silently did nothing. The keybinding's
  // own route works from anywhere, so the widget takes that.
  function summon(mode) {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId,
                             JSON.stringify({ mode: mode })])
  }

  readonly property string tooltip: {
    if (root.needsToken) return "Shortcut Stories: click to set up a token"
    if (root.status.error) return "Shortcut: " + root.status.error
    var lines = []
    var count = root.status.count || 0
    lines.push(count === 1 ? "1 story assigned to you" : count + " stories assigned to you")
    var top = root.status.top || []
    for (var i = 0; i < top.length; i++)
      lines.push(top[i].ref + " · " + top[i].stateName + " · " + top[i].name)
    if (root.status.stale) lines.push("(reference data is from earlier)")
    lines.push("Click for your stories · middle click for a new one")
    return lines.join("\n")
  }

  // The panel does the work. A widget that cannot see the service cannot act
  // on it either, so every button summons the panel rather than half of them
  // silently doing nothing.
  function press(button) {
    if (root.needsToken) { root.summon("mine"); return }
    root.summon(button === Qt.MiddleButton ? "compose" : "mine")
  }

  readonly property int labelGap: Style.space(5)
  readonly property real labelMargin: Style.spaceReal(8.5)

  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight

  Row {
    id: content
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      slotSize: Style.bar.statusSlot
      tooltipText: root.tooltip
      iconComponent: glyph

      onPressed: function(b) { root.press(b) }
    }

    // A vertical bar has no room beside the glyph, so the count is dropped
    // rather than squeezed.
    Item {
      visible: root.label !== "" && !root.vertical
      width: visible ? root.labelGap + label.implicitWidth + root.labelMargin : 0
      height: button.implicitHeight

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: root.labelGap
        textFormat: Text.PlainText
        text: root.label
        color: button.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: function(mouse) { root.press(mouse.button) }
      }
    }
  }

  Component {
    id: glyph
    Text {
      // A question mark while there is no token: the widget is a door to
      // setting one up, not a count of nothing.
      text: root.needsToken ? "" : ""
      color: root.status.error && !root.needsToken ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }
  }
}
