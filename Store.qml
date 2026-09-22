import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The service: the only thing in this plugin that runs bin/shortcut.
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

  readonly property bool ready: root.refs !== null
  readonly property var me: root.refs ? root.refs.me : null
  readonly property bool stale: !!(root.refs && root.refs.stale)

  signal storyCreated(var story)
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
    root.actionError = ""
    root.creating = true
    createProc.body = JSON.stringify(Model.buildCreateRequest(form, root.refs))
    createProc.running = true
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

  function moveStory(storyId, stateId) {
    if (root.movingStory) return
    root.actionError = ""
    root.movingStory = storyId
    // Optimistic: the row moves now and is put back if Shortcut disagrees.
    root.pendingMove = { id: storyId, before: storyStateOf(storyId) }
    root.stories = Model.applyMove(root.stories, storyId, stateId)
    moveProc.command = [root.cli, "move", String(storyId), String(stateId)]
    moveProc.running = true
  }

  property var pendingMove: null

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
    root.loadingDetail = true
    detailProc.command = [root.cli, "show", String(storyId)]
    detailProc.running = true
  }

  function closeStory() {
    root.detailFor = 0
    root.detail = null
    root.detailError = ""
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
      root.pendingMove = null
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

  function publishStatus() {
    if (!root.configLoaded) return
    var unseen = 0
    if (root.seenReady && root.storiesKnown) {
      root.remember(root.stories, [])
      unseen = Model.unseenCount(root.stories, root.seenIds)
    }
    var open = Model.openCount(root.stories, root.refs)
    var started = Model.startedCount(root.stories, root.refs)
    var locked = !!(root.failure
      && (root.failure.code === "notoken" || root.failure.code === "auth"))
    statusFile.setText(JSON.stringify({
      count: open, started: started, unseen: unseen, locked: locked,
      stale: root.stale,
      error: root.failure && !locked ? String(root.failure.error) : ""
    }))
  }

  onStoriesChanged: root.publishStatus()
  onRefsChanged: root.publishStatus()
  onFailureChanged: root.publishStatus()

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

  // The story goes in on stdin, never argv: a description is multiline and
  // full of quotes and $, and argv is world-readable through ps besides.
  // stdinEnabled goes false straight after the write, because that is what
  // closes the pipe and lets the script's `cat` return.
  Process {
    id: createProc
    property string body: "{}"
    command: [root.cli, "create"]
    environment: root.cliEnvironment
    stdinEnabled: true
    onStarted: {
      write(createProc.body)
      createProc.body = "{}"
      stdinEnabled = false
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeCreate(text) }
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

  // ---- Timers.

  Timer {
    id: poll
    interval: Math.max(1, root.refreshMinutes) * 60000
    repeat: true
    running: root.configLoaded
    triggeredOnStart: false
    onTriggered: {
      root.ensureRefs()
      if (root.refs) root.refreshStories()
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

  onConfigLoadedChanged: if (root.configLoaded) root.refreshRefs(false)

  // Demo mode changes what the CLI is, not just what it says, so the cached
  // answer from before the switch is not an answer to the question now.
  onDemoChanged: {
    if (!root.configLoaded) return
    // Demo stories are not your stories. The next real list is a new baseline,
    // not a pile of badges for things you already had.
    root.storiesKnown = false
    root.seenBaseline = true
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
