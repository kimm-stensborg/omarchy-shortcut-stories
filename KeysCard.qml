import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Every key the panel answers to, over the pane it was opened from. ? or F1
// opens it, and ? or Esc closes it again. The groups are Model.keyHelp(), the
// same list the footer leaves out to stay short.
Rectangle {
  id: card

  property color foreground: Color.menu.text
  property color muted: Color.muted
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily

  color: Color.menu.background
  opacity: visible ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

  // Eats clicks meant for the pane underneath.
  MouseArea { anchors.fill: parent }

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: groups.implicitHeight
    boundsBehavior: Flickable.StopAtBounds

    // Two columns, each group straight under the one before, alternating
    // sides -- a grid would line the groups up in rows and leave a hole
    // under every short one.
    Row {
      id: groups
      width: flick.width
      spacing: Style.spacing.lg

      Repeater {
        model: 2

        Column {
          id: side
          required property int index
          width: (groups.width - groups.spacing) / 2
          spacing: Style.spacing.lg

          Repeater {
            model: Model.keyHelp().filter(function(g, i) { return i % 2 === side.index })

            ColumnLayout {
              required property var modelData
              width: side.width
              spacing: Style.spacing.xs

              PanelSectionHeader {
                Layout.fillWidth: true
                text: modelData.title
              }

              Repeater {
                model: modelData.keys

                RowLayout {
                  required property var modelData
                  Layout.fillWidth: true
                  spacing: Style.spacing.md

                  Text {
                    Layout.preferredWidth: Style.space(150)
                    text: modelData[0]
                    color: card.accent
                    font.family: card.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: modelData[1]
                    color: card.foreground
                    font.family: card.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
