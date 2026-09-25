import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The service: the only thing in this plugin that runs bin/shortcut, and the
// only thing that runs bin/solve. The token stays in the first; Herdr stays
// in the second.
//
// It has to be a service rather than living in the bar widget, because the bar
// instantiates its widget once per monitor. Polling in there would triple the
// API traffic on a three-screen desk, against a budget of 200 requests a
// minute. One poller here, and every widget copy plus the overlay reads the
// same properties.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.shortcut-stories"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string cli: root.pluginDir + "/bin/shortcut"
  readonly property string solveCli: root.pluginDir + "/bin/solve"

  // Settings live on the bar widget's entry, so the service reads them off the
  // shell config rather than being handed them: it is loaded before any bar
  // widget exists, and it outlives every one of them. One reader here means
  // the overlay and the widget cannot disagree about what a setting says.
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var settings: ({ id: root.pluginId })

  // Nothing may call bin/shortcut until this is true. The settings decide the
  // environment the CLI runs in -- demo mode above all -- so a fetch fired
  // before the file is read runs with the wrong one, fails, and then sits on
  // that failure until the next poll minutes later.
  property bool configLoaded: false

  function takeConfig(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      root.settings = Model.entryFor(parsed.bar, root.pluginId)
    } catch (e) {
      // A half-written or hand-broken shell.json leaves the last good
      // settings in place rather than resetting the panel to defaults.
    }
    root.configLoaded = true
  }

  // Writes go back through the shell, which replaces the entry rather than
  // merging into it -- hence Model.nextEntry carrying every other key across.
  function persist(key, value) {
    // Never write settings that have not been read. root.settings starts as a
    // bare {id}, so a write that slipped out before shell.json was parsed
    // would hand the shell that bare entry and take every stored option with
    // it. Whatever the caller, the file wins until it has been read.
    if (!root.configLoaded) return
    var entry = Model.nextEntry(root.settings, root.pluginId,
                               key === null ? null : ({ [key]: value }))
    root.settings = entry
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.pluginId, entry)
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.takeConfig(text())
    // No shell.json yet is not an error: it means every setting is at its
    // default, and the plugin has to start anyway.
    onLoadFailed: root.configLoaded = true
  }
  readonly property bool demo: Model.readSetting(root.settings, "demo")
  readonly property int refreshMinutes: Model.readSetting(root.settings, "refreshMinutes")
  readonly property var cliEnvironment: {
    var env = {}
    if (root.demo) env.SHORTCUT_DEMO = "1"
    return env
  }

  // ---- What everything else reads.

  property var refs: null           // teams, workflows, members, iterations, you
  property var stories: []          // raw story objects, newest first
  property bool storiesKnown: false // a fetch has succeeded, so [] means none
  property var seenIds: []          // story ids you have opened, still on the list
  property bool seenReady: false
  property bool seenBaseline: false // no seen file yet: the next list is not "new"
  property string seenWritten: ""
  property var failure: null        // the last {code, error}, or null
  property bool loadingRefs: false
  property bool loadingStories: false
  property bool creating: false
  property string actionError: ""
  property int movingStory: 0
  property bool loadingPr: false
  property string prError: ""
  // Enter on a bare PR URL files after the lookup lands, rather than filing
  // the URL string itself as the story name.
  property bool createAfterPr: false
  property string prLookupUrl: ""

  readonly property bool ready: root.refs !== null
  readonly property var me: root.refs ? root.refs.me : null
  readonly property bool stale: !!(root.refs && root.refs.stale)

  signal storyCreated(var story)
  signal prReady(var pr)
  signal storyMoved(int storyId)

  // ---- Reference data.

  function refreshRefs(force) {
    if (refsProc.running || !root.configLoaded) return
    root.loadingRefs = true
    refsProc.command = force ? [root.cli, "refs", "--force"] : [root.cli, "refs"]
    refsProc.running = true
  }

  // Called when the panel opens. The cache on disk lives for hours, but an
  // iteration can roll over inside that, so a quarter of an hour is the most
  // the pickers are allowed to be behind. It never blocks: the panel draws
  // from what it has and the lists repopulate underneath.
  function ensureRefs() {
    if (Model.refsAreStale(root.refs, Date.now() / 1000, 900)) refreshRefs(false)
  }

  function takeRefs(text) {
    root.loadingRefs = false
    var parsed = parse(text)
    if (parsed && parsed.ok) {
      root.refs = parsed
      root.failure = null
      root.tokenPolls = 0
      // The story list is meaningless without the workflows to read it
      // against, so the first refs are what start it.
      if (!storiesProc.running && !root.stories.length) refreshStories()
    } else {
      root.failure = parsed || { code: "error", error: "bin/shortcut gave no answer" }
      // The countdown belongs to the poll timer alone. Decrementing it here
      // too spent two polls per tick and halved the time you have to type the
      // token into the terminal.
    }
  }

  // ---- Stories.

  function refreshStories() {
    if (storiesProc.running || !root.configLoaded) return
    root.loadingStories = true
    storiesProc.running = true
  }

  function takeStories(text) {
    root.loadingStories = false
    var parsed = parse(text)
    if (parsed && parsed.ok) {
      root.storiesKnown = true
      root.stories = parsed.stories || []
      root.failure = null
      root.publishStatus()
    } else if (parsed) {
      // A failed refresh keeps the last list up. A panel that empties itself
      // because the wifi dropped is worse than one showing slightly old rows.
      root.failure = parsed
    }
  }

  // ---- Writing.

  function createStory(form) {
    if (root.creating) return
    var check = Model.validateForm(form)
    if (!check.ok) { root.actionError = check.errors.name; return }
    // A title that is still a PR URL has to be resolved first. Filing the URL
    // as the name would work, but it is not what the person meant.
    var pr = Model.parseGithubPrUrl(form && form.name)
    if (pr && !(form.externalLinks && form.externalLinks.length)) {
      root.createAfterPr = true
      if (!root.loadingPr) root.lookupPr(pr.url)
      return
    }
    // Paste already kicked off a lookup; Enter just asks to file when it lands.
    if (root.loadingPr) {
      root.createAfterPr = true
      return
    }
    root.actionError = ""
    root.creating = true
    root.runWithStdin([root.cli, "create"], root.cliEnvironment,
      JSON.stringify(Model.buildCreateRequest(form, root.refs)), root.takeCreate)
  }

  // Runs Omarchy's region picker through bin/shortcut shot and hands back
  // the path it saved, or "" when the picker was cancelled.
  function takeScreenshot(onDone) {
    root.runWithStdin([root.cli, "shot"], root.cliEnvironment, "{}", function(text) {
      var parsed = root.parse(text)
      if (parsed && parsed.ok !== true) root.actionError = parsed.error || "The screenshot failed"
      onDone(parsed && parsed.ok === true && parsed.path ? String(parsed.path) : "")
    })
  }

  // An image on the clipboard, saved by bin/shortcut paste; "" when there is
  // none. One at a time: Ctrl+V can reach both a field and the form.
  property bool pastingImage: false

  function pasteImage(onDone) {
    if (root.pastingImage) return
    root.pastingImage = true
    root.runWithStdin([root.cli, "paste"], root.cliEnvironment, "{}", function(text) {
      root.pastingImage = false
      var parsed = root.parse(text)
      if (parsed && parsed.ok !== true) root.actionError = parsed.error || "The clipboard image could not be read"
      if (parsed && parsed.ok === true && parsed.path) onDone(String(parsed.path))
    })
  }

  // A fresh Process per call, rather than one reused Process piped each time.
  // Quickshell does not reliably reopen a stdin channel it has already closed
  // once on the same Process instance, so a second reuse can send the child
  // an empty stdin (bin/shortcut then sees no JSON at all). See createStory
  // and launchSolve, the two callers that hand a body over on stdin.
  function runWithStdin(command, environment, body, onDone) {
    var proc = stdinProcess.createObject(root, {
      command: command, environment: environment || ({}), body: body, onDone: onDone
    })
    proc.running = true
  }

  Component {
    id: stdinProcess
    Process {
      property string body: "{}"
      property var onDone: null
      stdinEnabled: true
      onStarted: {
        write(body)
        // Closing stdin in the same tick as onStarted can race the write and
        // truncate it; the write reaches the child once and stdin closes
        // cleanly if the close waits a tick.
        Qt.callLater(function() { stdinEnabled = false })
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var done = onDone
          if (done) done(text)
          destroy()
        }
      }
    }
  }

  function lookupPr(url) {
    var parsed = Model.parseGithubPrUrl(url)
    if (!parsed) {
      root.prError = "That is not a GitHub pull request link"
      return
    }
    if (prProc.running && root.prLookupUrl === parsed.url) return
    root.prError = ""
    root.prLookupUrl = parsed.url
    root.loadingPr = true
    prProc.command = [root.cli, "pr", parsed.url]
    prProc.running = true
  }

  function takePr(text) {
    root.loadingPr = false
    var parsed = parse(text)
    if (parsed && parsed.ok && parsed.pr) {
      root.prError = ""
      root.prReady(parsed.pr)
      // createAfterPr is consumed by the overlay once it has rewritten the form,
      // so the create call sees the PR title rather than the URL.
    } else {
      root.createAfterPr = false
      root.prError = parsed && parsed.error ? parsed.error : "Could not read that pull request"
      root.actionError = root.prError
    }
    root.prLookupUrl = ""
  }

  function takeCreate(text) {
    root.creating = false
    var parsed = parse(text)
    if (parsed && parsed.ok && parsed.story) {
      var filed = Model.prependCreated(root.stories, parsed.story)
      // You wrote it, so it is not news. Remember it before the list changes,
      // or the badge would flash for a story you just filed.
      root.remember(filed, [parsed.story.id])
      root.stories = filed
      root.storyCreated(parsed.story)
      // Shortcut's search index trails a write by seconds, so the list is told
      // what happened rather than asked. The catch-up poll is only to pick up
      // whatever the server filled in that we did not.
      catchUpTimer.restart()
    } else {
      root.actionError = parsed && parsed.error ? parsed.error : "bin/shortcut gave no answer"
    }
  }

  // The story being rewritten, or 0 for none. Set from the detail view's Edit
  // button; the compose form takes over the pane until this clears, either
  // because the save landed or because Esc backed out of it.
  property int editingId: 0
  property bool updating: false

  function beginEdit(storyId) { root.editingId = storyId }
  function cancelEdit() { root.editingId = 0 }

  // seed is the form as the edit opened and base the story as it was then
  // (Model.editBase). Only what differs from seed is sent, and bin/shortcut
  // refuses it if Shortcut has moved on from base in any of those fields.
  function updateStory(storyId, form, seed, base) {
    if (root.updating) return
    var check = Model.validateForm(form)
    if (!check.ok) { root.actionError = check.errors.name; return }
    root.actionError = ""
    root.updating = true
    root.runWithStdin([root.cli, "update", String(storyId)], root.cliEnvironment,
      JSON.stringify(Model.buildUpdatePatch(form, seed, base)), root.takeUpdate)
  }

  // A story Shortcut has just saved, folded into the open one (if it is
  // that one) and into the list.
  function applySaved(story) {
    if (root.detail && root.detail.id === story.id) {
      var next = {}
      for (var k in root.detail) next[k] = root.detail[k]
      for (var k2 in story) next[k2] = story[k2]
      root.detail = next
    }
    root.stories = Model.applyUpdate(root.stories, story)
    // Same reasoning as takeCreate: the search index trails the write.
    catchUpTimer.restart()
  }

  function takeUpdate(text) {
    root.updating = false
    var parsed = parse(text)
    if (parsed && parsed.ok && parsed.story) {
      root.editingId = 0
      root.applySaved(parsed.story)
    } else {
      root.actionError = parsed && parsed.error ? parsed.error : "bin/shortcut gave no answer"
    }
  }

  // undoing is true for the move Ctrl+Z makes, so that one is not itself
  // offered for undoing.
  function moveStory(storyId, stateId, undoing) {
    if (root.movingStory) return
    root.actionError = ""
    root.movingStory = storyId
    // The state it came from: off the list, or off the open story when it
    // is not in the list (one opened from the bar, say).
    var before = storyStateOf(storyId)
    if (before === null && root.detail && root.detail.id === storyId) before = root.detail.workflowStateId
    // Optimistic: the row moves now and is put back if Shortcut disagrees.
    root.pendingMove = { id: storyId, before: before, after: stateId, undoing: !!undoing }
    root.stories = Model.applyMove(root.stories, storyId, stateId)
    moveProc.command = [root.cli, "move", String(storyId), String(stateId)]
    moveProc.running = true
  }

  property var pendingMove: null

  // The last move, for Ctrl+Z, and the line the footer shows about it. Both
  // go after a few seconds: an undo offered minutes later would move a
  // story you have long since stopped thinking about.
  property var lastMove: null
  property string notice: ""

  function undoMove() {
    var move = root.lastMove
    if (!move || root.movingStory) return
    root.lastMove = null
    root.moveStory(move.id, move.from, true)
  }

  Timer {
    id: noticeTimer
    interval: 8000
    onTriggered: { root.notice = ""; root.lastMove = null }
  }

  // ---- One story, opened.

  property var detail: null
  property int detailFor: 0
  property bool loadingDetail: false
  property string detailError: ""

  function showStory(storyId) {
    if (!root.configLoaded) return
    root.detailFor = storyId
    root.detail = null
    root.detailError = ""
    root.solveError = ""
    root.solveReview = false
    root.solvePending = false
    root.prReview = false
    root.openPrError = ""
    root.suggestedState = null
    root.editingId = 0
    root.loadingDetail = true
    root.refreshWorkspaces()
    detailProc.command = [root.cli, "show", String(storyId)]
    detailProc.running = true
  }

  function closeStory() {
    root.detailFor = 0
    root.detail = null
    root.detailError = ""
    root.prReview = false
    root.openPrError = ""
    root.suggestedState = null
    root.solveReview = false
    root.solvePending = false
    root.solveError = ""
    root.editingId = 0
  }

  function takeDetail(text) {
    root.loadingDetail = false
    var parsed = parse(text)
    if (parsed && parsed.ok && parsed.story) {
      // A slow answer for a story you have already navigated away from must
      // not overwrite the one you are looking at now.
      if (parsed.story.id !== root.detailFor) return
      root.detail = parsed.story
      root.remember(root.stories, [parsed.story.id])
      root.publishStatus()
    } else {
      root.detailError = parsed && parsed.error ? parsed.error : "bin/shortcut gave no answer"
    }
  }

  function storyStateOf(storyId) {
    for (var i = 0; i < root.stories.length; i++)
      if (root.stories[i].id === storyId) return root.stories[i].workflowStateId
    return null
  }

  function takeMove(text) {
    var moved = root.movingStory
    root.movingStory = 0
    var parsed = parse(text)
    if (parsed && parsed.ok) {
      root.storyMoved(moved)
      var done = root.pendingMove
      root.pendingMove = null
      root.suggestedState = null
      if (done && done.undoing) {
        root.lastMove = null
        root.notice = Model.movedBackNotice(root.refs, { id: done.id, from: done.before, to: done.after })
      } else if (done && done.before !== null && done.before !== undefined && done.before !== done.after) {
        root.lastMove = { id: done.id, from: done.before, to: done.after }
        root.notice = Model.moveNotice(root.refs, root.lastMove)
      }
      noticeTimer.restart()
      if (root.detail && root.detail.id === moved && parsed.story) {
        var next = {}
        for (var k in root.detail) next[k] = root.detail[k]
        next.workflowStateId = parsed.story.workflowStateId
        root.detail = next
      }
      catchUpTimer.restart()
    } else {
      if (root.pendingMove && root.pendingMove.before !== null)
        root.stories = Model.applyMove(root.stories, root.pendingMove.id, root.pendingMove.before)
      root.pendingMove = null
      root.actionError = parsed && parsed.error ? parsed.error : "bin/shortcut gave no answer"
    }
  }

  // ---- Herdr. A story is handed to an agent in a workspace the user already
  // has. The list is fetched when a story or the settings open, not on the poll.

  property var workspaces: null
  property bool loadingWorkspaces: false
  property bool solving: false
  property string solveError: ""
  property bool solveReview: false
  property bool solvePending: false

  signal solveReadyToClose()

  function refreshWorkspaces() {
    if (spacesProc.running) return
    root.loadingWorkspaces = true
    spacesProc.command = [root.solveCli, "workspaces"]
    spacesProc.running = true
  }

  function takeWorkspaces(text) {
    root.loadingWorkspaces = false
    var parsed = root.parse(text)
    if (!parsed || parsed.ok !== true) {
      root.workspaces = []
      if (root.solvePending) {
        root.solvePending = false
        root.solveReview = false
        root.solveError = parsed && parsed.error ? parsed.error : "Herdr gave no answer"
      }
      return
    }
    root.workspaces = parsed.workspaces || []
    if (root.solvePending) root.continueSolve()
  }

  // Opens the review. Nothing is started until that screen says so.
  function armSolve() {
    if (!root.detail || root.solving) return
    root.solveError = ""
    root.solvePending = true
    // An empty list is retried: the last fetch may have run before Herdr was up.
    if (root.workspaces && root.workspaces.length && !root.loadingWorkspaces) {
      root.continueSolve()
      return
    }
    if (!root.loadingWorkspaces) root.refreshWorkspaces()
  }

  function continueSolve() {
    if (!root.solvePending || !root.detail) return
    root.solvePending = false
    if (!root.workspaces || !root.workspaces.length) {
      root.solveReview = false
      root.solveError = "Herdr has no workspaces yet"
      return
    }
    root.solveReview = true
  }

  function launchSolve(workspace, worktree, prompt) {
    if (!workspace || !root.detail || root.solving) return
    var raw = root.detail
    var text = prompt !== undefined && prompt !== null && String(prompt) !== ""
      ? String(prompt) : Model.solvePrompt(raw, root.refs, !!worktree)
    root.solveError = ""
    root.solving = true
    root.runWithStdin([root.solveCli, "start"], ({}), JSON.stringify({
      workspaceId: String(workspace.id || ""),
      cwd: String(workspace.cwd || ""),
      worktree: !!worktree,
      kind: Model.readSetting(root.settings, "agentKind"),
      agent: Model.solveAgentName(raw.id),
      branch: Model.solveBranch(raw.id),
      prompt: text
    }), root.takeSolve)
  }

  function takeSolve(text) {
    root.solving = false
    var parsed = root.parse(text)
    if (!parsed || parsed.ok !== true) {
      root.solveError = parsed && parsed.error ? parsed.error : "Herdr gave no answer"
      return
    }
    root.solveError = ""
    root.refreshSolveStatus()
    if (parsed.focused === true) {
      root.solveReview = false
      root.solveReadyToClose()
      return
    }
    root.solveError = parsed.status === "blocked"
      ? "Herdr is waiting for an answer"
      : "The agent is in Herdr"
  }

  // Where each Solve agent has got to: Herdr's status and its branch, from
  // bin/solve status. Local only -- Herdr's socket and git -- so it is asked
  // every ten seconds, but only while there are Solve agents to follow or a
  // story is open to show it on; otherwise with the ordinary poll. A failure
  // (no Herdr, Herdr not running) just means no line, not an error: Solve
  // itself says what is wrong when you use it.
  property var solveStatus: null
  readonly property bool hasSolveAgents: !!(root.solveStatus
    && root.solveStatus.agents && root.solveStatus.agents.length)

  // Whether the overlay is on screen. Set by the overlay: a story left open
  // behind a hidden panel is not one you are looking at.
  property bool panelOpen: false

  // Agent name -> the state it was last looked at in (Model.solveAcks). The
  // first answer after the shell starts is the baseline: an agent that was
  // already finished before a restart is not news.
  property var solveAcked: ({})
  property bool solveBaselined: false

  function refreshSolveStatus() {
    if (solveStatusProc.running) return
    solveStatusProc.command = [root.solveCli, "status"]
    solveStatusProc.running = true
  }

  function takeSolveStatus(text) {
    var parsed = root.parse(text)
    root.solveStatus = parsed && parsed.ok === true ? parsed : null
    if (!root.solveStatus) return
    var looked = root.solveBaselined
      ? root.lookingAt()
      : root.solveStatus.agents.map(function(a) { return a.storyId })
    root.solveBaselined = true
    root.solveAcked = Model.solveAcks(root.solveAcked, root.solveStatus, looked)
  }

  // The story in front of you right now, if any.
  function lookingAt() {
    return root.panelOpen && root.detailFor ? [root.detailFor] : []
  }

  function ackOpenStory() {
    if (!root.solveStatus) return
    root.solveAcked = Model.solveAcks(root.solveAcked, root.solveStatus, root.lookingAt())
  }

  // ---- The open story's pull request, from bin/solve pr (gh). Asked when
  // the story opens, again the moment there is somewhere new to look (a link
  // saved on it, or Solve's branch appearing), and every two minutes while
  // it is on screen -- that part goes over the network, so it is not on the
  // ten-second beat. A failed lookup keeps what was shown rather than
  // blanking it: gh being slow is not news about the PR.
  property var prStatus: null
  property string prLookupKey: ""
  property bool loadingPrStatus: false
  // The lookup GitHub has answered for. prStatus is only the truth about
  // the story when this is the lookup in use.
  property string prAnsweredKey: ""
  readonly property bool prKnown: root.prLookupKey !== "" && root.prAnsweredKey === root.prLookupKey

  function refreshPrStatus(force) {
    var lookup = Model.prLookupFor(root.detail, root.solveStatus)
    if (!lookup) { root.prStatus = null; root.prLookupKey = ""; root.prAnsweredKey = ""; return }
    var key = JSON.stringify(lookup)
    if (!force && key === root.prLookupKey) return
    if (root.loadingPrStatus) return
    root.prLookupKey = key
    root.loadingPrStatus = true
    var storyId = root.detail.id
    root.runWithStdin([root.solveCli, "pr"], ({}), key, function(text) {
      root.loadingPrStatus = false
      // An answer for a story you have already left is not this one's.
      if (root.detailFor !== storyId) return
      var parsed = root.parse(text)
      if (parsed && parsed.ok === true) {
        root.prStatus = parsed.pr || null
        root.prAnsweredKey = key
      }
    })
  }

  onDetailChanged: {
    if (!root.detail) { root.prStatus = null; root.prLookupKey = ""; root.prAnsweredKey = ""; return }
    root.refreshPrStatus(false)
  }
  onSolveStatusChanged: if (root.detail) root.refreshPrStatus(false)

  // ---- Opening the pull request. Alt+P shows what would be sent; only
  // Enter on that screen pushes the branch and opens the PR. Then the PR is
  // linked on the story, and the state after it is suggested -- the move
  // strip lands on it, and Enter there is still yours to press.
  property bool prReview: false
  property bool openingPr: false
  property string openPrError: ""
  // {storyId, stateId}: where the move strip should start after a PR.
  property var suggestedState: null

  // Whether the open story has a branch with commits and no PR yet -- the
  // only time the PR button and the footer's Alt+P are offered at all.
  // Not until GitHub has been asked, either: before the first answer, "no
  // PR" only means "not known yet", and a PR opened outside the panel would
  // otherwise get a button that pushes and then fails.
  readonly property bool prCanOpen: Model.prOpenable(root.solveStatus, root.detail, root.prStatus, root.prKnown).ok

  function armPr() {
    var can = Model.prOpenable(root.solveStatus, root.detail, root.prStatus, root.prKnown)
    root.openPrError = can.ok ? "" : can.reason
    root.prReview = can.ok
  }

  function closePrReview() {
    if (root.openingPr) return
    root.prReview = false
    root.openPrError = ""
  }

  function openPr(draft) {
    if (root.openingPr || !root.detail) return
    root.openPrError = ""
    root.openingPr = true
    var story = root.detail
    root.runWithStdin([root.solveCli, "open-pr"], ({}), JSON.stringify(draft), function(text) {
      root.openingPr = false
      var parsed = root.parse(text)
      if (!parsed || parsed.ok !== true) {
        root.openPrError = parsed && parsed.error ? parsed.error : "bin/solve gave no answer"
        return
      }
      root.prReview = false
      // The PR exists on GitHub now, so it is linked on its story whether or
      // not that story is still the one on screen. Only the suggestion of
      // where to move it next needs you to be looking at it.
      root.linkPr(story, parsed.url)
      root.refreshSolveStatus()
      if (root.detailFor !== story.id) return
      var next = Model.stateAfterPr(root.refs, story)
      root.suggestedState = next ? { storyId: story.id, stateId: next.id } : null
      root.refreshPrStatus(true)
    })
  }

  // Only the links go out, checked against what they were: whatever else
  // someone changed on the story meanwhile is not touched.
  // Runs on its own, not through updating: an edit being saved at the same
  // moment must not make the link quietly not happen, and this answer must
  // not end that edit's Saving... either.
  function linkPr(story, url) {
    var links = story.externalLinks || []
    root.runWithStdin([root.cli, "update", String(story.id)], root.cliEnvironment,
      JSON.stringify({ externalLinks: Model.withPrLink(links, url), base: { externalLinks: links } }),
      function(text) {
        var parsed = root.parse(text)
        if (parsed && parsed.ok && parsed.story) { root.applySaved(parsed.story); return }
        root.actionError = "The pull request is open, but it could not be linked on the story: "
          + (parsed && parsed.error ? parsed.error : "bin/shortcut gave no answer")
      })
  }

  onPanelOpenChanged: root.ackOpenStory()
  onDetailForChanged: root.ackOpenStory()
  onSolveAckedChanged: root.publishStatus()

  function closeSolveReview() {
    root.solveReview = false
    root.solvePending = false
    root.solveError = ""
  }

  // ---- What the bar widget reads.
  //
  // A bar widget cannot reach its own plugin's service: the shell injects
  // `shell` into the bar, into services and into panel loaders, but never into
  // a widget, and pluginServiceFor refuses a caller with no id. So the service
  // puts what the bar needs into a small file instead. Every monitor's copy of
  // the widget watches the same one, which is cheaper than each of them
  // polling, and it survives the widget being rebuilt.
  readonly property string statusPath: (Quickshell.env("XDG_CACHE_HOME")
    || Quickshell.env("HOME") + "/.cache") + "/omarchy-shortcut-stories/status.json"

  // Seen ids live beside the status file. The bar cannot ask the service,
  // so the count of stories you have not opened is written out with the rest.
  readonly property string seenPath: (Quickshell.env("XDG_CACHE_HOME")
    || Quickshell.env("HOME") + "/.cache") + "/omarchy-shortcut-stories/seen.json"

  function writeSeen() {
    var text = JSON.stringify({ ids: root.seenIds })
    if (text === root.seenWritten) return
    root.seenWritten = text
    seenFile.setText(text)
  }

  // `readIds` are stories just opened or just filed. A missing seen file
  // baselines instead: the list in front of you is not news.
  function remember(stories, readIds) {
    if (!root.seenReady) return
    var next = root.seenBaseline
      ? Model.seenIdsOf(stories)
      : Model.noteSeen(root.seenIds, stories, readIds || [])
    root.seenBaseline = false
    if (Model.sameIds(next, root.seenIds)) return
    root.seenIds = next
    root.writeSeen()
  }

  // Stories already waiting when the shell starts are not news, the same as
  // Solve's agents: the first list only fills the notified set. After that, a
  // story is told about once, and again only if it leaves and comes back.
  property var notifiedIds: []
  property bool notifyBaselined: false

  function tellNewlyAssigned() {
    var next = Model.newlyAssigned(root.stories, root.seenIds, root.notifiedIds)
    var quiet = !root.notifyBaselined || root.demo || !Model.readSetting(root.settings, "notifyAssigned")
    root.notifyBaselined = true
    if (!Model.sameIds(next.notified, root.notifiedIds)) root.notifiedIds = next.notified
    if (quiet) return
    var notices = Model.assignedNotices(next.notify, root.pluginId)
    // Omarchy's notifications run the notice's argv on a click, and keep it
    // when the toast is restored after a restart.
    for (var i = 0; i < notices.length; i++)
      Quickshell.execDetached(Model.noticeCommand(notices[i]))
  }

  function publishStatus() {
    if (!root.configLoaded) return
    var unseen = 0
    if (root.seenReady && root.storiesKnown) {
      root.remember(root.stories, [])
      unseen = Model.unseenCount(root.stories, root.seenIds)
      root.tellNewlyAssigned()
    }
    // The number beside the icon is the number on My stories, so it follows
    // the same filter the list is using.
    var today = new Date().toISOString().slice(0, 10)
    var scope = Model.readSetting(root.settings, "listScope")
    var visible = Model.storiesInScope(root.stories, root.refs, scope, today)
    var open = Model.openCount(visible, root.refs)
    var started = Model.startedCount(visible, root.refs)
    var locked = !!(root.failure
      && (root.failure.code === "notoken" || root.failure.code === "auth"))
    var text = JSON.stringify({
      count: open, started: started, unseen: unseen, locked: locked,
      stale: root.stale,
      error: root.failure && !locked ? String(root.failure.error) : "",
      solve: Model.solveBarStatus(root.solveStatus, root.solveAcked)
    })
    // Solve status arrives every ten seconds and mostly says nothing new.
    // Rewriting the same bytes would wake every bar widget for nothing.
    if (text === root.publishedStatus) return
    root.publishedStatus = text
    statusFile.setText(text)
  }

  property string publishedStatus: ""

  onStoriesChanged: root.publishStatus()
  onRefsChanged: root.publishStatus()
  onFailureChanged: root.publishStatus()
  onSettingsChanged: root.publishStatus()

  FileView {
    id: statusFile
    path: root.statusPath
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: seenFile
    path: root.seenPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = root.parse(text())
      if (!parsed || !Array.isArray(parsed.ids)) {
        root.seenIds = []
        root.seenBaseline = true
      } else {
        root.seenIds = parsed.ids
        root.seenBaseline = false
        root.seenWritten = JSON.stringify({ ids: parsed.ids })
      }
      root.seenReady = true
      root.publishStatus()
    }
    onLoadFailed: {
      root.seenIds = []
      root.seenBaseline = true
      root.seenReady = true
      root.publishStatus()
    }
  }

  // ---- The token.

  property int tokenPolls: 0

  // bin/shortcut login reads the token without echo, which needs a terminal.
  function setupToken() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "'" + root.cli + "' login"])
    root.tokenPolls = 60
  }

  function parse(text) {
    try { return JSON.parse(String(text || "").trim()) } catch (e) { return null }
  }

  // Linked from a checkout: the plugin's folder is a symlink rather than the
  // clone `omarchy plugin add` makes. That is what working on it looks like,
  // so it is what shows the settings only a developer needs. Asked once; a
  // swap between the two restarts the shell anyway.
  property bool linked: false

  Process {
    running: true
    command: ["sh", "-c", 'test -L "$1" && echo linked', "sh",
              Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.linked = text.trim() === "linked" }
  }

  // ---- Processes. One per verb, so two never share a collector.

  Process {
    id: refsProc
    environment: root.cliEnvironment
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeRefs(text) }
  }

  Process {
    id: storiesProc
    command: [root.cli, "mine"]
    environment: root.cliEnvironment
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeStories(text) }
  }

  // gh speaks to GitHub; this process never sees the Shortcut token. The URL
  // is argv rather than stdin because it is a single short string with no
  // quotes to protect, and the panel never puts a secret there.
  Process {
    id: prProc
    environment: root.cliEnvironment
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takePr(text) }
  }

  Process {
    id: detailProc
    environment: root.cliEnvironment
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeDetail(text) }
  }

  Process {
    id: moveProc
    environment: root.cliEnvironment
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeMove(text) }
  }

  Process {
    id: spacesProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeWorkspaces(text) }
  }

  Process {
    id: solveStatusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeSolveStatus(text) }
  }

  // ---- Timers.

  Timer {
    interval: 120000
    repeat: true
    running: root.panelOpen && root.detailFor !== 0
    onTriggered: root.refreshPrStatus(true)
  }

  Timer {
    interval: 10000
    repeat: true
    running: root.configLoaded && (root.hasSolveAgents || (root.panelOpen && root.detailFor !== 0))
    triggeredOnStart: true
    onTriggered: root.refreshSolveStatus()
  }

  Timer {
    id: poll
    interval: Math.max(1, root.refreshMinutes) * 60000
    repeat: true
    running: root.configLoaded
    triggeredOnStart: false
    onTriggered: {
      root.ensureRefs()
      if (root.refs) root.refreshStories()
      // Picks up agents Solve did not start in this session -- one left
      // running across a shell restart -- without polling Herdr all day.
      root.refreshSolveStatus()
    }
  }

  // Ten seconds is long enough for Shortcut's search index to have caught up
  // with a write of ours.
  Timer {
    id: catchUpTimer
    interval: 10000
    onTriggered: root.refreshStories()
  }

  // While waiting for a token to be typed in the terminal.
  Timer {
    interval: 2000
    repeat: true
    running: root.tokenPolls > 0
    onTriggered: {
      root.tokenPolls--
      root.refreshRefs(true)
    }
  }

  onConfigLoadedChanged: if (root.configLoaded) {
    root.refreshRefs(false)
    root.refreshSolveStatus()
  }

  // Demo mode changes what the CLI is, not just what it says, so the cached
  // answer from before the switch is not an answer to the question now.
  onDemoChanged: {
    if (!root.configLoaded) return
    // Demo stories are not your stories. The next real list is a new baseline,
    // not a pile of badges for things you already had.
    root.storiesKnown = false
    root.seenBaseline = true
    root.notifyBaselined = false
    root.refs = null
    root.stories = []
    root.refreshRefs(true)
  }

  // Lets the overlay and the bar widget reach the one service without each
  // having to own a copy of it.
  IpcHandler {
    target: root.pluginId + ".store"
    function refresh(): void { root.refreshRefs(true); root.refreshStories() }
    function count(): string { return String(root.stories.length) }
  }
}
