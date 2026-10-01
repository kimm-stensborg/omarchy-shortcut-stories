import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One block, one row per Herdr workspace: a serve command and an optional
// .env path for it. Not a Model.SETTINGS row -- the settings system there
// only understands one scalar per key, and this is a map keyed by however
// many workspaces happen to exist, so it is read and written with its own
// small bit of code instead (see Store.qml's persistServeConfig).
Item {
  id: root

  property var workspaces: null      // {id, label, cwd}[], or null while loading
  property var settings: ({})

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property string fontFamily: Style.font.family

  property var focusedField: null
  readonly property bool editing: focusedField !== null && focusedField.activeFocus

  signal changed(string label, var patch)   // patch is {serveCommand: ...} or {envPath: ...}

  function dropFocus() { root.focusedField = null }

  implicitHeight: content.implicitHeight + Style.space(14) * 2

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(14)
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "WORKSPACES"
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Text {
      visible: !root.workspaces || root.workspaces.length === 0
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.workspaces === null ? "Loading Herdr..." : "Herdr has no workspaces yet"
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.workspaces || []

      Column {
        id: wsRow
        required property var modelData
        readonly property var cfg: Model.serveConfigFor(root.settings, modelData.label)
        width: content.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: wsRow.modelData.label
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        TextField {
          width: parent.width
          text: wsRow.cfg.command
          placeholderText: "Serve command, e.g. npm run dev"
          foreground: root.fg
          font.family: root.fontFamily

          onActiveFocusChanged: {
            if (activeFocus) root.focusedField = this
            else if (root.focusedField === this) root.focusedField = null
          }
          onAccepted: { root.changed(wsRow.modelData.label, { serveCommand: text }); root.dropFocus() }
          onEditingFinished: root.changed(wsRow.modelData.label, { serveCommand: text })
          Keys.onEscapePressed: { text = wsRow.cfg.command; root.dropFocus() }
        }

        TextField {
          width: parent.width
          text: wsRow.cfg.envPath
          placeholderText: ".env path (optional)"
          foreground: root.fg
          font.family: root.fontFamily

          onActiveFocusChanged: {
            if (activeFocus) root.focusedField = this
            else if (root.focusedField === this) root.focusedField = null
          }
          onAccepted: { root.changed(wsRow.modelData.label, { envPath: text }); root.dropFocus() }
          onEditingFinished: root.changed(wsRow.modelData.label, { envPath: text })
          Keys.onEscapePressed: { text = wsRow.cfg.envPath; root.dropFocus() }
        }
      }
    }
  }
}
