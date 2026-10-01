import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One row per Herdr workspace: its name, and a Configure button that reveals
// its up and down scripts. Not a Model.SETTINGS row -- the settings system
// there only understands one scalar per key, and this is a map keyed by
// however many workspaces happen to exist, so it is read and written with
// its own small bit of code instead (see Store.qml's persistServeConfig).
Item {
  id: root

  property var workspaces: null      // {id, label, cwd}[], or null while loading
  property var settings: ({})

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  property var focusedField: null
  readonly property bool editing: focusedField !== null && focusedField.activeFocus

  signal changed(string label, var patch)   // patch is {upScript: ...} or {downScript: ...}

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
        // Collapsed by default even for a workspace that already has scripts
        // set -- a page that unfolds every row the moment it is opened reads
        // as a wall of fields, not a list.
        property bool expanded: false
        readonly property var cfg: Model.serveConfigFor(root.settings, modelData.label)
        readonly property bool configured: cfg.up !== "" || cfg.down !== ""
        width: content.width
        spacing: Style.space(8)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: wsRow.modelData.label
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            visible: wsRow.configured
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Style.space(6)
            Layout.preferredHeight: Style.space(6)
            radius: width / 2
            color: root.accent
          }

          Button {
            bordered: wsRow.expanded
            text: wsRow.expanded ? "Close" : "Configure"
            foreground: wsRow.expanded ? root.accent : root.muted
            fontFamily: root.fontFamily
            onClicked: wsRow.expanded = !wsRow.expanded
          }
        }

        Column {
          visible: wsRow.expanded
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Up script"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            width: parent.width
            text: wsRow.cfg.up
            placeholderText: "e.g. docker compose up -d"
            foreground: root.fg
            font.family: root.fontFamily

            onActiveFocusChanged: {
              if (activeFocus) root.focusedField = this
              else if (root.focusedField === this) root.focusedField = null
            }
            onAccepted: { root.changed(wsRow.modelData.label, { upScript: text }); root.dropFocus() }
            onEditingFinished: root.changed(wsRow.modelData.label, { upScript: text })
            Keys.onEscapePressed: { text = wsRow.cfg.up; root.dropFocus() }
          }

          Text {
            text: "Down script"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            width: parent.width
            text: wsRow.cfg.down
            placeholderText: "e.g. docker compose down"
            foreground: root.fg
            font.family: root.fontFamily

            onActiveFocusChanged: {
              if (activeFocus) root.focusedField = this
              else if (root.focusedField === this) root.focusedField = null
            }
            onAccepted: { root.changed(wsRow.modelData.label, { downScript: text }); root.dropFocus() }
            onEditingFinished: root.changed(wsRow.modelData.label, { downScript: text })
            Keys.onEscapePressed: { text = wsRow.cfg.down; root.dropFocus() }
          }
        }
      }
    }
  }
}
