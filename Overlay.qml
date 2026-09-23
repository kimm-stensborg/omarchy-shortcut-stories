import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The summoned panel. One card with three panes -- write a story, the ones
// assigned to you, and the settings -- rather than three overlays, because two
// PanelWindows both asking for exclusive keyboard focus fight each other, and
// because a second keybinding to see what you just filed is a keybinding too
// many.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: (root.manifest && root.manifest.id)
    || "io.github.kimm-stensborg.shortcut-stories"
  readonly property var store: root.service

  property bool opened: false
  property string mode: "compose"          // compose | mine | settings
  property var form: Model.emptyForm()
  // The edit form is a separate draft from the one above: opening an edit
  // must not disturb a new story you were halfway through composing, and
  // backing out of one must not leave the other holding stale field values.
  property var editForm: Model.emptyForm()
  // What the edit form started as, so Save can tell whether there is
  // anything to save. Untouched by change() -- only onEditingIdChanged below
  // ever sets it -- so it stays the original even as editForm is replaced.
  property var editFormSeededWith: null
  // The story itself as it was when the edit opened, for Save to check
  // Shortcut against -- see Model.editBase.
  property var editBase: null
  property bool discardArmed: false

  // ---- Theme. Read once, so a theme change moves every colour at once.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Qt.darker(foreground, 1.5)
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding

  // ---- Settings, read off the one service.
  readonly property var settings: root.store ? root.store.settings : ({})
  readonly property bool stickyFields: Model.readSetting(settings, "stickyFields")
  readonly property string defaultIteration: Model.readSetting(settings, "defaultIteration")
  readonly property string defaultOwner: Model.readSetting(settings, "defaultOwner")
  readonly property bool showDone: Model.readSetting(settings, "showDone")
  readonly property string listScope: Model.readSetting(settings, "listScope")
  readonly property string today: new Date().toISOString().slice(0, 10)
  readonly property string defaultMode: Model.readSetting(settings, "defaultMode")
  readonly property string defaultType: Model.readSetting(settings, "defaultType")
  readonly property string defaultTeam: Model.readSetting(settings, "defaultTeam")

  readonly property var refs: root.store ? root.store.refs : null
  readonly property bool hasRefs: !!root.refs
  readonly property var failure: root.store ? root.store.failure : null
  // A token that is missing and a token that has been revoked block exactly
  // the same things, so they get the same lock screen. Letting a rejected
  // token through to the form means empty pickers, a Create button that
  // cannot work, and one line of explanation in the footer.
  readonly property bool needsToken: !!(root.failure && root.failure.code === "notoken")
  readonly property bool tokenRejected: !!(root.failure && root.failure.code === "auth")
  readonly property bool locked: root.needsToken || root.tokenRejected

  // A story is open over the list rather than beside it: the card is one
  // column and two panes of stories at once would halve both.
  readonly property bool storyOpen: !!(root.store && root.store.detailFor)

  // What a fresh form starts as, given the settings. Each one is resolved
  // against the workspace rather than trusted: a team that has been archived,
  // a sprint that has finished, or a colleague who has left all read as unset
  // instead of being sent to Shortcut.
  function formDefaults() {
    var today = new Date().toISOString().slice(0, 10)
    var teamId = Model.resolveTeamSetting(root.refs, root.defaultTeam)
    return {
      storyType: root.defaultType,
      groupId: teamId,
      iterationId: Model.resolveIterationSetting(root.refs, root.defaultIteration, teamId, today),
      ownerId: Model.resolveOwnerSetting(root.refs, root.defaultOwner)
    }
  }

  // A form that has never been filled in is not a draft, however far it sits
  // from its defaults. Without this the very first open reads "ownerIds is
  // empty but should be you" as a story someone started writing, and the
  // defaults never get applied at all.
  property bool formSeeded: false

  // The defaults the form was actually filled from. A draft has to be judged
  // against those and not against what the defaults say now: change the
  // default team in settings and an untouched form would otherwise differ
  // from the new defaults, read as a draft someone started, and never pick
  // the new team up at all.
  property var formSeededWith: null

  function resetForm() {
    var defaults = root.formDefaults()
    root.formSeededWith = defaults
    root.form = Model.emptyForm(defaults)
    root.formSeeded = true
  }

  function draftDirty() {
    return Model.draftIsDirty(root.form, root.formSeededWith || root.formDefaults())
  }

  // Reference data decides what the defaults are, and it arrives after the
  // shell starts. Seed the form the moment it lands, unless something has
  // been typed in the meantime.
  onHasRefsChanged: {
    if (root.hasRefs && (!root.formSeeded || !root.draftDirty())) root.resetForm()
  }

  // Changing a default in settings should show up in the next story you write.
  onSettingsChanged: if (root.formSeeded && !root.draftDirty()) root.resetForm()

  // ---- The host contract: opened, open(payloadJson), close().

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) || {} } catch (e) {}
    root.mode = payload.mode === "mine" || payload.mode === "settings"
      ? String(payload.mode)
      : (payload.mode === "compose" ? "compose" : root.defaultMode)
    root.discardArmed = false
    if (root.store) root.store.ensureRefs()
    if (root.mode === "settings" && root.store) root.store.refreshWorkspaces()
    if (!root.formSeeded || !root.draftDirty()) root.resetForm()
    root.opened = true
    Qt.callLater(function() { root.focusPane() })
  }

  function close() {
    root.opened = false
    root.discardArmed = false
  }

  // Closing ourselves without telling the shell leaves its open-state stale,
  // and the next press of the keybinding then does nothing at all.
  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() { root.opened ? root.dismiss() : root.open("{}") }

  function setMode(next) {
    if (root.store && root.storyOpen) root.store.closeStory()
    root.mode = next
    root.discardArmed = false
    if (next === "settings" && root.store) root.store.refreshWorkspaces()
    Qt.callLater(function() { root.focusPane() })
  }

  function focusPane() {
    var pane = paneLoader.item
    if (pane && typeof pane.takeFocus === "function") pane.takeFocus()
    else keyCatcher.forceActiveFocus()
  }

  // Esc is tiered: a dropdown eats it first, then a focused field gives up its
  // focus without losing what is typed in it, and only then does the panel
  // close. A draft with anything in it costs a second Esc, because a reflex
  // keystroke should not throw away a story you were halfway through writing.
  function escapePressed() {
    // Editing is a detour off the detail view, not a mode of its own, so it
    // gets first refusal on Esc -- a dropdown or a focused field still eats it
    // first, same as compose -- and backs out to the story rather than
    // closing the panel.
    if (root.store && root.store.editingId) {
      var editPane = paneLoader.item
      if (editPane && typeof editPane.escapePressed === "function" && editPane.escapePressed()) return
      root.store.cancelEdit()
      return
    }
    if (root.storyOpen && root.mode === "mine") { root.store.closeStory(); return }
    var pane = paneLoader.item
    if (pane && typeof pane.escapePressed === "function" && pane.escapePressed()) {
      root.discardArmed = false
      return
    }
    if (root.mode === "compose" && root.draftDirty()) {
      if (!root.discardArmed) { root.discardArmed = true; discardTimer.restart(); return }
      root.resetForm()
    }
    root.dismiss()
  }

  Timer { id: discardTimer; interval: 3000; onTriggered: root.discardArmed = false }

  Connections {
    target: root.store
    function onStoryCreated(story) {
      root.form = Model.clearForm(root.form, root.formDefaults(), root.stickyFields)
      Quickshell.execDetached([
        root.omarchyPath + "/bin/omarchy-notification-send",
        "--app-name", "Shortcut", "-g", "",
        "sc-" + story.id + " created", String(story.name),
        "--exec", "omarchy-launch-browser", String(story.appUrl)
      ])
    }
    function onPrReady(pr) {
      root.form = Model.applyPrToForm(root.form, pr, root.formSeededWith || root.formDefaults())
      // Enter (or Create) while the title was still a URL asked us to file once
      // the lookup landed. Do that now that the form holds the PR's title.
      if (root.store && root.store.createAfterPr) {
        root.store.createAfterPr = false
        root.store.createStory(root.form)
      }
    }
    // The edit form is filled the moment an edit starts, from whatever detail
    // is already open (Edit only ever comes from the open story's own pane).
    // Clearing it back to empty when the edit ends, rather than leaving the
    // last story's text sitting there, keeps a stray read of it harmless.
    function onEditingIdChanged() {
      var seeded = root.store.editingId ? Model.formFromDetail(root.store.detail) : Model.emptyForm()
      root.editForm = seeded
      root.editFormSeededWith = root.store.editingId ? seeded : null
      root.editBase = root.store.editingId ? Model.editBase(root.store.detail) : null
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-shortcut-stories"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    // Fixed across modes. A card that resizes when you switch panes reads as a
    // different window opening rather than the same one turning over.
    // Wide enough to read a story title without it eliding, and to put a
    // description beside nothing else. The narrow card made the list a column
    // of truncated sentences.
    readonly property int cardWidth: Math.min(Style.space(1120), panel.width - Style.gapsOut * 2)
    readonly property int cardHeight: Math.min(Style.space(780), panel.height - Style.gapsOut * 2)

    BorderSurface {
      id: card
      width: panel.cardWidth
      height: panel.cardHeight
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: root.contentMargin
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.escapePressed(); event.accepted = true; return }

          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var alt = (event.modifiers & Qt.AltModifier) !== 0

          if (ctrl && event.key === Qt.Key_R) {
            if (root.store) { root.store.refreshRefs(true); root.store.refreshStories() }
            event.accepted = true; return
          }
          if (ctrl && event.key === Qt.Key_Comma) { root.setMode("settings"); event.accepted = true; return }
          if (alt && event.key === Qt.Key_1) { root.setMode("compose"); event.accepted = true; return }
          if (alt && event.key === Qt.Key_2) { root.setMode("mine"); event.accepted = true; return }
          if (ctrl && event.key === Qt.Key_Tab) {
            root.setMode(root.mode === "compose" ? "mine" : "compose")
            event.accepted = true; return
          }
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.spacing.md

          // ---- Header.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            Text {
              text: "Shortcut"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Item { Layout.fillWidth: true }

            Repeater {
              model: [
                { id: "compose", label: "New story" },
                { id: "mine", label: "My stories" }
              ]
              Button {
                required property var modelData
                bordered: root.mode === modelData.id
                text: {
                  if (modelData.id !== "mine" || !root.store) return modelData.label
                  var list = Model.storiesInScope(root.store.stories, root.refs, root.listScope, root.today)
                  var n = Model.openCount(list, root.refs)
                  return n ? modelData.label + " · " + n : modelData.label
                }
                foreground: root.mode === modelData.id ? root.accent : root.muted
                fontFamily: root.fontFamily
                onClicked: root.setMode(modelData.id)
              }
            }

            Button {
              bordered: root.mode === "settings"
              text: ""
              tooltipText: "Settings (Ctrl+,)"
              foreground: root.mode === "settings" ? root.accent : root.muted
              fontFamily: root.fontFamily
              onClicked: root.setMode("settings")
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- Body.
          Loader {
            id: paneLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Settings stays reachable without a token. Writing a story or
            // listing them cannot work without one, but the settings are
            // where demo mode lives, and locking that behind the token it is
            // meant to do without would be a circle.
            sourceComponent: root.mode === "settings" ? settingsPane
              : (root.locked ? tokenPane
                : (root.store && root.store.editingId ? composePane
                  : (root.mode === "compose" ? composePane
                    : (root.storyOpen && root.store && root.store.solveReview ? solvePane
                      : (root.storyOpen ? detailPane : storiesPane)))))
            onLoaded: Qt.callLater(function() { root.focusPane() })
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- Footer.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              color: root.discardArmed || root.footerIsError ? root.urgent : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: root.footerText
            }
          }
        }
      }
    }
  }

  readonly property bool footerIsError: !!(root.store && root.store.actionError)

  readonly property string footerText: {
    if (root.discardArmed) return "Draft will be lost — Esc again to discard"
    // None of the compose or list keys do anything behind the lock, so the
    // footer must not offer them.
    if (root.locked && root.mode !== "settings")
      return "A token unlocks the panel · Ctrl+, for settings · Esc closes"
    if (root.store && root.store.actionError) return root.store.actionError
    if (root.failure && !root.locked) return root.failure.error
    if (root.store && root.store.stale) return "Showing reference data from earlier — Ctrl+R to retry"
    if (root.store && root.store.loadingPr)
      return "Reading the pull request…"
    if (root.store && root.store.editingId)
      return root.store.updating ? "Saving…" : "Enter saves it · Tab moves on · Esc cancels the edit"
    if (root.mode === "compose")
      return "Enter files it · a GitHub PR link fills it in · Tab moves on · Alt+2 your stories · Esc closes"
    if (root.store && root.store.solving)
      return "Starting the agent in Herdr…"
    if (root.store && root.store.solveError && root.mode === "mine" && root.storyOpen)
      return root.store.solveError
    if (root.mode === "mine" && root.storyOpen && root.store && root.store.solveReview)
      return "Enter starts · Ctrl+Enter from the prompt · ← → workspace · W a worktree · Esc back"
    if (root.mode === "mine" && root.storyOpen)
      return "Alt+A solves it · ← → pick a state · Enter moves it · Ctrl+E edits it · Esc back"
    if (root.mode === "mine")
      return "Enter opens a story · Alt+I the current sprint · Ctrl+O in your browser · Esc closes"
    return "Ctrl+R refreshes · Alt+1 a new story · Esc closes"
  }

  Component { id: composePane; ComposePane {
    overlay: root
    store: root.store
  } }

  Component { id: storiesPane; StoriesPane {
    overlay: root
    store: root.store
  } }

  Connections {
    target: root.store
    function onSolveReadyToClose() { root.dismiss() }
  }

  Component { id: solvePane; SolveReview {
    overlay: root
    store: root.store
  } }

  Component { id: detailPane; StoryDetail {
    overlay: root
    store: root.store
    onBack: if (root.store) root.store.closeStory()
  } }

  Component { id: settingsPane; SettingsPane {
    overlay: root
    store: root.store
  } }

  // A token that is not there is the whole panel's problem, not one pane's.
  Component {
    id: tokenPane
    Item {
      id: tokenGate
      anchors.fill: parent
      focus: true

      function takeFocus() { tokenGate.forceActiveFocus() }
      function escapePressed() { return false }

      // qs.Ui's Button is mouse-only -- it carries a clicked() signal and no
      // key handling at all. On a panel that holds exclusive keyboard focus
      // that would make the one button you need unreachable, so Enter and
      // Space are wired up here.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          if (root.store) root.store.setupToken()
          root.dismiss()
          event.accepted = true
        }
      }

      ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width, Style.space(420))
        spacing: Style.spacing.lg

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          text: root.tokenRejected ? "Shortcut rejected your token"
                                   : "Shortcut Stories needs an API token"
        }

        Text {
          Layout.fillWidth: true
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: (root.tokenRejected
                  ? "It may have been revoked, or belong to another workspace. Set up a new one. "
                  : "It opens a terminal, because the token is read without echoing it. ")
              + "Create one under Settings → API Tokens in Shortcut."
        }

        Button {
          id: setupButton
          Layout.alignment: Qt.AlignHCenter
          bordered: true
          text: root.tokenRejected ? "Enter a new token" : "Set up token"
          foreground: root.accent
          fontFamily: root.fontFamily
          onClicked: { if (root.store) root.store.setupToken(); root.dismiss() }
        }
      }
    }
  }

  IpcHandler {
    target: root.pluginId + ".panel"
    function open(payloadJson: string): void { root.open(payloadJson) }
    function close(): void { root.dismiss() }
    function toggle(): void { root.toggle() }
  }
}
