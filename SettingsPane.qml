import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The settings, as a pane of the one card rather than an overlay of their own:
// two PanelWindows both holding exclusive keyboard focus fight each other.
// Every row is rendered from Model.SETTINGS by SettingsColumn, so adding an
// option is a line there and nothing here. There is no Save -- a change is
// written the moment it is made.
Item {
  id: pane

  property var overlay: null
  property var store: null

  readonly property var settings: pane.store ? pane.store.settings : ({})
  readonly property color foreground: pane.overlay ? pane.overlay.foreground : Color.menu.text
  readonly property color muted: pane.overlay ? pane.overlay.muted : Color.muted
  readonly property color accent: pane.overlay ? pane.overlay.accent : Color.accent
  readonly property string fontFamily: pane.overlay ? pane.overlay.fontFamily : Style.font.menuFamily

  // Two columns above this width, one below, so every option is on screen at
  // once rather than behind a scroll.
  readonly property int columnCount: pane.width >= Style.space(620) ? 2 : 1
  readonly property var columns: Model.settingsColumns(pane.columnCount)

  property bool editing: false

  function takeFocus() { keys.forceActiveFocus() }

  // A focused text field owns Escape, and gives it back rather than closing
  // the panel out from under a half-typed team name.
  function escapePressed() {
    if (pane.editing) { keys.forceActiveFocus(); return true }
    return false
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.md

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        Text {
          Layout.fillWidth: true
          color: pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
          text: Model.settingsSummary(pane.settings)
        }

        Button {
          bordered: true
          visible: Model.hasCustomSettings(pane.settings)
          text: "Reset"
          tooltipText: "Put every option back to its default"
          foreground: pane.muted
          fontFamily: pane.fontFamily
          onClicked: { if (pane.store) pane.store.persist(null, null) }
        }
      }

      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentHeight: columnsRow.implicitHeight
        interactive: contentHeight > height

        RowLayout {
          id: columnsRow
          width: parent.width
          spacing: Style.spacing.xl

          Repeater {
            model: pane.columns
            SettingsColumn {
              required property var modelData
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignTop
              width: parent ? parent.width / pane.columnCount : 0
              spacing: Style.spacing.md
              sections: modelData
              values: pane.settings
              refs: pane.overlay ? pane.overlay.refs : null
              workspaces: pane.store ? pane.store.workspaces : null
              today: new Date().toISOString().slice(0, 10)
              fg: pane.foreground
              muted: pane.muted
              accent: pane.accent
              fontFamily: pane.fontFamily
              onChanged: function(key, value) { if (pane.store) pane.store.persist(key, value) }
              onEditingChanged: pane.editing = editing
              onFocusReleased: keys.forceActiveFocus()
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        text: "A dot marks an option that is no longer the default. "
            + "The token is not here: it lives in your keyring, set with bin/shortcut login."
      }
    }
  }
}
