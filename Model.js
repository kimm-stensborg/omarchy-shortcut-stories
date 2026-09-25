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

// The people a story is for, in the order they were added, each once. A story
// can have several owners; every place the form holds them goes through here,
// so an edit never quietly narrows the list down to its first entry.
function ownerList(ids) {
  var list = ids || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var id = trim(list[i])
    if (id !== "" && out.indexOf(id) === -1) out.push(id)
  }
  return out
}

function addOwner(ids, id) {
  return ownerList((ids || []).concat([id]))
}

function removeOwner(ids, id) {
  var gone = trim(id)
  return ownerList(ids).filter(function(o) { return o !== gone })
}

// One chip per owner already on the form. Someone who has left the workspace
// still gets a chip, so they can be seen and taken off rather than riding
// along invisibly.
function ownerChips(refs, ids, meId) {
  var mine = str(meId)
  return ownerList(ids).map(function(id) {
    if (id === mine) return { value: id, label: "Me" }
    var m = findMember(refs, id)
    return { value: id, label: m ? str(m.name) : "Someone who has left" }
  })
}

// What the add picker offers: everyone not on the story yet, you first.
// "Unassigned" is not a person to add -- no chips is what unassigned means.
function ownerAddOptions(refs, meId, ids) {
  var taken = ownerList(ids)
  return memberOptions(refs, meId).filter(function(o) {
    return o.value !== "" && taken.indexOf(o.value) === -1
  })
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
    ownerIds: ownerList([d.ownerId]),
    // A GitHub pull request the story was filled from. Filed as Shortcut's
    // external_links so the PR stays on the story after the title is rewritten.
    externalLinks: [],
    // Every other external link an existing story already carries -- a doc, a
    // Figma file, anything not shaped like a GitHub PR. The edit form never
    // shows these, but it has to round-trip them, or saving a story that has
    // one would silently drop it.
    otherLinks: [],
    // Images to upload and show in the description when the story is filed:
    // screenshots, by path on this machine.
    files: []
  }
}

// The images on a draft, each once, in the order they were added.
function fileList(files) {
  var out = []
  var list = files || []
  for (var i = 0; i < list.length; i++) {
    var f = str(list[i])
    if (f !== "" && out.indexOf(f) === -1) out.push(f)
  }
  return out
}

function addFiles(files, more) {
  return fileList((files || []).concat(more || []))
}

function removeFile(files, path) {
  var gone = str(path)
  return fileList(files).filter(function(f) { return f !== gone })
}

// A draft opened from a screenshot. On a blank form it becomes a bug, since
// that is what a screenshot of something is nearly always for; a draft you
// had already started keeps its type and just gains the picture.
function withScreenshots(form, files, storyType, blank) {
  var next = {}
  for (var k in form) next[k] = form[k]
  next.files = addFiles(form && form.files, files)
  if (blank && str(storyType) !== "") next.storyType = str(storyType)
  return next
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

// The first of a story's external links shaped like a GitHub PR, or "" for
// none. Used both for the row icon in the list and to seed the edit form's
// one editable slot.
function firstPrLink(links) {
  var list = links || []
  for (var i = 0; i < list.length; i++) if (parseGithubPrUrl(list[i])) return list[i]
  return ""
}

// owner/repo#42 for one PR link. A URL that is not a GitHub PR still shows,
// trimmed, rather than vanishing into an empty string.
function prRefLabel(url) {
  var u = trim(url)
  if (u === "") return ""
  var parsed = parseGithubPrUrl(u)
  return parsed ? parsed.owner + "/" + parsed.repo + "#" + parsed.number : u
}

// Same, read off the compose form's one PR slot.
function prSourceLabel(form) {
  var links = (form && form.externalLinks) || []
  return links.length ? prRefLabel(links[0]) : ""
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
    next.ownerIds = ownerList(form.ownerIds)
    next.files = fileList(form.files)
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

  var owners = ownerList(form && form.ownerIds)
  if (owners.length) body.ownerIds = owners

  var links = (form && form.externalLinks) || []
  var cleaned = []
  for (var i = 0; i < links.length; i++) {
    var url = trim(links[i])
    if (url !== "") cleaned.push(url)
  }
  if (cleaned.length) body.externalLinks = cleaned

  var files = fileList(form && form.files)
  if (files.length) body.files = files

  return body
}

// A story already on Shortcut, turned back into the same shape the compose
// form edits. Only the fields the form offers come back — labels, tasks,
// comments and the rest stay on the story, untouched by an edit. The one
// external link shaped like a GitHub PR becomes the editable slot; every
// other one is set aside in otherLinks, unedited but not lost.
function formFromDetail(raw) {
  var links = (raw && raw.externalLinks) || []
  var pr = null
  var others = []
  for (var i = 0; i < links.length; i++) {
    if (pr === null && parseGithubPrUrl(links[i])) pr = links[i]
    else others.push(links[i])
  }
  return {
    name: str(raw && raw.name),
    description: str(raw && raw.description),
    storyType: str(raw && raw.storyType) || "feature",
    groupId: str(raw && raw.groupId),
    iterationId: raw && raw.iterationId !== null && raw.iterationId !== undefined
      ? str(raw.iterationId) : "",
    ownerIds: ownerList(raw && raw.ownerIds),
    externalLinks: pr ? [pr] : [],
    otherLinks: others
  }
}

// Every field the edit form holds, as bin/shortcut update takes it. Empty
// fields stay in as null or [] rather than being left out, because this is
// not a blank the API should default: an edit that clears the sprint or the
// owners has to say so. buildUpdatePatch below picks out only the fields that
// changed; this is the whole picture it compares. The linked PR works the
// same way -- cleared means cleared -- but only that one entry: whatever else
// was in otherLinks rides along untouched, so editing a story can never
// silently drop a doc or a Figma link it already had.
function buildUpdateRequest(form) {
  var iteration = parseInt(str(form && form.iterationId), 10)
  var pr = trim(form && form.externalLinks && form.externalLinks[0])
  if (pr !== "") {
    var parsed = parseGithubPrUrl(pr)
    if (parsed) pr = parsed.url
  }
  var others = ((form && form.otherLinks) || []).map(trim).filter(function(u) { return u !== "" })
  return {
    name: trim(form && form.name),
    description: str(form && form.description).replace(/\s+$/, ""),
    storyType: str(form && form.storyType) || "feature",
    groupId: str(form && form.groupId),
    iterationId: isFinite(iteration) ? iteration : null,
    ownerIds: ownerList(form && form.ownerIds),
    externalLinks: pr !== "" ? others.concat([pr]) : others
  }
}

// What an edit is compared against when it is saved: the story as the detail
// view had it when Edit was pressed, in the same shape bin/shortcut reads it
// back in. Not the form -- the form has already normalized things (the PR
// link pulled out and canonicalized), and a comparison has to be like for
// like or every link written a different way reads as someone else's edit.
function editBase(detail) {
  var d = detail || {}
  return {
    name: d.name === undefined ? null : d.name,
    description: str(d.description),
    storyType: d.storyType === undefined ? null : d.storyType,
    groupId: d.groupId === undefined ? null : d.groupId,
    iterationId: d.iterationId === undefined ? null : d.iterationId,
    ownerIds: (d.ownerIds || []).slice(),
    externalLinks: (d.externalLinks || []).slice()
  }
}

// What Save actually sends: only the fields that differ from what the edit
// opened with, and -- under base -- what each of those looked like then. A
// field you did not touch is not sent at all, so it cannot overwrite a change
// someone made to it in Shortcut meanwhile; one you did touch is checked
// against the story as it is now before it is written.
function buildUpdatePatch(form, seed, base) {
  var now = buildUpdateRequest(form)
  var was = buildUpdateRequest(seed)
  var patch = {}
  var then = {}
  for (var key in now) {
    if (JSON.stringify(now[key]) === JSON.stringify(was[key])) continue
    patch[key] = now[key]
    if (base && key in base) then[key] = base[key]
  }
  if (base) patch.base = then
  return patch
}

// Save has nothing to do until the edit actually differs from the story it
// was seeded from. Comparing the two built requests, rather than the two
// forms field by field, means anything buildUpdateRequest itself normalizes
// away -- trimmed whitespace, a PR link written a different way -- does not
// read as a change either, and a field added there later is covered here for
// free.
function editFormDirty(form, seed) {
  if (!form || !seed) return false
  return JSON.stringify(buildUpdateRequest(form)) !== JSON.stringify(buildUpdateRequest(seed))
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
  if (ownerList(form.ownerIds).join(",") !== base.ownerIds.join(",")) return true
  if ((form.externalLinks || []).length) return true
  if (fileList(form.files).length) return true
  return false
}

// What Esc does on the new-story form. An open dropdown closes first. A
// draft with something in it is warned about once -- a reflex keystroke
// should not cost a half-written story -- and the next Esc cancels it. A
// blank form has nothing to lose, so Esc cancels straight away.
function composeEscape(popupOpen, dirty, armed) {
  if (popupOpen) return "popup"
  if (dirty && !armed) return "arm"
  return "cancel"
}

// Where cancelling a new story lands: the pane it was started from -- the
// list, or the story that was open -- or nowhere, which closes the panel,
// when the panel was opened straight onto the form.
function cameFrom(mode, storyId) {
  var m = str(mode)
  if (m !== "mine" && m !== "settings") return null
  var id = parseInt(storyId, 10)
  return { mode: m, storyId: m === "mine" && isFinite(id) && id > 0 ? id : 0 }
}

// After filing one. Team, iteration and owner stay put when sticky: five
// stories in a row usually belong to the same sprint. The PR link does not —
// the next story is not about that pull request.
function clearForm(form, defaults, sticky) {
  var next = emptyForm(defaults)
  if (sticky && form) {
    next.groupId = str(form.groupId)
    next.iterationId = str(form.iterationId)
    next.ownerIds = ownerList(form.ownerIds)
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

// A story's other links -- every external link that is not the PR the
// header already has a chip for -- as chips of their own, labelled by where
// they go: figma.com, docs.google.com. The full address is the tooltip. A
// GitHub link that is not a PR (an issue, a file) says so by its path.
function linkChips(links, prUrl) {
  var pr = parseGithubPrUrl(prUrl)
  var out = []
  var seen = []
  var list = links || []
  for (var i = 0; i < list.length; i++) {
    var url = trim(list[i])
    if (url === "" || seen.indexOf(url) !== -1) continue
    var asPr = parseGithubPrUrl(url)
    if (pr && asPr && asPr.url === pr.url) continue
    seen.push(url)
    var m = url.match(/^[a-z][a-z0-9+.-]*:\/\/(?:www\.)?([^\/?#:]+)([^?#]*)/i)
    var host = m ? m[1].toLowerCase() : url
    var label = host
    if (asPr) label = prRefLabel(url)
    else if (host === "github.com" && m) {
      var parts = m[2].split("/").filter(function(p) { return p !== "" })
      if (parts.length >= 2) label = parts.slice(0, 2).join("/") + (parts.length > 3 ? " " + parts[2] + " " + parts[3] : "")
    }
    out.push({ url: url, label: label, github: host === "github.com" })
  }
  return out
}

// ---- undoing a move.
// A move lands the moment you press Enter, so the footer says what just
// happened and how to take it back, for a few seconds. move is
// {id, from, to}: the story and the two state ids.

function stateNameOf(refs, stateId) {
  var found = findState(refs, stateId)
  return found ? str(found.state.name) : "another state"
}

function moveNotice(refs, move) {
  if (!move) return ""
  return "Moved sc-" + str(move.id) + " to " + stateNameOf(refs, move.to) + " · Ctrl+Z moves it back"
}

function movedBackNotice(refs, move) {
  if (!move) return ""
  return "sc-" + str(move.id) + " is back in " + stateNameOf(refs, move.to)
}

// ---- the keys.
// Every key the panel answers to, grouped by where it works. The ? card
// shows this, so the footer only has to carry the two or three that matter
// on the pane in front of you.
var KEY_HELP = [
  { title: "Everywhere", keys: [
    ["SUPER + ALT + T", "Show or hide the panel"],
    ["SUPER + ALT + B", "A new bug from a screenshot"],
    ["Alt + 1", "A new story"],
    ["Alt + 2", "Your stories"],
    ["Ctrl + Tab", "Swap between those two"],
    ["Ctrl + ,", "Settings"],
    ["Ctrl + R", "Re-read your workspace and stories"],
    ["? or F1", "These keys"],
    ["Esc", "Back a step, then close"]] },
  { title: "A new story", keys: [
    ["Enter", "File it, from the title"],
    ["Ctrl + Enter", "File it, from anywhere"],
    ["Tab / Shift + Tab", "Next field, previous field"],
    ["Alt + F / B / C", "Feature, bug, chore"],
    ["Alt + S", "Add a screenshot"],
    ["Ctrl + V", "Add the image on the clipboard"],
    ["Esc twice", "Throw the draft away"]] },
  { title: "Your stories", keys: [
    ["↑ ↓", "Walk the list"],
    ["Enter", "Open the story"],
    ["Ctrl + O", "Open it in Shortcut"],
    ["Alt + I", "Only the current sprint, or everything"]] },
  { title: "An open story", keys: [
    ["← →", "Pick a state"],
    ["Enter", "Move it there"],
    ["Ctrl + Z", "Move it back"],
    ["Ctrl + E", "Edit it"],
    ["Ctrl + O", "Open it in Shortcut"],
    ["Ctrl + G", "Open its pull request on GitHub"],
    ["Alt + A", "Hand it to an agent"],
    ["Alt + P", "Push its branch and open a pull request"]] },
  { title: "Solve and pull request screens", keys: [
    ["Enter", "Start, or push and open"],
    ["Ctrl + Enter", "The same, from the text"],
    ["← →", "Pick a workspace (Solve)"],
    ["W", "In a worktree (Solve)"],
    ["D", "As a draft (pull request)"],
    ["Esc", "Back to the story"]] }
]

function keyHelp() { return KEY_HELP }

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
    prUrl: firstPrLink(story && story.externalLinks),
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
    var common = commonStateName(rows)
    sections.push({ type: type, title: sectionTitle(type), stories: rows,
                    commonState: common,
                    heading: common ? sectionTitle(type) + " · " + common : sectionTitle(type) })
  }
  // A story whose state is not in the cache would otherwise vanish from a list
  // that is meant to show everything assigned to you.
  var orphans = summaries.filter(function(s) { return STATE_TYPE_ORDER.indexOf(s.stateType) === -1 })
  if (orphans.length)
    sections.push({ type: "unknown", title: "Elsewhere", stories: orphans, commonState: "", heading: "Elsewhere" })
  return sections
}

// The state most of a section's stories are in, when at least two share it
// -- it goes in the heading once, and a row only names its state when it is
// a different one. Ten rows all saying "Prioritized & Ready for
// Development" is noise; the one that says "Ready for Code Review" among
// them is the news. "" when no state is shared, so every row keeps its own.
function commonStateName(rows) {
  var counts = {}
  var best = ""
  var most = 1
  for (var i = 0; i < rows.length; i++) {
    var name = str(rows[i].stateName)
    if (name === "" || name === "Unknown") continue
    counts[name] = (counts[name] || 0) + 1
    if (counts[name] > most) { most = counts[name]; best = name }
  }
  return best
}

// The list as the pane walks it: a heading, then its stories, each knowing
// whether to name its state.
function storyRows(sections) {
  var out = []
  for (var i = 0; i < (sections || []).length; i++) {
    var section = sections[i]
    out.push({ kind: "header", title: section.heading, story: null, showState: false })
    for (var j = 0; j < section.stories.length; j++) {
      var story = section.stories[j]
      out.push({ kind: "story", title: "", story: story,
                 showState: story.stateName !== section.commonState })
    }
  }
  return out
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

// Optimistic, like applyMove above: the edited fields land on the list row
// now, rather than waiting for the next poll to notice.
function applyUpdate(stories, story) {
  return (stories || []).map(function(s) {
    if (!story || s.id !== story.id) return s
    var copy = {}
    for (var k in s) copy[k] = s[k]
    for (var k2 in story) copy[k2] = story[k2]
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
      fallback: 5, min: 1, max: 60 },
    { key: "notifyAssigned", kind: "toggle", label: "Notify when assigned", fallback: true }
  ]},
  { title: "Shortcut", rows: [
    // `dev` rows are for working on the plugin, and only shown then: see
    // settingsPage.
    { key: "demo", kind: "toggle", label: "Demo workspace", fallback: false, dev: true,
      hint: "A made-up workspace; never calls Shortcut" }
  ]}
]

// The settings page. New story beside Solve, then the list beside the bar.
// Shortcut sits under the bar: it is the one switch that is not part of either.
//
// Rows marked `dev` are left out unless `showDev`: the plugin is linked from a
// checkout, or one of them is already on. The second is so a switch nobody can
// see is never left on -- whoever has it on can always turn it off.
function settingsPage(showDev) {
  var order = [["New story", "Stories"], ["Solve", "Bar", "Shortcut"]]
  return order.map(function(names) {
    return names.map(function(name) {
      for (var i = 0; i < SETTINGS.length; i++) {
        if (SETTINGS[i].title !== name) continue
        if (showDev) return SETTINGS[i]
        var rows = SETTINGS[i].rows.filter(function(row) { return !row.dev })
        return rows.length ? { title: SETTINGS[i].title, rows: rows } : null
      }
      return null
    }).filter(function(section) { return section })
  })
}

function showDevSettings(linked, settings) {
  if (linked) return true
  for (var s = 0; s < SETTINGS.length; s++) {
    var rows = SETTINGS[s].rows
    for (var r = 0; r < rows.length; r++)
      if (rows[r].dev && !isDefaultSetting(rows[r], readSetting(settings, rows[r].key))) return true
  }
  return false
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

// ---- Telling you a story arrived.
// A story is news once: unseen, and not told about before. The notified set is
// kept to stories still on the list, like the seen set, so one that leaves and
// comes back is told about again.

var NOTICE_EACH_UP_TO = 3

function newlyAssigned(stories, seenIds, notifiedIds) {
  var told = {}
  var before = notifiedIds || []
  for (var i = 0; i < before.length; i++) told[String(before[i])] = true
  var fresh = unseenStories(stories, seenIds).filter(function(s) { return !told[storyKey(s)] })
  var keep = []
  var list = stories || []
  for (var j = 0; j < list.length; j++) {
    var id = storyKey(list[j])
    if (id === "") continue
    if (told[id] || fresh.indexOf(list[j]) !== -1) keep.push(id)
  }
  return { notify: fresh, notified: keep }
}

// What the notification says, and what clicking it runs: the same summon the
// bar sends. A handful at once is one notification each; more than that is one
// for all of them, which opens the list rather than any single story.
function assignedNotices(stories, pluginId) {
  var list = stories || []
  var summon = function(payload) {
    return ["omarchy-shell", "shell", "summon", String(pluginId), JSON.stringify(payload)]
  }
  if (list.length > NOTICE_EACH_UP_TO) {
    return [{ summary: list.length + " stories assigned to you",
              body: list.slice(0, NOTICE_EACH_UP_TO).map(function(s) { return noticeText(s.name) }).join("\n") + "\n…",
              glyph: storyGlyph("feature"),
              argv: summon({ mode: "mine" }) }]
  }
  return list.map(function(s) {
    return { summary: "Assigned to you",
             body: "sc-" + storyKey(s) + " · " + noticeText(s.name),
             glyph: storyGlyph(s.storyType),
             argv: summon({ mode: "mine", story: Number(storyKey(s)) }) }
  })
}

// The notify-send line for one notice. Critical, because it is the only
// urgency Omarchy leaves on screen until you dismiss it: anything else is gone
// within half a minute, and a story you were away for is exactly the one to
// keep. Sent under the plugin's own name, so Do Not Disturb still holds it.
function noticeCommand(notice) {
  return ["notify-send", "-a", "Shortcut Stories", "-u", "critical",
          "-h", "string:omarchy-exec-argv:" + JSON.stringify(notice.argv),
          "-h", "string:omarchy-glyph:" + str(notice.glyph),
          notice.summary, notice.body]
}

// Omarchy draws a notification body as markup, so a story called
// "Fix <Button> padding" would lose its middle. Escaped, it reads as written.
function noticeText(text) {
  return str(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// ---- Where the panel stands.
// A place is the card's top-left corner on its screen, in the screen's own
// logical pixels. No place means the middle. Places are kept per screen, by
// Hyprland's name for it, and are clamped whenever they are used rather than
// when they are stored: a screen can change size underneath one.

function clampPlace(place, screenW, screenH, cardW, cardH) {
  var maxX = Math.max(0, screenW - cardW)
  var maxY = Math.max(0, screenH - cardH)
  if (!place || !isFinite(place.x) || !isFinite(place.y))
    return { x: Math.round(maxX / 2), y: Math.round(maxY / 2) }
  return { x: Math.round(Math.min(Math.max(0, place.x), maxX)),
           y: Math.round(Math.min(Math.max(0, place.y), maxY)) }
}

function placeOn(places, screenName) {
  var p = places && screenName ? places[String(screenName)] : null
  return p && isFinite(p.x) && isFinite(p.y) ? { x: Number(p.x), y: Number(p.y) } : null
}

// A new map rather than an edit, so QML notices. A null place forgets the
// screen's, which puts the card back in the middle.
function withPlace(places, screenName, place) {
  var out = {}
  for (var k in (places || {})) if (k !== String(screenName)) out[k] = places[k]
  if (place) out[String(screenName)] = { x: Math.round(place.x), y: Math.round(place.y) }
  return out
}

// The monitor under a point in Hyprland's layout, and the point on it. Layout
// coordinates are logical, a monitor's width and height are not: divide by its
// scale, and swap them when it is turned on its side.
function monitorAt(monitors, x, y) {
  var list = monitors || []
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    var scale = Number(m.scale) || 1
    var turned = (Number(m.transform) || 0) % 2 === 1
    var w = (turned ? m.height : m.width) / scale
    var h = (turned ? m.width : m.height) / scale
    if (x >= m.x && x < m.x + w && y >= m.y && y < m.y + h)
      return { name: String(m.name), x: x - m.x, y: y - m.y, width: w, height: h }
  }
  return null
}

// Where a drag let go that ended on another screen: the card goes with the
// pointer, held where it was grabbed. Null while the pointer is still on the
// card's own screen, or on none that Hyprland knows.
function dropOnScreen(answer, fromScreen, grabX, grabY) {
  if (!answer || !answer.cursor) return null
  var at = monitorAt(answer.monitors, Number(answer.cursor.x), Number(answer.cursor.y))
  if (!at || at.name === String(fromScreen)) return null
  return { screen: at.name, place: { x: at.x - grabX, y: at.y - grabY } }
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

// ---- where Solve has got to.
// bin/solve status lists every agent Solve started, by story. These turn one
// of those into the line an open story shows, so the view holds no rules.

function solveAgentFor(status, storyId) {
  var list = (status && status.agents) || []
  var wanted = solveId(storyId)
  if (!wanted) return null
  for (var i = 0; i < list.length; i++)
    if (solveId(list[i] && list[i].storyId) === wanted) return list[i]
  return null
}

// Herdr's word for the agent, in the panel's. Waiting and finished both want
// you back, which is what attention marks; working does not.
function solveAgentState(status) {
  switch (str(status)) {
    case "working": return { label: "Agent working", attention: false }
    case "blocked": return { label: "Agent waiting for you", attention: true }
    case "idle":
    case "done": return { label: "Agent finished", attention: true }
    default: return { label: "Agent in Herdr", attention: false }
  }
}

function solveBranchLabel(branch) {
  if (!branch || branch.repo !== true) return ""
  var name = str(branch.name)
  if (branch.exists !== true) return "no " + name + " yet"
  var parts = [name]
  var ahead = branch.ahead
  if (typeof ahead === "number") parts.push(ahead === 0 ? "no commits yet" : ahead + (ahead === 1 ? " commit" : " commits"))
  if (branch.dirty === true) parts.push("uncommitted changes")
  return parts.join(" · ")
}

// The whole line for one open story, or null when no agent has it.
function solveProgress(status, storyId) {
  var agent = solveAgentFor(status, storyId)
  if (!agent) return null
  var state = solveAgentState(agent.status)
  var branch = solveBranchLabel(agent.branch)
  return {
    label: branch ? state.label + " · " + branch : state.label,
    attention: state.attention,
    status: str(agent.status)
  }
}

// Which Solve agents want you back and have not been looked at since they
// got there. Waiting and finished both count; working does not. An agent
// whose pane has focus in Herdr is being looked at already. acked maps an
// agent's name to the state_change_seq it was last seen at, so an agent that
// goes back to work and then stops again counts again.
function solveNeedsYou(status, acked) {
  var list = (status && status.agents) || []
  var seen = acked || {}
  return list.filter(function(a) {
    if (!a || !solveAgentState(a.status).attention) return false
    if (a.focused === true) return false
    return seen[str(a.name)] !== a.seq
  })
}

// acked brought up to date against a fresh status: agents that are gone are
// forgotten, and every agent that is focused, or whose story id is in
// lookedAt, is marked seen at the state it is in now.
function solveAcks(acked, status, lookedAt) {
  var list = (status && status.agents) || []
  var ids = (lookedAt || []).map(solveId)
  var next = {}
  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    if (!a) continue
    var name = str(a.name)
    if (a.focused === true || ids.indexOf(solveId(a.storyId)) !== -1) next[name] = a.seq
    else if (acked && Object.prototype.hasOwnProperty.call(acked, name)) next[name] = acked[name]
  }
  return next
}

// What the bar needs: how many are waiting, how many finished, and the story
// a click should open -- a waiting one before a finished one, since a
// blocked agent is stuck until you answer and a finished one is not.
function solveBarStatus(status, acked) {
  var list = solveNeedsYou(status, acked)
  var waiting = list.filter(function(a) { return str(a.status) === "blocked" })
  var finished = list.filter(function(a) { return str(a.status) !== "blocked" })
  var first = waiting.length ? waiting[0] : (finished.length ? finished[0] : null)
  return {
    waiting: waiting.length,
    finished: finished.length,
    storyId: first ? first.storyId : null
  }
}

// Where to look for a story's pull request: the link on the story when it
// has one, since someone put it there on purpose; otherwise the sc-<id>
// branch, from the directory of the agent working on it. null when there is
// nowhere to look -- no link, and no branch yet.
function prLookupFor(detail, status) {
  if (!detail) return null
  var linked = parseGithubPrUrl(firstPrLink(detail.externalLinks))
  if (linked) return { url: linked.url }
  var agent = solveAgentFor(status, detail.id)
  if (agent && agent.branch && agent.branch.exists === true && str(agent.cwd) !== "")
    return { branch: str(agent.branch.name), dir: str(agent.cwd) }
  return null
}

// One line for a pull request, and whether it wants something from you.
// Checks and reviews only matter while it is open; merged or closed says it
// all. bad is red (a check failed, or changes were asked for), good is the
// accent (merged, or approved with nothing failing or still running).
function prStatusLabel(pr) {
  if (!pr) return null
  var state = str(pr.state)
  var parts = ["PR #" + str(pr.number)]
  var tone = "neutral"
  if (state === "merged") { parts.push("merged"); tone = "good" }
  else if (state === "closed") parts.push("closed")
  else {
    parts.push(pr.draft === true ? "draft" : "open")
    var checks = { passing: "checks passing", failing: "checks failing", pending: "checks running" }[str(pr.checks)]
    if (checks) parts.push(checks)
    var review = { approved: "approved", changes_requested: "changes requested",
                   review_required: "waiting for review" }[str(pr.review)]
    if (review) parts.push(review)
    if (pr.checks === "failing" || pr.review === "changes_requested") tone = "bad"
    else if (pr.review === "approved" && pr.checks !== "pending") tone = "good"
  }
  // summary is the same without the number, for beside a link that has it.
  return { label: parts.join(" · "), summary: parts.slice(1).join(" · "), tone: tone, url: str(pr.url) }
}

// ---- opening the pull request.

// Whether Alt+P has anything to do, and if not, the one reason why -- said
// in the panel rather than leaving a key that silently does nothing.
//
// known is whether GitHub has answered the question "is there a PR already"
// for this branch; false means the answer is still coming. Left out, the PR
// passed in is taken as the answer.
function prOpenable(status, detail, pr, known) {
  if (!detail) return { ok: false, reason: "" }
  if (pr) return { ok: false, reason: "It already has PR #" + str(pr.number) }
  var agent = solveAgentFor(status, detail.id)
  var branch = solveBranch(detail.id)
  if (!agent) return { ok: false, reason: "No agent has " + branch + " — Alt+A starts one" }
  var b = agent.branch
  if (!b || b.repo !== true) return { ok: false, reason: "The agent is not working in a git repository" }
  if (b.exists !== true) return { ok: false, reason: "There is no " + branch + " branch yet" }
  if (b.ahead === 0) return { ok: false, reason: branch + " has no commits yet" }
  if (known === false) return { ok: false, reason: "GitHub has not said yet whether " + branch + " has a pull request" }
  return { ok: true, reason: "" }
}

// What the review screen starts with. The title is the story's name -- a PR
// titled after the work it does. The body links back to the story; the ref
// in it is also what Shortcut's GitHub integration looks for. base is the
// branch it was counted against, without the remote in front, or empty to
// let GitHub use the repository's default.
function prDraft(detail, status) {
  var agent = solveAgentFor(status, detail && detail.id)
  var b = (agent && agent.branch) || {}
  var branch = solveBranch(detail && detail.id)
  var url = str(detail && detail.appUrl)
  return {
    dir: str(agent && agent.cwd),
    branch: branch,
    base: str(b.base).replace(/^origin\//, ""),
    title: trim(detail && detail.name),
    body: "Shortcut story " + (url ? "[" + branch + "](" + url + ")" : branch) + ".",
    draft: false,
    ahead: typeof b.ahead === "number" ? b.ahead : null,
    dirty: b.dirty === true
  }
}

// The story's links with the new PR added, once. Every link it already had
// stays, in its place.
function withPrLink(links, url) {
  var list = (links || []).slice()
  var added = parseGithubPrUrl(url)
  var want = added ? added.url : trim(url)
  if (want === "") return list
  for (var i = 0; i < list.length; i++) {
    var have = parseGithubPrUrl(list[i])
    if ((have ? have.url : trim(list[i])) === want) return list
  }
  list.push(want)
  return list
}

// Where the story probably goes once its PR is up: the next in-progress
// state after the one it is in, in its own workflow -- Code Review after
// In Development, say. null when there is none; the panel then suggests
// nothing rather than guess at done.
function stateAfterPr(refs, detail) {
  var states = statesForStory(refs, detail)
  var at = -1
  for (var i = 0; i < states.length; i++) if (states[i].id === (detail && detail.workflowStateId)) at = i
  if (at < 0) return null
  for (var j = at + 1; j < states.length; j++) if (str(states[j].type) === "started") return states[j]
  return null
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
    parseGithubPrUrl: parseGithubPrUrl, prSourceLabel: prSourceLabel, firstPrLink: firstPrLink,
    prRefLabel: prRefLabel,
    applyPrToForm: applyPrToForm,
    buildCreateRequest: buildCreateRequest, draftIsDirty: draftIsDirty,
    formFromDetail: formFromDetail, buildUpdateRequest: buildUpdateRequest,
    editFormDirty: editFormDirty,
    clearForm: clearForm, destinationLabel: destinationLabel,
    summarizeStory: summarizeStory, storyComments: storyComments,
    storyDetail: storyDetail,
    detailFacts: detailFacts, sectionStories: sectionStories,
    sectionTitle: sectionTitle,
    currentIterations: currentIterations, currentIterationLabel: currentIterationLabel,
    storiesInScope: storiesInScope,
    applyMove: applyMove, applyUpdate: applyUpdate,
    prependCreated: prependCreated, relativeTime: relativeTime,
    SETTINGS: SETTINGS, settingsPage: settingsPage, settingRow: settingRow, choiceList: choiceList,
    coerceSetting: coerceSetting, readSetting: readSetting,
    isDefaultSetting: isDefaultSetting, nextEntry: nextEntry, showDevSettings: showDevSettings,
    hasCustomSettings: hasCustomSettings, toggleChoice: toggleChoice,
    sectionWeight: sectionWeight, settingsColumns: settingsColumns,
    entryFor: entryFor, settingsSummary: settingsSummary, barLabel: barLabel,
    openCount: openCount, startedCount: startedCount,
    storyKey: storyKey, unseenStories: unseenStories, unseenCount: unseenCount,
    newlyAssigned: newlyAssigned, assignedNotices: assignedNotices, noticeText: noticeText, noticeCommand: noticeCommand,
    clampPlace: clampPlace, placeOn: placeOn, withPlace: withPlace,
    monitorAt: monitorAt, dropOnScreen: dropOnScreen,
    noteSeen: noteSeen, seenIdsOf: seenIdsOf, sameIds: sameIds,
    settingOptions: settingOptions, resolveTeamSetting: resolveTeamSetting,
    resolveOwnerSetting: resolveOwnerSetting,
    ownerList: ownerList, addOwner: addOwner, removeOwner: removeOwner,
    ownerChips: ownerChips, ownerAddOptions: ownerAddOptions,
    fileList: fileList, addFiles: addFiles, removeFile: removeFile, withScreenshots: withScreenshots,
    composeEscape: composeEscape, cameFrom: cameFrom,
    commonStateName: commonStateName, storyRows: storyRows, linkChips: linkChips,
    moveNotice: moveNotice, movedBackNotice: movedBackNotice, keyHelp: keyHelp,
    editBase: editBase, buildUpdatePatch: buildUpdatePatch, resolveIterationSetting: resolveIterationSetting,
    SOLVE_PROMPT_LIMIT: SOLVE_PROMPT_LIMIT,
    solveAgentName: solveAgentName, solveBranch: solveBranch,
    workspaceByLabel: workspaceByLabel, solveTarget: solveTarget,
    suggestWorkspace: suggestWorkspace, solveHaystack: solveHaystack,
    solvePrompt: solvePrompt, solveCaption: solveCaption,
    solveAgentFor: solveAgentFor, solveAgentState: solveAgentState,
    solveBranchLabel: solveBranchLabel, solveProgress: solveProgress,
    solveNeedsYou: solveNeedsYou, solveAcks: solveAcks, solveBarStatus: solveBarStatus,
    prLookupFor: prLookupFor, prStatusLabel: prStatusLabel,
    prOpenable: prOpenable, prDraft: prDraft, withPrLink: withPrLink, stateAfterPr: stateAfterPr
  }
}
