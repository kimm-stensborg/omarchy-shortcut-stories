// Pure helpers for the Shortcut Stories panel: reference lookups, the picker
// lists, the create body, and the story list. Nothing here touches QML, so
// test.sh can run it under node.

// ---- small things.

function str(value) {
  return value === null || value === undefined ? "" : String(value)
}

function trim(value) {
  return str(value).replace(/^\s+|\s+$/g, "")
}

function byName(a, b) {
  var x = str(a.name).toLowerCase(), y = str(b.name).toLowerCase()
  return x < y ? -1 : (x > y ? 1 : 0)
}

// ---- reference data.

// Reference data is cached on disk for hours, so everything that reads it has
// to cope with it being absent, empty, or a shape an older version wrote.
function refsAreStale(refs, nowSeconds, ttl) {
  if (!refs || refs.ok !== true) return true
  if (refs.stale === true) return true
  var at = parseInt(refs.fetchedAt, 10)
  if (!isFinite(at)) return true
  return (nowSeconds - at) >= ttl
}

function findGroup(refs, groupId) {
  var list = (refs && refs.groups) || []
  var wanted = str(groupId)
  if (wanted === "") return null
  for (var i = 0; i < list.length; i++) if (str(list[i].id) === wanted) return list[i]
  return null
}

function findWorkflow(refs, workflowId) {
  var list = (refs && refs.workflows) || []
  for (var i = 0; i < list.length; i++) if (list[i].id === workflowId) return list[i]
  return null
}

// The workflow a state belongs to, and the state itself. Every state id in the
// workspace is unique, so this is a lookup and not a guess.
function findState(refs, stateId) {
  var list = (refs && refs.workflows) || []
  for (var i = 0; i < list.length; i++) {
    var states = list[i].states || []
    for (var j = 0; j < states.length; j++)
      if (states[j].id === stateId) return { workflow: list[i], state: states[j] }
  }
  return null
}

function findMember(refs, memberId) {
  var list = (refs && refs.members) || []
  var wanted = str(memberId)
  if (wanted === "") return null
  for (var i = 0; i < list.length; i++) if (str(list[i].id) === wanted) return list[i]
  return null
}

function findIteration(refs, iterationId) {
  var list = (refs && refs.iterations) || []
  for (var i = 0; i < list.length; i++) if (list[i].id === iterationId) return list[i]
  return null
}

// A team's workflow. default_workflow_id is nullable in the API, hence the
// fallback to the first workflow the team is attached to.
function workflowForGroup(refs, groupId) {
  var group = findGroup(refs, groupId)
  if (!group) return null
  var id = group.defaultWorkflowId
  if (id === null || id === undefined) {
    var ids = group.workflowIds || []
    id = ids.length ? ids[0] : null
  }
  return id === null || id === undefined ? null : findWorkflow(refs, id)
}

// Where a new story lands. A story's board is decided by its workflow_state_id
// and not by its group_id, so sending a team without a state files it under the
// right team on the workspace's default board -- a column that team never
// looks at. Resolving the state is a correctness fix, not a nicety.
function defaultStateFor(refs, groupId) {
  var workflow = workflowForGroup(refs, groupId)
  if (!workflow) return null
  var id = workflow.defaultStateId
  if (id === null || id === undefined) {
    var states = statesOf(workflow)
    id = states.length ? states[0].id : null
  }
  return id === null || id === undefined ? null : { workflowId: workflow.id, stateId: id }
}

function statesOf(workflow) {
  return ((workflow && workflow.states) || []).slice().sort(function(a, b) {
    return (a.position || 0) - (b.position || 0)
  })
}

// The states a story may be moved to: its own workflow's, and no other. The
// API will happily accept a state from a different workflow and move the story
// to a board nobody on that team reads, so the picker never offers one.
function statesForStory(refs, story) {
  var found = story ? findState(refs, story.workflowStateId) : null
  return found ? statesOf(found.workflow) : []
}

// ---- pickers.

function groupOptions(refs) {
  var list = ((refs && refs.groups) || []).slice().sort(byName)
  var out = [{ value: "", label: "No team" }]
  for (var i = 0; i < list.length; i++)
    out.push({ value: str(list[i].id), label: str(list[i].name) })
  return out
}

// You first, because most stories you write are yours. Everyone else by name.
function memberOptions(refs, meId) {
  var list = ((refs && refs.members) || []).slice().sort(byName)
  var mine = str(meId)
  var out = [{ value: "", label: "Unassigned" }]
  for (var i = 0; i < list.length; i++) {
    if (str(list[i].id) !== mine) continue
    out.push({ value: mine, label: "Me (@" + str(list[i].mentionName) + ")" })
    break
  }
  for (var j = 0; j < list.length; j++) {
    if (str(list[j].id) === mine) continue
    out.push({ value: str(list[j].id), label: str(list[j].name) })
  }
  return out
}

// An iteration is current when today falls inside it. Shortcut does not check
// that an iteration belongs to the team you picked, so filtering by team is a
// convenience here rather than a rule the API would enforce.
function iterationIsCurrent(iteration, todayIso) {
  var today = str(todayIso).slice(0, 10)
  if (today === "") return false
  var from = str(iteration.startDate).slice(0, 10)
  var to = str(iteration.endDate).slice(0, 10)
  if (from === "" || to === "") return false
  return from <= today && today <= to
}

function iterationOptions(refs, groupId, todayIso, limit) {
  var list = ((refs && refs.iterations) || []).filter(function(it) {
    return str(it.status) !== "done"
  })
  var team = str(groupId)
  if (team !== "") {
    list = list.filter(function(it) {
      var ids = it.groupIds || []
      // An iteration with no team on it belongs to the whole workspace.
      return ids.length === 0 || ids.map(str).indexOf(team) !== -1
    })
  }
  list = list.slice().sort(function(a, b) {
    var ac = iterationIsCurrent(a, todayIso) ? 0 : 1
    var bc = iterationIsCurrent(b, todayIso) ? 0 : 1
    if (ac !== bc) return ac - bc
    return str(a.startDate) < str(b.startDate) ? -1 : (str(a.startDate) > str(b.startDate) ? 1 : 0)
  })
  var cap = limit === undefined ? 30 : limit
  var out = [{ value: "", label: "No iteration" }]
  for (var i = 0; i < list.length && i < cap; i++) {
    var it = list[i]
    out.push({
      value: String(it.id),
      label: str(it.name) + (iterationIsCurrent(it, todayIso) ? " · current" : "")
    })
  }
  return out
}

// Three types, and the API rejects anything else with a 422 nobody can read.
// Three buttons rather than a dropdown keeps an invalid value unreachable.
var STORY_TYPES = [
  { value: "feature", label: "Feature", glyph: "" },
  { value: "bug", label: "Bug", glyph: "" },
  { value: "chore", label: "Chore", glyph: "" }
]

function storyTypes() {
  return STORY_TYPES.slice()
}

function storyGlyph(type) {
  for (var i = 0; i < STORY_TYPES.length; i++)
    if (STORY_TYPES[i].value === str(type)) return STORY_TYPES[i].glyph
  return STORY_TYPES[0].glyph
}

// ---- description text.

// What kind of markdown line this is. A list has to stay a list, and a run of
// ordinary lines has to stay the lines the author typed.
function descriptionLineKind(line) {
  if (/^\s*$/.test(line)) return "blank"
  if (/^\s{0,3}(\d+[.)]\s|[-*+]\s)/.test(line)) return "list"
  if (/^\s{0,3}(#{1,6}\s|>\s?|[-*_]{3,}\s*$)/.test(line)) return "block"
  return "prose"
}

// Shortcut stores the breaks the author typed. Markdown collapses a single
// newline into a space, so a description written as lines comes out as one
// paragraph. A run of ordinary lines becomes hard breaks. A blank line stays
// a paragraph. A list or a heading starts its own block, and so does the
// prose that follows one, so neither gets swallowed by the other. A fenced
// block is copied as it was typed.
function formatDescription(text) {
  var src = str(text).replace(/\r\n/g, "\n").replace(/[ \t]+$/, "")
  if (trim(src) === "") return ""
  var lines = src.split("\n")
  var out = []
  var inFence = false
  var prev = "start"

  function pushBlank() {
    if (prev === "blank" || prev === "start") return
    out.push("")
    prev = "blank"
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^\s{0,3}(```|~~~)/.test(line)) {
      inFence = !inFence
      if (prev !== "start" && prev !== "blank" && prev !== "fence") pushBlank()
      out.push(line)
      prev = "fence"
      continue
    }
    if (inFence) {
      out.push(line)
      prev = "fence"
      continue
    }
    var kind = descriptionLineKind(line)
    if (kind === "blank") { pushBlank(); continue }
    var cleaned = line.replace(/[ \t]+$/, "")
    if (kind === "prose" && prev === "prose") {
      out[out.length - 1] = out[out.length - 1].replace(/[ \t]+$/, "") + "  "
      out.push(cleaned)
      prev = "prose"
      continue
    }
    if (prev !== "start" && prev !== "blank" && prev !== kind) pushBlank()
    out.push(cleaned)
    prev = kind
  }
  while (out.length && out[out.length - 1] === "") out.pop()
  return out.join("\n")
}

// ---- the form.

function emptyForm(defaults) {
  var d = defaults || {}
  return {
    name: "",
    description: "",
    storyType: str(d.storyType) || "feature",
    groupId: str(d.groupId),
    iterationId: str(d.iterationId),
    ownerId: str(d.ownerId),
    // A GitHub pull request the story was filled from. Filed as Shortcut's
    // external_links so the PR stays on the story after the title is rewritten.
    externalLinks: []
  }
}

// A paste of https://github.com/owner/repo/pull/123 — with optional trailing
// path, query or hash — becomes the story. Anything else is just a title.
function parseGithubPrUrl(text) {
  var raw = trim(text)
  var match = raw.match(/^https?:\/\/(?:www\.)?github\.com\/([^\/\s?#]+)\/([^\/\s?#]+)\/pull\/(\d+)(?:\/[^?\s#]*)?(?:\?[^\s#]*)?(?:#[^\s]*)?$/i)
  if (!match) return null
  var owner = match[1]
  var repo = match[2].replace(/\.git$/i, "")
  var number = parseInt(match[3], 10)
  if (!isFinite(number) || number < 1) return null
  return {
    owner: owner,
    repo: repo,
    number: number,
    url: "https://github.com/" + owner + "/" + repo + "/pull/" + number
  }
}

// owner/repo#42 for the line under the form. A bare URL that is not a GitHub
// PR still shows, rather than vanishing into an empty string.
function prSourceLabel(form) {
  var links = (form && form.externalLinks) || []
  if (!links.length) return ""
  var parsed = parseGithubPrUrl(links[0])
  if (parsed) return parsed.owner + "/" + parsed.repo + "#" + parsed.number
  return trim(links[0])
}

// Turn a looked-up pull request into the form: the PR's title and body become
// the story, and the URL is kept so Create can file it as an external link.
// Team, sprint, owner and type stay where they were — you already picked them.
function applyPrToForm(form, pr, defaults) {
  var next = emptyForm(defaults)
  if (form) {
    next.storyType = str(form.storyType) || next.storyType
    next.groupId = str(form.groupId)
    next.iterationId = str(form.iterationId)
    next.ownerId = str(form.ownerId)
  }
  var title = trim(pr && pr.title)
  if (title === "") title = "Pull request #" + str(pr && pr.number)
  if (title.length > 512) title = title.slice(0, 512)
  next.name = title
  next.description = str(pr && pr.body).replace(/\s+$/, "")
  var url = str(pr && pr.url)
  if (url === "" && pr) {
    var parsed = parseGithubPrUrl("https://github.com/" + str(pr.owner) + "/" + str(pr.repo) + "/pull/" + str(pr.number))
    url = parsed ? parsed.url : ""
  }
  next.externalLinks = url !== "" ? [url] : []
  return next
}

function validateForm(form) {
  var name = trim(form && form.name)
  // A bare PR URL is not a story name yet — lookup still has to rewrite it —
  // but it is enough to start filing from, so validation lets it through.
  if (name === "") return { ok: false, errors: { name: "A story needs a name" } }
  if (name.length > 512) return { ok: false, errors: { name: "That name is too long for Shortcut" } }
  return { ok: true, errors: {} }
}

// What goes on bin/shortcut's stdin. Empty fields are left out entirely rather
// than sent as null, so a name-only form posts exactly {"name": "..."}.
function buildCreateRequest(form, refs) {
  var body = { name: trim(form && form.name) }
  var description = str(form && form.description).replace(/\s+$/, "")
  if (description !== "") body.description = description

  var type = str(form && form.storyType)
  body.storyType = type === "" ? "feature" : type

  var group = str(form && form.groupId)
  if (group !== "") {
    body.groupId = group
    var landing = defaultStateFor(refs, group)
    // No workflow in the cache means no state to name. Leaving it out lets
    // Shortcut apply its own default, which beats guessing wrong.
    if (landing) body.workflowStateId = landing.stateId
  }

  var iteration = parseInt(str(form && form.iterationId), 10)
  if (isFinite(iteration)) body.iterationId = iteration

  var owner = str(form && form.ownerId)
  if (owner !== "") body.ownerId = owner

  var links = (form && form.externalLinks) || []
  var cleaned = []
  for (var i = 0; i < links.length; i++) {
    var url = trim(links[i])
    if (url !== "") cleaned.push(url)
  }
  if (cleaned.length) body.externalLinks = cleaned

  return body
}

// Is there anything here worth a second Esc before it is thrown away?
function draftIsDirty(form, defaults) {
  var base = emptyForm(defaults)
  if (!form) return false
  if (trim(form.name) !== "") return true
  if (trim(form.description) !== "") return true
  if (str(form.storyType) !== base.storyType) return true
  if (str(form.groupId) !== base.groupId) return true
  if (str(form.iterationId) !== base.iterationId) return true
  if (str(form.ownerId) !== base.ownerId) return true
  if ((form.externalLinks || []).length) return true
  return false
}

// After filing one. Team, iteration and owner stay put when sticky: five
// stories in a row usually belong to the same sprint. The PR link does not —
// the next story is not about that pull request.
function clearForm(form, defaults, sticky) {
  var next = emptyForm(defaults)
  if (sticky && form) {
    next.groupId = str(form.groupId)
    next.iterationId = str(form.iterationId)
    next.ownerId = str(form.ownerId)
  }
  return next
}

// The line under the form: where this story is about to land.
function destinationLabel(form, refs) {
  var group = findGroup(refs, form && form.groupId)
  if (!group) return "Your workspace's default workflow"
  var landing = defaultStateFor(refs, str(group.id))
  if (!landing) return str(group.name)
  var found = findState(refs, landing.stateId)
  return str(group.name) + " → " + (found ? str(found.state.name) : "its default state")
}

// ---- the story list.

function summarizeStory(story, refs) {
  var found = story ? findState(refs, story.workflowStateId) : null
  var group = findGroup(refs, story && story.groupId)
  var iteration = findIteration(refs, story && story.iterationId)
  return {
    id: story ? story.id : null,
    ref: story && story.id !== null && story.id !== undefined ? "sc-" + story.id : "",
    name: str(story && story.name),
    storyType: str(story && story.storyType),
    glyph: storyGlyph(story && story.storyType),
    appUrl: str(story && story.appUrl),
    workflowStateId: story ? story.workflowStateId : null,
    stateName: found ? str(found.state.name) : "Unknown",
    stateType: found ? str(found.state.type) : "",
    statePosition: found ? (found.state.position || 0) : 0,
    groupName: group ? str(group.name) : "",
    iterationName: iteration ? str(iteration.name) : "",
    updatedAt: str(story && story.updatedAt)
  }
}

// Comments, oldest first, so the thread reads in the order it was written.
// A deleted comment, or one whose text is gone, is left out: there is nothing
// to read. A reply stays in that order and is only marked, so the view can
// indent it without rebuilding the thread.
function storyComments(raw, refs) {
  var list = ((raw && raw.comments) || []).filter(function(c) {
    return c && c.deleted !== true && trim(c.text) !== ""
  })
  list.sort(function(a, b) {
    var ap = a.position || 0, bp = b.position || 0
    if (ap !== bp) return ap - bp
    var ac = str(a.createdAt), bc = str(b.createdAt)
    return ac < bc ? -1 : (ac > bc ? 1 : 0)
  })
  return list.map(function(c) {
    var author = findMember(refs, c.authorId)
    var parent = c.parentId
    return {
      id: c.id,
      text: formatDescription(c.text),
      authorName: author ? str(author.name)
        : (str(c.authorId) === "" ? "Someone" : "Someone who has left"),
      createdAt: str(c.createdAt),
      reply: parent !== null && parent !== undefined && str(parent) !== "",
      blocker: c.blocker === true
    }
  })
}

// One story opened up. Everything the panel shows is resolved here against the
// reference cache, so the detail view is a layout and holds no lookups.
function storyDetail(raw, refs) {
  if (!raw) return null
  var base = summarizeStory(raw, refs)
  var owners = (raw.ownerIds || []).map(function(id) {
    var m = findMember(refs, id)
    return m ? str(m.name) : "Someone who has left"
  })
  var requester = findMember(refs, raw.requestedById)
  var tasks = raw.tasks || []
  var done = tasks.filter(function(t) { return t.complete === true }).length

  base.description = formatDescription(raw.description)
  base.owners = owners
  base.ownerLabel = owners.length ? owners.join(", ") : "Unassigned"
  base.requesterName = requester ? str(requester.name) : ""
  base.labels = raw.labels || []
  base.tasks = tasks
  base.taskLabel = tasks.length ? done + " of " + tasks.length + " done" : ""
  base.estimate = raw.estimate === null || raw.estimate === undefined ? null : raw.estimate
  base.estimateLabel = base.estimate === null ? ""
    : (base.estimate === 1 ? "1 point" : base.estimate + " points")
  base.deadline = str(raw.deadline).slice(0, 10)
  base.comments = storyComments(raw, refs)
  base.commentCount = base.comments.length
  base.createdAt = str(raw.createdAt)
  return base
}

// The metadata rows the detail view prints, with the empty ones left out so a
// bare story does not show a column of blanks.
function detailFacts(detail) {
  if (!detail) return []
  var rows = [
    { label: "State", value: detail.stateName },
    { label: "Team", value: detail.groupName },
    { label: "Iteration", value: detail.iterationName },
    { label: "Owner", value: detail.ownerLabel },
    { label: "Requested by", value: detail.requesterName },
    { label: "Estimate", value: detail.estimateLabel },
    { label: "Deadline", value: detail.deadline },
    { label: "Labels", value: (detail.labels || []).join(", ") },
    { label: "Tasks", value: detail.taskLabel }
  ]
  return rows.filter(function(r) {
    return r.value !== "" && r.value !== null && r.value !== undefined
  })
}

var STATE_TYPE_ORDER = ["started", "unstarted", "backlog", "done"]

// Iterations today falls inside. A workspace can have one per team, so "the
// current sprint" is all of them, not a guess at which team you meant.
function currentIterations(refs, todayIso) {
  return ((refs && refs.iterations) || []).filter(function(it) {
    return iterationIsCurrent(it, todayIso)
  })
}

// The name on the filter. One sprint is named. Several share the label,
// because the list is about to show all of them. None leaves it blank.
function currentIterationLabel(refs, todayIso) {
  var list = currentIterations(refs, todayIso)
  if (!list.length) return ""
  if (list.length === 1) return str(list[0].name)
  return "Current sprints"
}

// "current" keeps stories whose sprint contains today. Anything else, including
// a scope this version does not know, keeps the whole list.
function storiesInScope(stories, refs, scope, todayIso) {
  var list = stories || []
  if (scope !== "current") return list
  var ids = currentIterations(refs, todayIso).map(function(it) { return str(it.id) })
  return list.filter(function(story) {
    var id = str(story && story.iterationId)
    return id !== "" && ids.indexOf(id) !== -1
  })
}

// Grouped by what kind of state the story is in, because "what am I doing" and
// "what is waiting" are the two questions this list answers.
function sectionStories(stories, refs, showDone) {
  var summaries = (stories || []).map(function(s) { return summarizeStory(s, refs) })
  var sections = []
  for (var i = 0; i < STATE_TYPE_ORDER.length; i++) {
    var type = STATE_TYPE_ORDER[i]
    if (type === "done" && !showDone) continue
    var rows = summaries.filter(function(s) { return s.stateType === type })
    if (!rows.length) continue
    rows.sort(function(a, b) {
      if (a.statePosition !== b.statePosition) return a.statePosition - b.statePosition
      return a.updatedAt < b.updatedAt ? 1 : (a.updatedAt > b.updatedAt ? -1 : 0)
    })
    sections.push({ type: type, title: sectionTitle(type), stories: rows })
  }
  // A story whose state is not in the cache would otherwise vanish from a list
  // that is meant to show everything assigned to you.
  var orphans = summaries.filter(function(s) { return STATE_TYPE_ORDER.indexOf(s.stateType) === -1 })
  if (orphans.length) sections.push({ type: "unknown", title: "Elsewhere", stories: orphans })
  return sections
}

function sectionTitle(type) {
  if (type === "started") return "In progress"
  if (type === "unstarted") return "Ready"
  if (type === "backlog") return "Backlog"
  if (type === "done") return "Done"
  return "Elsewhere"
}

// Optimistic updates. Shortcut's search index trails a write by seconds, so
// the list has to be told what just happened rather than waiting to be asked.
function applyMove(stories, storyId, stateId) {
  return (stories || []).map(function(s) {
    if (s.id !== storyId) return s
    var copy = {}
    for (var k in s) copy[k] = s[k]
    copy.workflowStateId = stateId
    return copy
  })
}

function prependCreated(stories, story) {
  var list = (stories || []).filter(function(s) { return s.id !== (story && story.id) })
  return story ? [story].concat(list) : list
}

function relativeTime(iso, nowSeconds) {
  var at = Date.parse(str(iso))
  if (!isFinite(at)) return ""
  var seconds = Math.round(nowSeconds - at / 1000)
  if (seconds < 90) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.round(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

// ---- settings.
// The same shape tessie uses, so SettingsColumn.qml renders it unchanged. The
// list is duplicated as barWidget.schema in manifest.json because the shell
// reads that one; test.sh asserts the two agree.

var SETTINGS = [
  { title: "New story", rows: [
    // `picker` rows take their options from the workspace rather than from
    // this file, so the list is whatever your teams and sprints actually are.
    { key: "defaultTeam", kind: "picker", source: "teams", label: "Team", fallback: "" },
    { key: "defaultIteration", kind: "picker", source: "iterations", label: "Iteration", fallback: "",
      hint: "A named sprint, or the one today falls inside" },
    { key: "defaultOwner", kind: "picker", source: "members", label: "Owner", fallback: "me" },
    { key: "defaultType", kind: "choice", label: "Type", fallback: "feature",
      options: [{ value: "feature", label: "Feature" }, { value: "bug", label: "Bug" },
                { value: "chore", label: "Chore" }] },
    { key: "stickyFields", kind: "toggle", label: "Keep team and iteration after filing", fallback: true }
  ]},
  { title: "Stories", rows: [
    { key: "defaultMode", kind: "choice", label: "Opens on", fallback: "compose",
      options: [{ value: "compose", label: "New story" }, { value: "mine", label: "My stories" }] },
    { key: "listScope", kind: "choice", label: "Show", fallback: "all",
      options: [{ value: "all", label: "Everything assigned to me" },
                { value: "current", label: "The current sprint" }] },
    { key: "showDone", kind: "toggle", label: "Show finished stories", fallback: false }
  ]},
  { title: "Solve", rows: [
    { key: "solveWorkspace", kind: "picker", source: "workspaces", label: "Workspace", fallback: "",
      hint: "Empty asks each time" },
    { key: "solveWorktree", kind: "toggle", label: "In a worktree", fallback: false },
    { key: "agentKind", kind: "choice", label: "Agent", fallback: "grok",
      options: [{ value: "grok", label: "Grok" }, { value: "claude", label: "Claude" },
                { value: "codex", label: "Codex" }, { value: "cursor", label: "Cursor" },
                { value: "opencode", label: "OpenCode" }] }
  ]},
  { title: "Bar", rows: [
    { key: "barLabel", kind: "choice", label: "Next to the glyph", fallback: "count",
      options: [{ value: "none", label: "Nothing" }, { value: "count", label: "Open stories" },
                { value: "started", label: "In progress" }] },
    { key: "refreshMinutes", kind: "number", label: "Refresh while closed (minutes)",
      fallback: 5, min: 1, max: 60 }
  ]},
  { title: "Shortcut", rows: [
    { key: "demo", kind: "toggle", label: "Demo workspace", fallback: false,
      hint: "A made-up workspace; never calls Shortcut" }
  ]}
]

// The settings page. New story beside Solve, then the list beside the bar.
// Shortcut sits under the bar: it is the one switch that is not part of either.
function settingsPage() {
  var order = [["New story", "Stories"], ["Solve", "Bar", "Shortcut"]]
  return order.map(function(names) {
    return names.map(function(name) {
      for (var i = 0; i < SETTINGS.length; i++)
        if (SETTINGS[i].title === name) return SETTINGS[i]
      return null
    }).filter(function(section) { return section })
  })
}

// What a picker row offers. The values are what get stored, so they have to
// survive a workspace that changes underneath them: "me" and "current" are
// kept as words rather than resolved to an id at the time you pick them.
function settingOptions(row, refs, todayIso, groupId, workspaces) {
  if (!row) return []
  if (row.kind !== "picker") return row.options || []
  if (row.source === "workspaces") {
    var spaces = [{ value: "", label: "Ask each time" }]
    var named = (workspaces || []).slice().sort(function(a, b) {
      var al = str(a.label).toLowerCase(), bl = str(b.label).toLowerCase()
      return al < bl ? -1 : (al > bl ? 1 : 0)
    })
    var seen = {}
    for (var w = 0; w < named.length; w++) {
      var label = str(named[w].label)
      if (label === "" || seen[label]) continue
      seen[label] = true
      spaces.push({ value: label, label: label })
    }
    return spaces
  }
  if (row.source === "teams") return groupOptions(refs)
  if (row.source === "members") {
    var people = [{ value: "", label: "Unassigned" }, { value: "me", label: "Me" }]
    var meId = refs && refs.me ? str(refs.me.id) : ""
    var list = ((refs && refs.members) || []).slice().sort(byName)
    for (var i = 0; i < list.length; i++) {
      if (str(list[i].id) === meId) continue
      people.push({ value: str(list[i].id), label: str(list[i].name) })
    }
    return people
  }
  if (row.source === "iterations") {
    var out = [{ value: "", label: "No iteration" },
               { value: "current", label: "Whichever one is current" }]
    var its = iterationOptions(refs, groupId === undefined ? "" : groupId, todayIso)
    // iterationOptions leads with its own "No iteration"; ours is already there.
    for (var j = 1; j < its.length; j++) out.push(its[j])
    return out
  }
  return []
}

// A stored team setting as a group id. An id is what the picker writes, but a
// name typed at a terminal has to keep working, so both are accepted.
function resolveTeamSetting(refs, value) {
  var wanted = trim(value)
  if (wanted === "") return ""
  if (findGroup(refs, wanted)) return wanted
  var list = (refs && refs.groups) || []
  for (var i = 0; i < list.length; i++)
    if (str(list[i].name).toLowerCase() === wanted.toLowerCase()) return str(list[i].id)
  return ""
}

// "me" follows the account rather than pinning a uuid, so the setting still
// means you after a re-invite.
function resolveOwnerSetting(refs, value) {
  var wanted = trim(value)
  if (wanted === "") return ""
  if (wanted === "me") return refs && refs.me ? str(refs.me.id) : ""
  return findMember(refs, wanted) ? wanted : ""
}

// "current" is the iteration today falls inside, on the team in hand. A
// pinned iteration that has since finished, or belongs to another team, is
// dropped rather than sent.
function resolveIterationSetting(refs, value, groupId, todayIso) {
  var wanted = trim(value)
  if (wanted === "") return ""
  var allowed = iterationOptions(refs, groupId, todayIso)
  if (wanted === "current") {
    for (var i = 1; i < allowed.length; i++)
      if (allowed[i].label.indexOf("\u00b7 current") !== -1) return allowed[i].value
    return ""
  }
  for (var j = 1; j < allowed.length; j++) if (allowed[j].value === wanted) return wanted
  return ""
}

function settingRow(key) {
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++) if (rows[r].key === key) return rows[r]
  }
  return null
}

// A multi-value setting. Stored as an array, but it may arrive as a string:
// `omarchy bar set` splits its own arguments on commas, so a list typed at a
// terminal has to be space-separated, and a hand-edited shell.json is as
// likely to use commas. Both read the same here.
function choiceList(value) {
  var list = Array.isArray(value)
    ? value
    : String(value === null || value === undefined ? "" : value).split(/[,\s]+/)
  return list.map(function(v) { return String(v).replace(/^\s+|\s+$/g, "") })
             .filter(function(v) { return v !== "" })
}

// A stored value as the widget should use it: absent, out of range or simply
// wrong reads as the default rather than breaking the panel.
function coerceSetting(row, raw) {
  if (!row) return raw
  var missing = raw === undefined || raw === null
  if (row.kind === "toggle") {
    if (missing || raw === "") return row.fallback === true
    return raw === true || ["true", "on", "yes", "1"].indexOf(String(raw).toLowerCase()) !== -1
  }
  if (row.kind === "number") {
    var n = parseInt(raw, 10)
    if (!isFinite(n)) n = row.fallback
    return Math.max(row.min, Math.min(row.max, n))
  }
  if (row.kind === "multi") {
    var allowed = row.options.map(function(o) { return o.value })
    if (missing || raw === "") return row.fallback.slice()
    return choiceList(raw).filter(function(v) { return allowed.indexOf(v) !== -1 })
  }
  if (row.kind === "picker") return String(missing ? row.fallback : raw)
  if (row.kind === "choice") {
    var picked = String(missing ? row.fallback : raw)
    return row.options.some(function(o) { return o.value === picked }) ? picked : row.fallback
  }
  return String(missing ? "" : raw)
}

function readSetting(settings, key) {
  return coerceSetting(settingRow(key), settings ? settings[key] : undefined)
}

function isDefaultSetting(row, value) {
  if (!row) return false
  if (row.kind === "multi") {
    if (value === null || value === undefined) return true
    var chosen = choiceList(value)
    return chosen.length === row.fallback.length
      && row.fallback.every(function(v) { return chosen.indexOf(v) !== -1 })
  }
  if (row.kind === "text") return trim(value) === ""
  return value === row.fallback
}

// The whole shell.json entry a change leaves behind. updateEntryInline
// replaces the entry rather than merging into it, so every other key has to be
// carried across; a value back at its default is dropped instead of written.
// `changes` of null clears every option this page owns.
function nextEntry(settings, id, changes) {
  var entry = { id: String(id || "") }
  for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
  if (changes === null) {
    for (var s = 0; s < SETTINGS.length; s++)
      SETTINGS[s].rows.forEach(function(row) { delete entry[row.key] })
    return entry
  }
  for (var key in changes) {
    var row = settingRow(key)
    var value = changes[key]
    if (row && isDefaultSetting(row, value)) delete entry[key]
    else if (row && row.kind === "text") entry[key] = trim(value)
    else entry[key] = value
  }
  return entry
}

function hasCustomSettings(settings) {
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++) {
      var raw = settings ? settings[rows[r].key] : undefined
      if (raw !== undefined && raw !== null && !isDefaultSetting(rows[r], coerceSetting(rows[r], raw)))
        return true
    }
  }
  return false
}

function toggleChoice(row, value, option) {
  var all = row.options.map(function(o) { return o.value })
  var current = value === null || value === undefined ? row.fallback.slice() : choiceList(value)
  if (current.indexOf(option) !== -1)
    return current.filter(function(v) { return v !== option })
  return all.filter(function(v) { return v === option || current.indexOf(v) !== -1 })
}

var ROW_WEIGHT = { text: 3, multi: 3, picker: 3, choice: 2, number: 2, toggle: 2 }

function sectionWeight(section) {
  return section.rows.reduce(function(sum, row) {
    return sum + (ROW_WEIGHT[row.kind] || 2)
  }, 1)
}

// The sections dealt into `count` columns, in order, so that the tallest
// column comes out as short as it can.
function settingsColumns(count) {
  var wanted = Math.max(1, Math.min(Math.round(count) || 1, SETTINGS.length))
  var weights = SETTINGS.map(sectionWeight)
  var best = null

  function tallestOf(cuts) {
    var tallest = 0
    var from = 0
    for (var i = 0; i < cuts.length; i++) {
      var sum = 0
      for (var j = from; j < cuts[i]; j++) sum += weights[j]
      if (sum > tallest) tallest = sum
      from = cuts[i]
    }
    return tallest
  }

  // Only contiguous splits, so the sections stay in the order they are read.
  function walk(start, left, cuts) {
    if (left === 1) {
      var all = cuts.concat([SETTINGS.length])
      var tallest = tallestOf(all)
      if (best === null || tallest < best.tallest) best = { tallest: tallest, cuts: all }
      return
    }
    for (var cut = start + 1; cut <= SETTINGS.length - (left - 1); cut++)
      walk(cut, left - 1, cuts.concat([cut]))
  }
  walk(0, wanted, [])

  var columns = []
  var from = 0
  for (var i = 0; i < best.cuts.length; i++) {
    columns.push(SETTINGS.slice(from, best.cuts[i]))
    from = best.cuts[i]
  }
  return columns
}

// This widget's entry in the bar config the shell hands a plugin, which is
// where the overlay reads the settings it is about to change.
function entryFor(barConfig, id) {
  var layout = barConfig && barConfig.layout ? barConfig.layout : {}
  var wanted = String(id || "")
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var arr = layout[sections[s]] || []
    for (var i = 0; i < arr.length; i++) {
      // Clones carry a "#2" suffix; the id in front of it is the plugin's.
      if (arr[i] && String(arr[i].id || "").split("#")[0] === wanted) return arr[i]
    }
  }
  return { id: wanted }
}

function settingsSummary(settings) {
  return hasCustomSettings(settings) ? "Changed from the defaults" : "All at their defaults"
}

// Stories still to do. A story moved to a done state stays in the list we
// hold -- it is still assigned to you -- but counting it would make the
// header disagree with the rows underneath it.
function openCount(stories, refs) {
  return (stories || []).filter(function(s) {
    var found = findState(refs, s.workflowStateId)
    return !found || str(found.state.type) !== "done"
  }).length
}

function startedCount(stories, refs) {
  return (stories || []).filter(function(s) {
    var found = findState(refs, s.workflowStateId)
    return found && str(found.state.type) === "started"
  }).length
}

function storyKey(story) {
  if (!story || story.id === null || story.id === undefined) return ""
  var id = String(story.id)
  return id === "" ? "" : id
}

// Stories on the list that are not in the seen set. The bar's badge is this
// count: assigned since you last opened them, not everything you own.
function unseenStories(stories, seenIds) {
  var known = {}
  var seen = seenIds || []
  for (var i = 0; i < seen.length; i++) known[String(seen[i])] = true
  var out = []
  var list = stories || []
  for (var j = 0; j < list.length; j++) {
    var id = storyKey(list[j])
    if (id === "" || known[id]) continue
    out.push(list[j])
  }
  return out
}

function unseenCount(stories, seenIds) {
  return unseenStories(stories, seenIds).length
}

// The seen set, kept to stories still on the list. Ones that have left are
// forgotten, so one that comes back reads as new. `readIds` are stories just
// opened; they join the set only while they are still assigned to you.
function noteSeen(seenIds, stories, readIds) {
  var current = {}
  var list = stories || []
  for (var i = 0; i < list.length; i++) {
    var id = storyKey(list[i])
    if (id !== "") current[id] = true
  }
  var keep = {}
  var seen = seenIds || []
  for (var j = 0; j < seen.length; j++) {
    var s = String(seen[j])
    if (current[s]) keep[s] = true
  }
  var read = readIds || []
  for (var k = 0; k < read.length; k++) {
    var r = String(read[k])
    if (r !== "" && current[r]) keep[r] = true
  }
  var out = []
  for (var key in keep) out.push(key)
  return out
}

// The first list the plugin ever sees. Everything already assigned is the
// baseline, so the badge does not light up for stories you had before it
// started watching.
function seenIdsOf(stories) {
  var ids = []
  var list = stories || []
  for (var i = 0; i < list.length; i++) {
    var id = storyKey(list[i])
    if (id !== "") ids.push(id)
  }
  return noteSeen([], list, ids)
}

function sameIds(a, b) {
  var left = a || []
  var right = b || []
  if (left.length !== right.length) return false
  var known = {}
  for (var i = 0; i < left.length; i++) known[String(left[i])] = true
  for (var j = 0; j < right.length; j++) if (!known[String(right[j])]) return false
  return true
}

// ---- Handing a story to Herdr.
// The agent name has to match Herdr's alias rule, and the branch is the same
// sc- reference the panel already shows, so the checkout and the story can be
// told apart later.

var SOLVE_PROMPT_LIMIT = 12000

function solveId(storyId) {
  var id = String(storyId === null || storyId === undefined ? "" : storyId).replace(/[^0-9]/g, "")
  return id
}

function solveAgentName(storyId) {
  var id = solveId(storyId)
  if (!id) return ""
  return ("s" + id).slice(0, 32)
}

function solveBranch(storyId) {
  var id = solveId(storyId)
  return id ? "sc-" + id : ""
}

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// A saved workspace name, matched against the live list. An empty name, or one
// Herdr no longer has, means Solve has to ask. The match is the label, not the
// session id: those ids do not survive a restart.
function workspaceByLabel(workspaces, label) {
  var wanted = trim(label).toLowerCase()
  if (!wanted) return null
  var list = workspaces || []
  for (var i = 0; i < list.length; i++)
    if (str(list[i].label).toLowerCase() === wanted) return list[i]
  return null
}

function solveTarget(workspaces, savedLabel) {
  var found = workspaceByLabel(workspaces, savedLabel)
  if (!found) return { ask: true, workspace: null }
  return { ask: false, workspace: found }
}

// The story text names exactly one workspace, so the row can land there.
// Hyphen stays inside the name: "notes" is not "omarchy-notes".
function suggestWorkspace(workspaces, text) {
  var hay = str(text).toLowerCase()
  var hits = []
  var list = workspaces || []
  for (var i = 0; i < list.length; i++) {
    var label = str(list[i].label).toLowerCase()
    if (label.length < 3) continue
    var re = new RegExp("(^|[^a-z0-9-])" + escapeRegExp(label) + "([^a-z0-9-]|$)")
    if (re.test(hay)) hits.push(list[i])
  }
  return hits.length === 1 ? hits[0] : null
}

function solveHaystack(raw) {
  var parts = [str(raw && raw.name), str(raw && raw.description)]
  var comments = (raw && raw.comments) || []
  for (var i = 0; i < comments.length; i++) parts.push(str(comments[i] && comments[i].text))
  return parts.join("\n")
}

function capSolvePrompt(text, url) {
  if (text.length <= SOLVE_PROMPT_LIMIT) return text
  var note = "\n\nThe rest is on " + (url || "the story") + "."
  var room = SOLVE_PROMPT_LIMIT - note.length
  if (room < 1) return note.slice(0, SOLVE_PROMPT_LIMIT)
  var cut = text.slice(0, room)
  var sp = cut.lastIndexOf(" ")
  if (sp > room - 80) cut = cut.slice(0, sp)
  return cut + note
}

// What the agent is asked. The description and the comments stay as they were
// written: the view's hard breaks are for Qt's markdown, and an agent should
// see the author's newlines. A worktree is already on the branch, so the
// prompt must not tell the agent to check that branch out again.
function solvePrompt(raw, refs, worktree) {
  var branch = solveBranch(raw && raw.id)
  if (!branch) return ""
  var url = str(raw.appUrl)
  var lines = ["Solve Shortcut story " + branch + ".", "", "Title: " + str(raw.name)]
  if (url) lines.push("URL: " + url)
  lines.push("", "Description:", str(raw.description) || "(none)", "", "Tasks:")
  var tasks = raw.tasks || []
  if (!tasks.length) lines.push("(none)")
  for (var i = 0; i < tasks.length; i++) {
    var task = tasks[i] || {}
    lines.push("- [" + (task.complete === true ? "x" : " ") + "] " + str(task.description))
  }
  lines.push("", "Comments, oldest first:")
  var comments = (raw.comments || []).filter(function(c) {
    return c && c.deleted !== true && trim(c.text) !== ""
  })
  comments.sort(function(a, b) {
    var ap = a.position || 0, bp = b.position || 0
    if (ap !== bp) return ap - bp
    var ac = str(a.createdAt), bc = str(b.createdAt)
    return ac < bc ? -1 : (ac > bc ? 1 : 0)
  })
  if (!comments.length) lines.push("(none)")
  for (var j = 0; j < comments.length; j++) {
    var comment = comments[j]
    var author = findMember(refs, comment.authorId)
    var who = author ? str(author.name)
      : (str(comment.authorId) === "" ? "Someone" : "Someone who has left")
    lines.push("- " + who + ": " + str(comment.text))
  }
  lines.push("")
  if (worktree)
    lines.push("This checkout is already on branch " + branch + ". Implement the story here.")
  else
    lines.push("Create a branch named " + branch + " and implement the story there.")
  lines.push("Leave the Shortcut story where it is. Do not push.")
  return capSolvePrompt(lines.join("\n"), url)
}

function solveCaption(workspace, worktree, storyId) {
  var name = workspace ? str(workspace.label) : ""
  var branch = solveBranch(storyId)
  if (worktree) return "Worktree " + branch + (name ? " under " + name : "")
  return name ? "New tab in " + name : "New tab"
}

// What the bar shows next to the glyph. The same list the panel is showing:
// the current sprint when that filter is on, otherwise everything assigned.
function barLabel(stories, refs, mode, scope, todayIso) {
  if (mode === "none") return ""
  var list = storiesInScope(stories, refs, scope, todayIso)
  var n = mode === "started" ? startedCount(list, refs) : openCount(list, refs)
  return n ? String(n) : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    refsAreStale: refsAreStale, findGroup: findGroup, findWorkflow: findWorkflow,
    findState: findState, findMember: findMember, findIteration: findIteration,
    workflowForGroup: workflowForGroup, defaultStateFor: defaultStateFor,
    statesOf: statesOf, statesForStory: statesForStory,
    groupOptions: groupOptions, memberOptions: memberOptions,
    iterationOptions: iterationOptions, iterationIsCurrent: iterationIsCurrent,
    storyTypes: storyTypes, storyGlyph: storyGlyph,
    formatDescription: formatDescription,
    emptyForm: emptyForm, validateForm: validateForm,
    parseGithubPrUrl: parseGithubPrUrl, prSourceLabel: prSourceLabel,
    applyPrToForm: applyPrToForm,
    buildCreateRequest: buildCreateRequest, draftIsDirty: draftIsDirty,
    clearForm: clearForm, destinationLabel: destinationLabel,
    summarizeStory: summarizeStory, storyComments: storyComments,
    storyDetail: storyDetail,
    detailFacts: detailFacts, sectionStories: sectionStories,
    sectionTitle: sectionTitle,
    currentIterations: currentIterations, currentIterationLabel: currentIterationLabel,
    storiesInScope: storiesInScope,
    applyMove: applyMove,
    prependCreated: prependCreated, relativeTime: relativeTime,
    SETTINGS: SETTINGS, settingsPage: settingsPage, settingRow: settingRow, choiceList: choiceList,
    coerceSetting: coerceSetting, readSetting: readSetting,
    isDefaultSetting: isDefaultSetting, nextEntry: nextEntry,
    hasCustomSettings: hasCustomSettings, toggleChoice: toggleChoice,
    sectionWeight: sectionWeight, settingsColumns: settingsColumns,
    entryFor: entryFor, settingsSummary: settingsSummary, barLabel: barLabel,
    openCount: openCount, startedCount: startedCount,
    storyKey: storyKey, unseenStories: unseenStories, unseenCount: unseenCount,
    noteSeen: noteSeen, seenIdsOf: seenIdsOf, sameIds: sameIds,
    settingOptions: settingOptions, resolveTeamSetting: resolveTeamSetting,
    resolveOwnerSetting: resolveOwnerSetting, resolveIterationSetting: resolveIterationSetting,
    SOLVE_PROMPT_LIMIT: SOLVE_PROMPT_LIMIT,
    solveAgentName: solveAgentName, solveBranch: solveBranch,
    workspaceByLabel: workspaceByLabel, solveTarget: solveTarget,
    suggestWorkspace: suggestWorkspace, solveHaystack: solveHaystack,
    solvePrompt: solvePrompt, solveCaption: solveCaption
  }
}
