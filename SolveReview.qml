import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What Solve is about to hand to Herdr, before anything is started. The prompt
// is the one the agent will receive, and it changes with the worktree switch.
Item {
  id: view

  property var overlay: null
  property var store: null

  readonly property var refs: view.overlay ? view.overlay.refs : null
  readonly property var raw: view.store ? view.store.detail : null
  readonly property bool solving: !!(view.store && view.store.solving)
  readonly property string fontFamily: view.overlay ? view.overlay.fontFamily : Style.font.menuFamily
  readonly property color foreground: view.overlay ? view.overlay.foreground : Color.menu.text
  readonly property color muted: view.overlay ? view.overlay.muted : Color.muted
  readonly property color accent: view.overlay ? view.overlay.accent : Color.accent
  readonly property color urgent: view.overlay ? view.overlay.urgent : Color.urgent

  readonly property var agents: {
    var row = Model.settingRow("agentKind")
    return row && row.options ? row.options : []
  }
  readonly property string agentKind: view.store
    ? Model.readSetting(view.store.settings, "agentKind") : "grok"
  readonly property bool worktree: view.store
    ? Model.readSetting(view.store.settings, "solveWorktree") === true : false
  readonly property var workspaces: view.store && view.store.workspaces ? view.store.workspaces : []
  readonly property string prompt: view.raw ? Model.solvePrompt(view.raw, view.refs, view.worktree) : ""

  property int cursor: 0

  function takeFocus() { keys.forceActiveFocus() }

  function escapePressed() {
    if (view.solving || !view.store) return view.solving
    view.store.closeSolveReview()
    return true
  }

  function prepare() {
    var list = view.workspaces
    var saved = Model.workspaceByLabel(list, view.store
      ? Model.readSetting(view.store.settings, "solveWorkspace") : "")
    var hinted = view.raw ? Model.suggestWorkspace(list, Model.solveHaystack(view.raw)) : null
    var want = saved || hinted
    var at = 0
    if (want) {
      for (var i = 0; i < list.length; i++)
        if (list[i].id === want.id) { at = i; break }
    }
    view.cursor = at
  }

  function selectedWorkspace() {
    return view.workspaces[view.cursor] || null
  }

  function toggleWorktree() {
    if (view.store) view.store.persist("solveWorktree", !view.worktree)
  }

  function chooseAgent(kind) {
    if (view.store) view.store.persist("agentKind", kind)
  }

  function start() {
    var workspace = view.selectedWorkspace()
    if (view.store && workspace) view.store.launchSolve(workspace, view.worktree)
  }

  function revealWorkspace(item) {
    if (!item || workspaceScroll.width <= 0) return
    var maxX = Math.max(0, workspaceScroll.contentWidth - workspaceScroll.width)
    var margin = Style.spacing.sm
    var x = workspaceScroll.contentX
    if (item.x - margin < x) x = item.x - margin
    else if (item.x + item.width + margin > x + workspaceScroll.width)
      x = item.x + item.width + margin - workspaceScroll.width
    workspaceScroll.contentX = Math.max(0, Math.min(maxX, x))
  }

  Component.onCompleted: view.prepare()

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (view.solving) { event.accepted = true; return }
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      var alt = (event.modifiers & Qt.AltModifier) !== 0
      if (event.key === Qt.Key_Left) {
        view.cursor = Math.max(0, view.cursor - 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Right) {
        view.cursor = Math.min(Math.max(0, view.workspaces.length - 1), view.cursor + 1)
        event.accepted = true
      } else if (event.key === Qt.Key_W && !ctrl && !alt) {
        view.toggleWorktree()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        view.start()
        event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.md

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.sm

        Button {
          bordered: false
          text: ""
          tooltipText: "Back to the story (Esc)"
          foreground: view.muted
          fontFamily: view.fontFamily
          onClicked: if (view.store && !view.solving) view.store.closeSolveReview()
        }

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: view.raw ? "Solve " + Model.solveBranch(view.raw.id) : "Solve"
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          bordered: true
          enabled: !view.solving && !!view.selectedWorkspace()
          text: view.solving ? "Starting..." : "Start"
          foreground: view.accent
          fontFamily: view.fontFamily
          onClicked: view.start()
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !!(view.store && view.store.solveError !== "")
        wrapMode: Text.Wrap
        text: view.store ? view.store.solveError : ""
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // ---- Agent.
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xs

        Text {
          text: "Agent"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flow {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Repeater {
            model: view.agents

            Button {
              required property var modelData
              bordered: true
              selected: modelData.value === view.agentKind
              text: modelData.label
              fontSize: Style.font.bodySmall
              foreground: modelData.value === view.agentKind ? view.accent : view.foreground
              fontFamily: view.fontFamily
              onClicked: view.chooseAgent(modelData.value)
            }
          }
        }
      }

      // ---- Workspace.
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xs

        Text {
          text: "Workspace"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: Model.solveCaption(view.selectedWorkspace(), view.worktree, view.raw ? view.raw.id : null)
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
        }

        Flickable {
          id: workspaceScroll
          Layout.fillWidth: true
          Layout.preferredHeight: workspaceRow.implicitHeight
          clip: true
          flickableDirection: Flickable.HorizontalFlick
          contentWidth: workspaceRow.implicitWidth
          contentHeight: workspaceRow.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          WheelHandler {
            onWheel: function(wheel) {
              var delta = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y
              var maxX = Math.max(0, workspaceScroll.contentWidth - workspaceScroll.width)
              workspaceScroll.contentX = Math.max(0, Math.min(maxX, workspaceScroll.contentX - delta * 0.6))
              wheel.accepted = true
            }
          }

          Row {
            id: workspaceRow
            spacing: Style.spacing.controlGap

            Repeater {
              model: view.workspaces

              Button {
                id: repoChip
                required property var modelData
                required property int index
                readonly property bool picked: index === view.cursor
                bordered: picked
                text: modelData.label || modelData.id
                foreground: picked ? view.accent : view.muted
                fontFamily: view.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: view.cursor = index
                onPickedChanged: if (picked) Qt.callLater(function() { view.revealWorkspace(repoChip) })
                onXChanged: if (picked) Qt.callLater(function() { view.revealWorkspace(repoChip) })
                Component.onCompleted: if (picked) Qt.callLater(function() { view.revealWorkspace(repoChip) })
              }
            }
          }
        }
      }

      // ---- Worktree.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        Text {
          text: "Worktree"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          bordered: view.worktree
          text: view.worktree ? "On" : "Off"
          fontSize: Style.font.bodySmall
          foreground: view.worktree ? view.accent : view.foreground
          fontFamily: view.fontFamily
          onClicked: view.toggleWorktree()
        }

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: view.worktree
            ? "A new checkout on " + (view.raw ? Model.solveBranch(view.raw.id) : "the story branch")
            : "A new tab in the checkout"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      Text {
        text: "Prompt"
        color: view.muted
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      Flickable {
        id: promptFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: width
        contentHeight: promptText.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Text {
          id: promptText
          width: promptFlick.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: view.prompt
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
