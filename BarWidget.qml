import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A glyph, a count, and a door. The widget owns no panel of its own: the
// overlay is the whole UI, and a compose form with three pickers has no
// business in a popup anchored to a button twenty pixels across. A badge on
// the glyph is the only extra: stories assigned since you last opened them.
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
  property var status: ({ count: 0, started: 0, unseen: 0, locked: false, stale: false, error: "" })

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

  readonly property int unseen: root.needsToken ? 0 : (parseInt(root.status.unseen, 10) || 0)

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

    Item {
      id: iconSlot
      width: button.implicitWidth
      height: button.implicitHeight

      BarIconButton {
        id: button
        bar: root.bar
        slotSize: Style.bar.statusSlot
        tooltipText: ""
        iconComponent: glyph

        onPressed: function(b) { root.press(b) }
      }

      // Sits on the glyph, not beside the count. The count is how many are
      // open. This is how many you have not opened yet. Disabled so a click
      // falls through to the button underneath.
      Rectangle {
        visible: root.unseen > 0
        enabled: false
        anchors.right: button.right
        anchors.top: button.top
        anchors.rightMargin: Style.space(1)
        anchors.topMargin: Style.space(2)
        width: Math.max(height, badgeText.implicitWidth + Style.space(4))
        height: badgeText.implicitHeight
        radius: height / 2
        color: Color.accent

        Text {
          id: badgeText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.unseen > 9 ? "9+" : String(root.unseen)
          color: Color.background
          font.family: root.fontFamily
          font.pixelSize: Math.max(7, Style.font.caption - 2)
          font.bold: true
        }
      }
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
