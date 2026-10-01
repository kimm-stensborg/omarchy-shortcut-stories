import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One row per Herdr workspace: its name, what its up script starts, and a
// Configure button that opens its scripts on a page of their own
// (ServeScriptEditor). Not a Model.SETTINGS row -- the settings system there
// only understands one scalar per key, and this is a map keyed by however
// many workspaces happen to exist, so it is read and written with its own
// small bit of code instead (see Store.qml's persistServeConfig).
Item {
  id: root

  property var workspaces: null      // {id, label, cwd}[], or null while loading
  property var settings: ({})

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal configure(string label)

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

      RowLayout {
        id: wsRow
        required property var modelData
        readonly property var cfg: Model.serveConfigFor(root.settings, modelData.label)
        readonly property bool configured: cfg.up !== "" || cfg.down !== ""
        width: content.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: wsRow.modelData.label
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // The first line of up, so the list says what each workspace starts
        // without opening it.
        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: wsRow.configured ? (wsRow.cfg.up.split("\n")[0] || "down only") : "no scripts"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
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
          bordered: true
          text: "Configure"
          foreground: root.muted
          fontFamily: root.fontFamily
          onClicked: root.configure(wsRow.modelData.label)
        }
      }
    }
  }
}
