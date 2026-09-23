import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The stories assigned to you, grouped by what kind of state they are in --
// what you are doing, and what is waiting. A row is a glance: reference, name
// and state. Enter or a click opens the story itself, which is where the
// description and everything else lives.
Item {
  id: pane

  property var overlay: null
  property var store: null

  readonly property var refs: pane.overlay ? pane.overlay.refs : null
  readonly property bool showDone: pane.overlay ? pane.overlay.showDone : false
  readonly property string scope: pane.overlay ? pane.overlay.listScope : "all"
  readonly property string today: pane.overlay && pane.overlay.today
    ? pane.overlay.today : new Date().toISOString().slice(0, 10)
  readonly property string sprintLabel: Model.currentIterationLabel(pane.refs, pane.today)
  readonly property bool loading: pane.store ? pane.store.loadingStories : false
  readonly property int moving: pane.store ? pane.store.movingStory : 0

  readonly property color foreground: pane.overlay ? pane.overlay.foreground : Color.menu.text
  readonly property color muted: pane.overlay ? pane.overlay.muted : Color.muted
  readonly property color accent: pane.overlay ? pane.overlay.accent : Color.accent
  readonly property string fontFamily: pane.overlay ? pane.overlay.fontFamily : Style.font.menuFamily

  // The sections flattened into rows, because a ListView wants one model and
  // the headers have to be walked past by the cursor anyway.
  readonly property var scopedStories: Model.storiesInScope(
    pane.store ? pane.store.stories : [], pane.refs, pane.scope, pane.today)

  readonly property var rows: Model.storyRows(
    Model.sectionStories(pane.scopedStories, pane.refs, pane.showDone))

  // "3 hours ago" has to move on while the panel sits open.
  property real now: Date.now() / 1000
  Timer { interval: 60000; repeat: true; running: pane.visible; onTriggered: pane.now = Date.now() / 1000 }

  property int cursor: 0

  // A refresh, or narrowing to the sprint, can leave the cursor on a header
  // or past the end. Put it back on a story.
  onRowsChanged: {
    if (pane.cursor >= pane.rows.length
        || (pane.rows.length && pane.rows[pane.cursor] && pane.rows[pane.cursor].kind !== "story"))
      pane.cursor = pane.firstStoryRow()
  }

  function setScope(next) {
    if (!pane.store || next === pane.scope) return
    pane.store.persist("listScope", next)
  }

  function toggleScope() {
    if (pane.scope === "current") pane.setScope("all")
    else if (pane.sprintLabel !== "") pane.setScope("current")
  }

  function firstStoryRow() {
    for (var i = 0; i < pane.rows.length; i++) if (pane.rows[i].kind === "story") return i
    return 0
  }

  function moveCursor(step) {
    var at = pane.cursor
    for (var n = 0; n < pane.rows.length; n++) {
      at = (at + step + pane.rows.length) % pane.rows.length
      if (pane.rows[at].kind === "story") { pane.cursor = at; list.positionViewAtIndex(at, ListView.Contain); return }
    }
  }

  function currentStory() {
    var row = pane.rows[pane.cursor]
    return row && row.kind === "story" ? row.story : null
  }

  function takeFocus() {
    if (pane.rows.length && pane.rows[pane.cursor] && pane.rows[pane.cursor].kind !== "story")
      pane.cursor = pane.firstStoryRow()
    keys.forceActiveFocus()
  }

  function escapePressed() { return false }

  // Opening a story used to expand its states in the row. The row had no
  // space for anything you would actually read, so it opens the detail view
  // instead and the states moved in there with it.
  function activate() {
    var story = pane.currentStory()
    if (!story || !pane.store) return
    pane.store.showStory(story.id)
  }

  function openInBrowser() {
    var story = pane.currentStory()
    if (story && story.appUrl) Quickshell.execDetached(["omarchy-launch-browser", story.appUrl])
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      if (ctrl && event.key === Qt.Key_O) { pane.openInBrowser(); event.accepted = true; return }

      if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_I) {
        pane.toggleScope(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Down) { pane.moveCursor(1); event.accepted = true }
      else if (event.key === Qt.Key_Up) { pane.moveCursor(-1); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        pane.activate(); event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.sm

      RowLayout {
        Layout.fillWidth: true
        visible: !!pane.refs
        spacing: Style.spacing.sm

        Button {
          bordered: pane.scope !== "current"
          text: "All"
          tooltipText: "Everything assigned to you (Alt+I)"
          foreground: pane.scope !== "current" ? pane.accent : pane.muted
          fontFamily: pane.fontFamily
          onClicked: pane.setScope("all")
        }

        Button {
          bordered: pane.scope === "current"
          enabled: pane.sprintLabel !== ""
          text: pane.sprintLabel !== "" ? pane.sprintLabel : "No current sprint"
          tooltipText: "Only the sprint today falls inside (Alt+I)"
          foreground: pane.scope === "current" ? pane.accent : pane.muted
          fontFamily: pane.fontFamily
          onClicked: pane.setScope("current")
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !pane.rows.length
        horizontalAlignment: Text.AlignHCenter
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.body
        text: pane.loading ? "Reading your stories..."
          : (!pane.refs ? "Loading your workspace..."
            : (pane.scope === "current"
              ? "Nothing assigned to you in the current sprint."
              : "Nothing is assigned to you."))
      }

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: pane.rows.length > 0
        clip: true
        model: pane.rows
        spacing: Style.spacing.xxs
        boundsBehavior: Flickable.StopAtBounds

        delegate: Loader {
          required property int index
          required property var modelData
          width: ListView.view.width
          sourceComponent: modelData.kind === "header" ? headerRow : storyRow
          property var rowData: modelData
          property int rowIndex: index
        }
      }
    }
  }

  Component {
    id: headerRow
    Item {
      height: header.implicitHeight + Style.spacing.md
      PanelSectionHeader {
        id: header
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        text: parent.parent.rowData.title
      }
    }
  }

  Component {
    id: storyRow
    Item {
      id: row
      readonly property var story: parent.rowData.story
      readonly property bool showState: parent.rowData.showState
      readonly property var agent: pane.store ? Model.solveProgress(pane.store.solveStatus, story.id) : null
      readonly property bool current: parent.rowIndex === pane.cursor
      readonly property bool busy: pane.moving === story.id

      height: body.implicitHeight + Style.spacing.sm * 2

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.current ? Style.selectionFillFor(pane.foreground, pane.accent) : "transparent"
      }

      MouseArea {
        anchors.fill: parent
        onClicked: { pane.cursor = row.parent.rowIndex; pane.activate() }
      }

      ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.spacing.sm
        spacing: Style.spacing.sm

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          // A fixed width, so a wrench and a bulb take the same room and the
          // references line up down the list.
          Text {
            Layout.preferredWidth: Style.space(16)
            horizontalAlignment: Text.AlignHCenter
            text: row.story.glyph
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            text: row.story.ref
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: nameText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: row.story.name
            color: row.busy ? pane.muted : pane.foreground
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          // No padding of its own and the title's height, so a row with a PR
          // is exactly as tall as one without: the list does not step.
          Button {
            visible: row.story.prUrl !== ""
            Layout.preferredHeight: nameText.implicitHeight
            horizontalPadding: Style.space(2)
            verticalPadding: 0
            bordered: false
            text: ""
            tooltipText: "Open the linked pull request"
            foreground: pane.muted
            fontFamily: pane.fontFamily
            onClicked: Quickshell.execDetached(["omarchy-launch-browser", row.story.prUrl])
          }

          // An agent Solve started on it: accent when it wants you back.
          Text {
            visible: !!row.agent
            text: "󰚩"
            color: row.agent && row.agent.attention ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          // Only when it is not the state the heading already names.
          Text {
            visible: row.busy || row.showState
            text: row.busy ? "moving..." : row.story.stateName
            color: row.busy ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          // A fixed column, right-aligned, so the times line up down the list.
          Text {
            Layout.preferredWidth: Style.space(80)
            horizontalAlignment: Text.AlignRight
            text: Model.relativeTime(row.story.updatedAt, pane.now)
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

      }
    }
  }
}
