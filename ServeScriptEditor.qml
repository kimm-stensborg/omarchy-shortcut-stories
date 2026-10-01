import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One workspace's up and down scripts, on a page of their own: a script is
// several lines more often than not, and a one-line field inside a settings
// card showed a sliver of the first one. Nothing is written until Save -- the
// rest of the settings save as you go, but half a script in shell.json is a
// script that runs half. Model.serveCommand turns the lines into the one
// command Herdr types. Format lays both out (Model.formatScript).
Item {
  id: editor

  property string label: ""
  property string upScript: ""
  property string downScript: ""

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property bool dirty: upBox.area.text !== editor.upScript || downBox.area.text !== editor.downScript
  readonly property bool editing: upBox.area.activeFocus || downBox.area.activeFocus

  // Why Format left a box alone, prefixed with which one.
  property string formatError: ""

  signal saved(string upScript, string downScript)
  signal cancelled()

  function takeFocus() { upBox.area.forceActiveFocus(); upBox.area.cursorPosition = upBox.area.length }

  function save() { editor.saved(upBox.area.text.trim(), downBox.area.text.trim()) }

  // Both boxes, each on its own (Model.formatScript): one it cannot read
  // keeps what you wrote and says why, and the other is still laid out. The
  // new text goes in as an edit rather than a replaced value, so Ctrl+Z
  // takes it back.
  function format() {
    var errors = []
    var boxes = [upBox, downBox]
    for (var i = 0; i < boxes.length; i++) {
      var area = boxes[i].area
      var result = Model.formatScript(area.text)
      if (!result.ok) { errors.push(boxes[i].title + ": " + result.error); continue }
      if (result.script === area.text) continue
      area.remove(0, area.length)
      area.insert(0, result.script)
    }
    editor.formatError = errors.join(" · ")
  }

  // Always a step back: out of a box first when there is something typed in
  // it, so a reflex Esc does not lose a script you were halfway through, and
  // otherwise straight back to the settings.
  function escapePressed() {
    if (editor.editing && editor.dirty) { keys.forceActiveFocus(); return true }
    editor.cancelled()
    return true
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      var alt = (event.modifiers & Qt.AltModifier) !== 0
      if (ctrl && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
        editor.save()
        event.accepted = true
      } else if (alt && event.key === Qt.Key_F) {
        editor.format()
        event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.md

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        Column {
          Layout.fillWidth: true
          spacing: Style.space(2)

          PanelSectionHeader {
            text: "SERVE SCRIPTS"
            foreground: editor.fg
            fontFamily: editor.fontFamily
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: editor.label
            color: editor.fg
            font.family: editor.fontFamily
            font.pixelSize: Style.font.subtitle
          }
        }

        Button {
          bordered: true
          text: "Format"
          tooltipText: "Lay both scripts out, one command to a line (Alt+F)"
          foreground: editor.muted
          fontFamily: editor.fontFamily
          onClicked: editor.format()
        }

        Button {
          bordered: true
          text: "Cancel"
          tooltipText: "Back to the settings, without saving (Esc)"
          foreground: editor.muted
          fontFamily: editor.fontFamily
          onClicked: editor.cancelled()
        }

        Button {
          bordered: true
          text: "Save"
          tooltipText: "Save both scripts (Ctrl+S)"
          foreground: editor.dirty ? editor.accent : editor.muted
          fontFamily: editor.fontFamily
          onClicked: editor.save()
        }
      }

      Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: editor.formatError !== "" ? editor.formatError
          : "A bash script, run in the story's directory: one line runs as it is, several run "
            + "as a script file would. Format lays it out without changing what it does."
        color: editor.formatError !== "" ? Color.urgent : editor.muted
        font.family: editor.fontFamily
        font.pixelSize: Style.font.caption
      }

      ScriptBox {
        id: upBox
        fg: editor.fg
        muted: editor.muted
        accent: editor.accent
        fontFamily: editor.fontFamily
        Layout.fillWidth: true
        Layout.fillHeight: true
        title: "Up script"
        hint: "Starts the dev server in a tab of its own"
        placeholder: "npm ci\nnpm run dev"
        initial: editor.upScript
      }

      ScriptBox {
        id: downBox
        fg: editor.fg
        muted: editor.muted
        accent: editor.accent
        fontFamily: editor.fontFamily
        Layout.fillWidth: true
        Layout.fillHeight: true
        title: "Down script"
        hint: "Tears down what up started, then both tabs close"
        placeholder: "docker compose down"
        initial: editor.downScript
      }
    }
  }

  component ScriptBox: ColumnLayout {
    id: box
    property string title: ""
    property string hint: ""
    property string placeholder: ""
    property string initial: ""
    property alias area: scriptArea
    property color fg: Color.foreground
    property color muted: Qt.darker(Color.foreground, 1.5)
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: box.title
        color: box.fg
        font.family: box.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: box.hint
        color: box.muted
        font.family: box.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    BorderSurface {
      Layout.fillWidth: true
      Layout.fillHeight: true
      radius: Style.cornerRadius
      color: Style.controlFill(scriptArea.activeFocus, false, box.fg, box.accent)
      borderSpec: Border.controlSpec(scriptArea.activeFocus ? "focus" : "normal", box.fg, box.accent)

      QQC.ScrollView {
        anchors.fill: parent
        anchors.margins: Style.space(4)
        clip: true

        QQC.TextArea {
          id: scriptArea
          text: box.initial
          placeholderText: box.placeholder
          wrapMode: TextEdit.Wrap
          color: box.fg
          placeholderTextColor: box.muted
          selectionColor: Style.selectionFillFor(box.fg, box.accent)
          font.family: box.fontFamily
          font.pixelSize: Style.font.body
          background: null
        }
      }
    }
  }
}
