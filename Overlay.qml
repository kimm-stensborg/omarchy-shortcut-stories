import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
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
  onOpenedChanged: {
    if (root.store) root.store.panelOpen = root.opened
    if (!root.opened) root.helpOpen = false
  }
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
  // Where cancelling a new story goes back to (Model.cameFrom): set when
  // Alt+1 leaves the list, a story or the settings for the form, cleared
  // when the panel is opened straight onto it.
  property var composeFrom: null
  // The ? card over the pane: every key, grouped by where it works.
  property bool helpOpen: false
  // While the card is up the keyboard is the card's: the pane underneath
  // must not move a story because an arrow went through to it. Closing it
  // hands the keys back to the pane.
  onHelpOpenChanged: {
    if (root.helpOpen) keyCatcher.forceActiveFocus()
    else Qt.callLater(function() { root.focusPane() })
  }

  // ---- Theme. Read once, so a theme change moves every colour at once.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Qt.darker(foreground, 1.5)
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  // The same border, faded, for while another window has the keyboard: the
  // panel stays up beside it, and should not look like it is still taking
  // what you type.
  readonly property var idleBorderSpec: Border.surfaceSpec("menu", "border",
    Qt.rgba(borderColor.r, borderColor.g, borderColor.b, 0.35), Math.max(1, Style.space(2)))
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
    // The panel stays up while you work in another window, so the key that
    // summons it (an empty payload) does two things: it brings the keyboard
    // back to a panel that is up but not focused, and closes one that has
    // it. The bar and the screenshot key say what they want in the payload,
    // and always get it.
    if (root.opened && Object.keys(payload).length === 0) {
      if (root.focused) root.dismiss()
      else root.grabKeyboard()
      return
    }
    root.mode = payload.mode === "mine" || payload.mode === "settings"
      ? String(payload.mode)
      : (payload.mode === "compose" ? "compose" : root.defaultMode)
    root.discardArmed = false
    root.composeFrom = null
    if (root.store) root.store.ensureRefs()
    if (root.mode === "settings" && root.store) root.store.refreshWorkspaces()
    var blank = !root.formSeeded || !root.draftDirty()
    if (blank) root.resetForm()
    // A screenshot taken for a story (bin/shortcut shot --open, or Alt+S
    // coming back) lands on the new-story form, added to whatever draft was
    // there rather than replacing it.
    var files = Array.isArray(payload.files) ? payload.files : []
    if (root.mode === "compose" && files.length)
      root.form = Model.withScreenshots(root.form, files, payload.storyType, blank)
    // The bar's click on an agent that wants you names its story, so the
    // panel lands on it rather than on the list you would then search.
    var story = parseInt(payload.story, 10)
    if (root.mode === "mine" && isFinite(story) && story > 0 && root.store) root.store.showStory(story)
    // It opens where you are working. Once up it stays on that screen, so a
    // summon from the bar or a notification does not pull it out from beside
    // the window you are copying from.
    if (!root.opened) root.screenName = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    root.opened = true
    root.grabKeyboard()
    Qt.callLater(function() { root.focusPane() })
  }

  // Whether this panel, rather than some other window, has the keyboard.
  readonly property bool focused: root.opened && card.Window.active

  // The panel takes the keyboard when it opens or is summoned back, but does
  // not keep it: a click in the browser beside it goes to the browser, and
  // a click back in a field comes back here. Hyprland only moves the keyboard
  // to a layer on its own for a click, so a summon asks for it outright --
  // exclusive for a moment, then on demand again.
  property bool grabbing: false
  function grabKeyboard() {
    root.grabbing = true
    releaseGrab.restart()
  }
  Timer { id: releaseGrab; interval: 200; onTriggered: root.grabbing = false }

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

  // Alt+S on the form: the panel gets out of the way, you pick a region, and
  // it comes back with the picture on the draft -- or just comes back, if
  // the picker was cancelled. Reopened through the shell, like the bar
  // does, so the shell's idea of whether the panel is open stays right.
  function captureScreenshot() {
    if (!root.store) return
    root.dismiss()
    shotDelay.restart()
  }

  function reopenWith(payload) {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.pluginId, JSON.stringify(payload)])
  }

  // The picker freezes the screen as it is; the panel has to be gone first
  // or it is in the picture.
  Timer {
    id: shotDelay
    interval: 250
    onTriggered: root.store.takeScreenshot(function(path) {
      root.reopenWith(path ? { mode: "compose", storyType: "bug", files: [path] } : { mode: "compose" })
    })
  }

  function setMode(next) {
    if (next === "compose" && root.mode !== "compose")
      root.composeFrom = Model.cameFrom(root.mode, root.store ? root.store.detailFor : 0)
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
    if (root.helpOpen) { root.helpOpen = false; return }
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
    // The Solve and PR screens are detours off the story: a focused field
    // gives up focus first -- an edited prompt is kept -- then Esc goes back
    // to the story, never past it to the list.
    if (root.storyOpen && root.store && (root.store.solveReview || root.store.prReview)) {
      var review = paneLoader.item
      if (review && typeof review.escapePressed === "function" && review.escapePressed()) return
      if (root.store.solveReview) root.store.closeSolveReview()
      else root.store.closePrReview()
      return
    }
    if (root.storyOpen && root.mode === "mine") { root.store.closeStory(); return }
    var pane = paneLoader.item
    if (root.mode === "compose" && pane && typeof pane.closePopup === "function") {
      var step = Model.composeEscape(false, root.draftDirty(), root.discardArmed)
      if (pane.closePopup()) return
      if (step === "arm") {
        root.discardArmed = true
        discardTimer.restart()
        pane.leaveFields()
        return
      }
      root.cancelDraft()
      return
    }
    if (pane && typeof pane.escapePressed === "function" && pane.escapePressed()) {
      root.discardArmed = false
      return
    }
    root.dismiss()
  }

  // Throws the new-story draft away and goes back to where it was started
  // from: the list, the story that was open, the settings -- or, when the
  // panel opened straight onto the form, closes it.
  function cancelDraft() {
    var from = root.composeFrom
    root.discardArmed = false
    root.composeFrom = null
    root.resetForm()
    if (!from) { root.dismiss(); return }
    root.setMode(from.mode)
    if (from.storyId && root.store) root.store.showStory(from.storyId)
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

  // The screen the panel opened on, by Hyprland's name for it. Empty, or a
  // screen since unplugged, leaves the choice to Quickshell.
  property string screenName: ""
  readonly property var openScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name) === root.screenName) return screens[i]
    return null
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.openScreen
    // No anchors: the layer is the card's size and Hyprland centres it, so
    // the rest of the screen stays clickable -- the browser you are copying
    // a URL out of, say. No scrim, and a click outside does not close it;
    // Esc or the summon key does.
    color: "transparent"
    implicitWidth: panel.cardWidth
    implicitHeight: panel.cardHeight
    WlrLayershell.namespace: "omarchy-shortcut-stories"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.grabbing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Fixed across modes. A card that resizes when you switch panes reads as a
    // different window opening rather than the same one turning over.
    // Wide enough to read a story title without it eliding, and to put a
    // description beside nothing else. The narrow card made the list a column
    // of truncated sentences.
    readonly property int screenWidth: panel.screen ? panel.screen.width : Style.space(1400)
    readonly property int screenHeight: panel.screen ? panel.screen.height : Style.space(900)
    readonly property int cardWidth: Math.min(Style.space(1120), panel.screenWidth - Style.gapsOut * 2)
    readonly property int cardHeight: Math.min(Style.space(780), panel.screenHeight - Style.gapsOut * 2)

    BorderSurface {
      id: card
      anchors.fill: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.focused ? root.borderSpec : root.idleBorderSpec
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

          // The card over everything: ? or F1 closes it again, and nothing
          // else reaches the pane underneath while it is up. "?" only gets
          // here when no text field took it as a character, so typing one
          // in a title still types it; F1 works from inside a field too.
          if (event.key === Qt.Key_F1 || (event.text === "?" && !ctrl && !alt)) {
            root.helpOpen = !root.helpOpen
            event.accepted = true; return
          }
          if (root.helpOpen) { event.accepted = true; return }

          // A text field keeps Ctrl+Z for its own undo; only outside one does
          // it take back the last move.
          if (ctrl && event.key === Qt.Key_Z && root.store && root.store.lastMove) {
            root.store.undoMove()
            event.accepted = true; return
          }

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
                      : (root.storyOpen && root.store && root.store.prReview ? prPane
                        : (root.storyOpen ? detailPane : storiesPane))))))
            onLoaded: {
              Qt.callLater(function() { root.focusPane() })
              paneIn.restart()
            }

            // Each pane settles in rather than snapping: a short fade with
            // a few pixels of drift, quick enough that it never waits on you.
            ParallelAnimation {
              id: paneIn
              NumberAnimation { target: paneLoader.item; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
              NumberAnimation { target: paneLoader.item; property: "y"; from: Style.space(6); to: 0; duration: 180; easing.type: Easing.OutCubic }
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- Footer.
          RowLayout {
            id: footerRow
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

        // Over the pane, not the footer: the footer says how to close it.
        KeysCard {
          anchors.fill: parent
          anchors.bottomMargin: footerRow.height + Style.spacing.md * 2
          visible: root.helpOpen
          foreground: root.foreground
          muted: root.muted
          accent: root.accent
          fontFamily: root.fontFamily
        }
      }
    }
  }

  readonly property bool footerIsError: !!(root.store && root.store.actionError)

  readonly property string footerText: {
    if (root.discardArmed) return "Draft will be lost — Esc again to throw it away"
    // None of the compose or list keys do anything behind the lock, so the
    // footer must not offer them.
    if (root.locked && root.mode !== "settings")
      return "A token unlocks the panel · Ctrl+, for settings · Esc closes"
    if (root.helpOpen) return "? or Esc closes this"
    if (root.store && root.store.actionError) return root.store.actionError
    if (root.store && root.store.notice) return root.store.notice
    if (root.failure && !root.locked) return root.failure.error
    if (root.store && root.store.stale) return "Showing reference data from earlier — Ctrl+R to retry"
    if (root.store && root.store.loadingPr)
      return "Reading the pull request…"
    // From here on, the two or three keys that matter on this pane; the
    // rest are on the ? card, so the line stays readable at a glance. The
    // form's title has the focus, where ? is a character, so there it is F1.
    if (root.store && root.store.editingId)
      return root.store.updating ? "Saving…" : "Enter saves it · Tab moves on · F1 keys · Esc cancels the edit"
    if (root.mode === "compose")
      return "Enter files it · Alt+S a screenshot · F1 keys · "
        + (root.draftDirty() ? "Esc twice cancels" : (root.composeFrom ? "Esc back" : "Esc closes"))
    if (root.store && root.store.solving)
      return "Starting the agent in Herdr…"
    if (root.store && root.store.solveError && root.mode === "mine" && root.storyOpen)
      return root.store.solveError
    if (root.store && root.store.openingPr)
      return "Pushing the branch and opening the pull request…"
    if (root.mode === "mine" && root.storyOpen && root.store && root.store.prReview)
      return "Enter pushes and opens it · D a draft · ? keys · Esc back"
    if (root.mode === "mine" && root.storyOpen && root.store && root.store.solveReview)
      return "Enter starts · ← → workspace · W a worktree · ? keys · Esc back"
    if (root.mode === "mine" && root.storyOpen)
      return "← → Enter moves it · Alt+A solves it" + (root.store.prCanOpen ? " · Alt+P opens a PR" : "")
        + " · ? keys · Esc back"
    if (root.mode === "mine")
      return "Enter opens a story · Alt+I the current sprint · ? keys · Esc closes"
    return "Alt+1 a new story · ? keys · Esc closes"
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

  Component { id: prPane; PrReview {
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
