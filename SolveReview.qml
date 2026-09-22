import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
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
  // The generated prompt, until it is edited. After that the field is what
  // gets sent, and toggling the worktree no longer rewrites it.
  property bool promptEdited: false
  property bool syncingPrompt: false
  property string promptDraft: ""

  property int cursor: 0

  function generatedPrompt() {
    return view.raw ? Model.solvePrompt(view.raw, view.refs, view.worktree) : ""
  }

  function adoptPrompt() {
    if (view.promptEdited) return
    var next = view.generatedPrompt()
    view.syncingPrompt = true
    view.promptDraft = next
    if (promptArea) promptArea.text = next
    view.syncingPrompt = false
  }

  function takeFocus() { keys.forceActiveFocus() }

  function escapePressed() {
    if (view.solving) return true
    if (promptArea.activeFocus) { keys.forceActiveFocus(); return true }
    if (view.store) view.store.closeSolveReview()
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
    view.adoptPrompt()
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
    var text = view.promptDraft.replace(/\s+$/, "")
    if (view.store && workspace && text !== "") view.store.launchSolve(workspace, view.worktree, text)
  }

  onWorktreeChanged: view.adoptPrompt()
  onRawChanged: view.adoptPrompt()

  function revealWorkspace(item) {
    if (!item || workspaceScroll.width <= 0) return
    var maxX = Math.max(0, workspaceScroll.contentWidth - workspaceScroll.width)
    var margin = Style.spacing.sm
    var left = workspaceRow.x + item.x
    var x = workspaceScroll.contentX
    if (left - margin < x) x = left - margin
    else if (left + item.width + margin > x + workspaceScroll.width)
      x = left + item.width + margin - workspaceScroll.width
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
      if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
        view.start()
        event.accepted = true
        return
      }
      // Inside the prompt, the keys are text. Enter is a new line there.
      if (promptArea.activeFocus) return
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
          enabled: !view.solving && !!view.selectedWorkspace() && view.promptDraft.replace(/\s+$/, "") !== ""
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
          // The chip border is painted on the edge of the button. A flickable
          // clipped to that exact height cuts the top stroke off.
          Layout.preferredHeight: workspaceRow.implicitHeight + 8
          clip: true
          flickableDirection: Flickable.HorizontalFlick
          contentWidth: workspaceRow.implicitWidth + 8
          contentHeight: workspaceRow.implicitHeight + 8
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
            x: 4
            y: 4
            spacing: Style.spacing.controlGap

            Repeater {
              model: view.workspaces

              Button {
                id: repoChip
                required property var modelData
                required property int index
                readonly property bool picked: index === view.cursor
                bordered: true
                text: modelData.label || modelData.id
                foreground: picked ? view.accent : view.muted
                fontFamily: view.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
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

      QQC.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        QQC.TextArea {
          id: promptArea
          placeholderText: "What the agent is asked to do"
          wrapMode: TextEdit.Wrap
          color: view.foreground
          placeholderTextColor: view.muted
          selectionColor: Style.selectionFillFor(view.foreground, view.accent)
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          background: null
          onTextChanged: {
            if (view.syncingPrompt) return
            view.promptEdited = true
            view.promptDraft = text
          }
        }
      }
    }
  }
}
