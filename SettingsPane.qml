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
  readonly property color background: pane.overlay ? pane.overlay.background : Color.menu.background
  readonly property string fontFamily: pane.overlay ? pane.overlay.fontFamily : Style.font.menuFamily

  property bool editing: false

  // New story beside Solve, then the list beside the bar.
  readonly property var pageColumns: Model.settingsPage(
    Model.showDevSettings(pane.store ? pane.store.linked : false, pane.settings))

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

      // Widths come from this flickable, not from its content item. Binding a
      // column to parent.width there made the content item and the column
      // size each other, and a whole group slipped off the side of the card.
      Flickable {
        id: settingsFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: width
        contentHeight: pageColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: pageColumn
          width: settingsFlick.width
          spacing: Style.spacing.md

          Row {
            id: pageRow
            width: settingsFlick.width
            spacing: Style.spacing.lg

            Repeater {
              model: 2

              SettingsColumn {
                required property int index
                width: (pageRow.width - pageRow.spacing) / 2
                sections: pane.pageColumns[index]
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

          // At the end of the page rather than pinned under it: a fixed line
          // there took the room the last card needed and cut it off.
          Text {
            width: settingsFlick.width
            wrapMode: Text.WordWrap
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
            text: "A dot marks an option that is no longer the default. "
                + "The token is not here: it lives in your keyring, set with bin/shortcut login."
          }
        }

        // More below: the page fades out rather than stopping at a card cut
        // in half, which read as broken rather than as "scroll".
        Rectangle {
          parent: settingsFlick
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(40)
          visible: settingsFlick.contentY < settingsFlick.contentHeight - settingsFlick.height - 1
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(pane.background.r, pane.background.g, pane.background.b, 0) }
            GradientStop { position: 1.0; color: pane.background }
          }
        }
      }
    }
  }
}
