import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One story, opened up: what it is called, everything the list had no room
// for, and then the description, the tasks and the comments. That is the
// part you actually need in front of you to do the work, which is why none
// of it is fetched until the story is opened.
//
// Everything reads down one column. The description sits under the facts
// rather than beside them because it is prose: a half-width column of it is
// harder to read than a full-width one, and the facts are short enough that
// putting them side by side wasted the width on both.
//
// Moving the story lives here rather than in the list, so the states you are
// offered always belong to the story you are reading.
Item {
  id: view

  property var overlay: null
  property var store: null

  readonly property var refs: view.overlay ? view.overlay.refs : null
  readonly property var raw: view.store ? view.store.detail : null
  readonly property bool loading: view.store ? view.store.loadingDetail : false
  readonly property string error: view.store ? view.store.detailError : ""
  readonly property bool busy: !!(view.store && view.raw && view.store.movingStory === view.raw.id)

  readonly property var detail: view.raw ? Model.storyDetail(view.raw, view.refs) : null
  readonly property var facts: Model.detailFacts(view.detail)
  readonly property var moveStates: view.detail ? Model.statesForStory(view.refs, view.detail) : []
  property int stateCursor: -1

  // Which state the arrows are sitting on: wherever you have walked to, or
  // the one the story is in when you have not walked anywhere.
  function currentStateIndex() {
    if (view.stateCursor >= 0) return view.stateCursor
    for (var i = 0; i < view.moveStates.length; i++)
      if (view.moveStates[i].id === view.detail.workflowStateId) return i
    return 0
  }

  // A story that has moved puts the arrows back on its new state.
  onDetailChanged: view.stateCursor = -1

  readonly property color foreground: view.overlay ? view.overlay.foreground : Color.menu.text
  readonly property color muted: view.overlay ? view.overlay.muted : Color.muted
  readonly property color accent: view.overlay ? view.overlay.accent : Color.accent
  readonly property color urgent: view.overlay ? view.overlay.urgent : Color.urgent
  readonly property string fontFamily: view.overlay ? view.overlay.fontFamily : Style.font.menuFamily
  readonly property int rowHeightCap: Style.spacing.controlHeight + Style.spacing.controlGap

  signal back()

  function takeFocus() { keys.forceActiveFocus() }

  function escapePressed() { return false }

  function moveTo(stateId) {
    if (!view.store || !view.detail) return
    if (stateId === view.detail.workflowStateId) return
    view.store.moveStory(view.detail.id, stateId)
  }

  function openInBrowser() {
    if (view.detail && view.detail.appUrl)
      Quickshell.execDetached(["omarchy-launch-browser", view.detail.appUrl])
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      if (ctrl && event.key === Qt.Key_O) { view.openInBrowser(); event.accepted = true; return }
      if (!view.moveStates.length) return

      if (event.key === Qt.Key_Left) {
        view.stateCursor = Math.max(0, view.currentStateIndex() - 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Right) {
        view.stateCursor = Math.min(view.moveStates.length - 1, view.currentStateIndex() + 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        var pick = view.moveStates[view.currentStateIndex()]
        if (pick) view.moveTo(pick.id)
        event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.md

      // ---- Title.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.sm

        Button {
          bordered: false
          text: ""
          tooltipText: "Back to the list (Esc)"
          foreground: view.muted
          fontFamily: view.fontFamily
          onClicked: view.back()
        }

        Text {
          visible: !!view.detail
          text: view.detail ? view.detail.glyph + "  " + view.detail.ref : ""
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          text: view.detail ? view.detail.name : (view.loading ? "Reading the story..." : "")
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          visible: !!view.detail
          bordered: true
          text: "Open"
          tooltipText: "Open in your browser (Ctrl+O)"
          foreground: view.accent
          fontFamily: view.fontFamily
          onClicked: view.openInBrowser()
        }
      }

      Text {
        Layout.fillWidth: true
        visible: view.error !== ""
        wrapMode: Text.Wrap
        text: view.error
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { Layout.fillWidth: true; visible: !!view.detail }

      // ---- Everything else, scrolling as one. A plain Flickable rather than
      // a ScrollView: inside a ScrollView the content's parent is the internal
      // Flickable, so binding a width through `parent` there gave the column
      // no width at all and the description never wrapped.
      Flickable {
        id: flick
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !!view.detail
        clip: true
        contentWidth: width
        contentHeight: body.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: body
          width: flick.width
          spacing: Style.spacing.md

          // ---- The facts.
          GridLayout {
            Layout.fillWidth: true
            columns: 2
            rowSpacing: Style.spacing.xs
            columnSpacing: Style.spacing.md

            Repeater {
              model: view.facts
              delegate: Item {
                required property var modelData
                // A Repeater in a GridLayout cannot hand back two items per
                // step, so each row is one item holding its own pair.
                Layout.fillWidth: true
                Layout.columnSpan: 2
                implicitHeight: factRow.implicitHeight

                RowLayout {
                  id: factRow
                  width: parent.width
                  spacing: Style.spacing.md

                  Text {
                    Layout.preferredWidth: Style.space(120)
                    Layout.alignment: Qt.AlignTop
                    text: parent.parent.modelData.label
                    color: view.muted
                    font.family: view.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: parent.parent.modelData.value
                    color: view.foreground
                    font.family: view.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- The description, full width.
          readonly property bool hasDescription: !!(view.detail && view.detail.description !== "")

          Text {
            Layout.fillWidth: true
            // Wrap at a word where it can and mid-word where it cannot: a
            // pasted URL is one long word and would otherwise run off the card.
            wrapMode: Text.Wrap
            // "No description" is not markdown, and rendering it as markdown
            // turned the underscores into an underline rather than italics.
            textFormat: body.hasDescription ? Text.MarkdownText : Text.PlainText
            text: body.hasDescription ? view.detail.description : "No description."
            color: body.hasDescription ? view.foreground : view.muted
            linkColor: view.accent
            lineHeight: 1.35
            lineHeightMode: Text.ProportionalHeight
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            onLinkActivated: function(link) {
              Quickshell.execDetached(["omarchy-launch-browser", link])
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- Tasks. Listed in full, not only counted in the facts above,
          // so a story can be worked without opening it in the browser.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xs

            Text {
              text: "Tasks"
              color: view.muted
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: !view.detail || view.detail.tasks.length === 0
              text: "No tasks."
              color: view.muted
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: view.detail ? view.detail.tasks : []
              delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.spacing.sm

                Text {
                  Layout.alignment: Qt.AlignTop
                  text: modelData.complete ? "" : ""
                  color: modelData.complete ? view.accent : view.muted
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  text: modelData.description
                  color: modelData.complete ? view.muted : view.foreground
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- Comments, oldest first. A reply is indented; the thread is
          // not rebuilt, because position order is already the reading order.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            Text {
              text: "Comments"
              color: view.muted
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: !view.detail || view.detail.comments.length === 0
              text: "No comments."
              color: view.muted
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: view.detail ? view.detail.comments : []
              delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                Layout.leftMargin: modelData.reply ? Style.space(24) : 0
                spacing: Style.spacing.xs

                readonly property string when: Model.relativeTime(modelData.createdAt, Math.round(Date.now() / 1000))

                Text {
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  text: parent.modelData.authorName
                    + (parent.when !== "" ? "  ·  " + parent.when : "")
                    + (parent.modelData.blocker ? "  ·  blocker" : "")
                  color: parent.modelData.blocker ? view.urgent : view.muted
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  Layout.fillWidth: true
                  wrapMode: Text.Wrap
                  textFormat: Text.MarkdownText
                  text: parent.modelData.text
                  color: view.foreground
                  linkColor: view.accent
                  lineHeight: 1.35
                  lineHeightMode: Text.ProportionalHeight
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.body
                  onLinkActivated: function(link) {
                    Quickshell.execDetached(["omarchy-launch-browser", link])
                  }
                }
              }
            }
          }
        }
      }

      PanelSeparator { Layout.fillWidth: true; visible: view.moveStates.length > 0 }

      // ---- Moving it. A workspace can have a dozen states with names like
      // "Review - Definition of Done". As one row they ran straight off the
      // card; as a dropdown the popup hung off the bottom of it, because the
      // kit's dropdown always opens downwards and this sits at the bottom.
      // So they wrap, and past three rows the strip scrolls.
      RowLayout {
        Layout.fillWidth: true
        visible: view.moveStates.length > 0
        spacing: Style.spacing.md

        Text {
          Layout.alignment: Qt.AlignTop
          Layout.topMargin: Style.spacing.xs
          text: view.busy ? "Moving..." : "Move to"
          color: view.busy ? view.accent : view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: stateScroll
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(stateFlow.implicitHeight, view.rowHeightCap * 3)
          clip: true
          contentWidth: width
          contentHeight: stateFlow.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Flow {
            id: stateFlow
            width: stateScroll.width
            spacing: Style.spacing.controlGap

            Repeater {
              model: view.moveStates
              delegate: Button {
                required property var modelData
                required property int index
                readonly property bool here: modelData.id === view.detail.workflowStateId
                readonly property bool picked: index === view.currentStateIndex()
                bordered: picked
                enabled: !view.busy
                text: modelData.name + (here ? " ·" : "")
                foreground: picked ? view.accent : view.muted
                fontFamily: view.fontFamily
                onClicked: view.moveTo(modelData.id)
              }
            }
          }
        }
      }
    }
  }
}
