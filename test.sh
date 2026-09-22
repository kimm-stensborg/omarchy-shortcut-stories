#!/bin/bash
# Tests for bin/shortcut against a local mock of the Shortcut API, for the pure
# helpers in Model.js under node, and for the QML files under qmllint. Nothing
# here reaches the real API, the keyring, or your stored token.
#
# Run: ./test.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$DIR/bin/shortcut"
WORK=$(mktemp -d)
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
clip() { local t=${1//$'\n'/ }; (( ${#t} > 120 )) && printf '%s…' "${t:0:120}" || printf '%s' "$t"; }
no()   { FAIL=$((FAIL+1)); printf '  ✗ %s\n     want: %s\n     got:  %s\n' "$1" "$(clip "$3")" "$(clip "$2")" >&2; }
is()   { [[ $2 == "$3" ]] && ok "$1" || no "$1" "$2" "$3"; }
has()  { [[ $2 == *"$3"* ]] && ok "$1" || no "$1" "contains: $3" "$2"; }
hasnt(){ [[ $2 != *"$3"* ]] && ok "$1" || no "$1" "must not contain: $3" "$2"; }

# ---- mock Shortcut: answers from routes.json, logs every request ----------
# The body is logged too, not just the method and path: the whole point of
# whitelisting keys in cmd_create is that a wrong key never reaches the API,
# and only the body proves it.
cat >"$WORK/mock.py" <<'PY'
import http.server, json, os, sys
work = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        token = self.headers.get("Shortcut-Token", "")
        with open(os.path.join(work, "requests.log"), "a") as log:
            log.write(f"{method} {self.path} token={token} body={body}\n")
        with open(os.path.join(work, "routes.json")) as f:
            routes = json.load(f)
        if token != "good-token":
            status, payload = 401, {"message": "Unauthorized"}
        else:
            status, payload = routes.get(f"{method} {self.path.split('?')[0]}", [404, {"message": "Not found"}])
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if status == 429:
            self.send_header("Retry-After", "17")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  self.answer("GET")
    def do_POST(self): self.answer("POST")
    def do_PUT(self):  self.answer("PUT")
    def log_message(self, *args): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(work, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

cat >"$WORK/routes.json" <<'JSON'
{
  "GET /api/v3/member": [200, {"id": "me-uuid", "name": "Kimm Stensborg", "mention_name": "kimm"}],
  "GET /api/v3/groups": [200, [
    {"id": "g1", "name": "Platform", "archived": false, "default_workflow_id": 500, "workflow_ids": [500]},
    {"id": "g2", "name": "Design", "archived": false, "default_workflow_id": 501, "workflow_ids": [501]},
    {"id": "g3", "name": "Old Team", "archived": true, "default_workflow_id": 500, "workflow_ids": [500]}
  ]],
  "GET /api/v3/workflows": [200, [
    {"id": 500, "name": "Engineering", "default_state_id": 5002, "states": [
      {"id": 5003, "name": "In Progress", "type": "started", "position": 2},
      {"id": 5001, "name": "Backlog", "type": "backlog", "position": 0},
      {"id": 5002, "name": "Ready", "type": "unstarted", "position": 1},
      {"id": 5004, "name": "Done", "type": "done", "position": 3}
    ]},
    {"id": 501, "name": "Design", "default_state_id": null, "states": [
      {"id": 5012, "name": "To Design", "type": "unstarted", "position": 1},
      {"id": 5011, "name": "Icebox", "type": "backlog", "position": 0}
    ]}
  ]],
  "GET /api/v3/members": [200, [
    {"id": "me-uuid", "disabled": false, "profile": {"name": "Kimm Stensborg", "mention_name": "kimm"}},
    {"id": "ada-uuid", "disabled": false, "profile": {"name": "Ada Lovelace", "mention_name": "ada"}},
    {"id": "gone-uuid", "disabled": true, "profile": {"name": "Departed", "mention_name": "gone"}}
  ]],
  "GET /api/v3/iterations": [200, [
    {"id": 42, "name": "Sprint 12", "status": "started", "start_date": "2026-09-14", "end_date": "2026-09-28", "group_ids": ["g1"]},
    {"id": 41, "name": "Sprint 11", "status": "done", "start_date": "2026-08-31", "end_date": "2026-09-14", "group_ids": ["g1"]}
  ]],
  "POST /api/v3/stories": [201, {"id": 1234, "name": "Fix the thing", "story_type": "bug",
    "app_url": "https://app.shortcut.com/acme/story/1234", "workflow_state_id": 5002,
    "group_id": "g1", "iteration_id": 42, "updated_at": "2026-09-22T10:00:00Z"}],
  "POST /api/v3/stories/search": [200, [
    {"id": 1234, "name": "Older story", "story_type": "bug", "app_url": "u1",
     "workflow_state_id": 5003, "group_id": "g1", "iteration_id": 42,
     "owner_ids": ["me-uuid"], "updated_at": "2026-09-20T10:00:00Z"},
    {"id": 1235, "name": "Newer story", "story_type": "feature", "app_url": "u2",
     "workflow_state_id": 5002, "group_id": "g1", "iteration_id": 42,
     "owner_ids": ["me-uuid"], "updated_at": "2026-09-21T10:00:00Z"}
  ]],
  "GET /api/v3/stories/1234": [200, {"id": 1234, "name": "Fix the thing", "story_type": "bug",
    "app_url": "https://app.shortcut.com/acme/story/1234", "description": "Body **text**",
    "workflow_state_id": 5003, "group_id": "g1", "iteration_id": 42, "epic_id": null,
    "estimate": 2, "deadline": null, "owner_ids": ["me-uuid"], "requested_by_id": "ada-uuid",
    "labels": [{"id": 1, "name": "regression"}, {"id": 2, "name": "frontend"}],
    "tasks": [{"id": 2, "description": "Second", "complete": false, "position": 1},
              {"id": 1, "description": "First", "complete": true, "position": 0}],
    "comments": [{"id": 1, "deleted": false}, {"id": 2, "deleted": true}, {"id": 3, "deleted": false}],
    "created_at": "2026-09-18T09:00:00Z", "updated_at": "2026-09-21T09:00:00Z"}],
  "PUT /api/v3/stories/1234": [200, {"id": 1234, "name": "Fix the thing", "story_type": "bug",
    "app_url": "https://app.shortcut.com/acme/story/1234", "workflow_state_id": 5004,
    "group_id": "g1", "iteration_id": 42, "owner_ids": ["me-uuid"], "updated_at": "2026-09-22T11:00:00Z"}]
}
JSON

route() { jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' "$WORK/routes.json" >"$WORK/r.tmp" && mv "$WORK/r.tmp" "$WORK/routes.json"; }
unroute() { jq -c --arg k "$1" 'del(.[$k])' "$WORK/routes.json" >"$WORK/r.tmp" && mv "$WORK/r.tmp" "$WORK/routes.json"; }

python3 "$WORK/mock.py" "$WORK" & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 50); do [[ -s $WORK/port ]] && break; sleep 0.1; done
[[ -s $WORK/port ]] || { echo "mock server did not start" >&2; exit 1; }

export SHORTCUT_API="http://127.0.0.1:$(<"$WORK/port")/api/v3" SHORTCUT_NO_KEYRING=1
export XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache"
unset SHORTCUT_TOKEN SHORTCUT_DEMO

s()   { SHORTCUT_TOKEN=good-token "$CLI" "$@" 2>&1; }
log() { cat "$WORK/requests.log" 2>/dev/null; }
reset_log() { : >"$WORK/requests.log"; rm -rf "$WORK/cache"; }

# ---- refs ----------------------------------------------------------------
echo "refs"
reset_log
out=$(s refs)
is "refs succeeds"                "$(jq -r .ok <<<"$out")" "true"
is "the archived team is dropped" "$(jq -r '[.groups[].name] | join(",")' <<<"$out")" "Platform,Design"
is "states come back in order"    "$(jq -r '[.workflows[0].states[].name] | join(",")' <<<"$out")" "Backlog,Ready,In Progress,Done"
is "the disabled member is dropped" "$(jq -r '[.members[].name] | join(",")' <<<"$out")" "Kimm Stensborg,Ada Lovelace"
is "a mention name is carried"    "$(jq -r '.me.mentionName' <<<"$out")" "kimm"
is "a done iteration is dropped"  "$(jq -r '[.iterations[].name] | join(",")' <<<"$out")" "Sprint 12"
is "nothing is partial"           "$(jq -c .partial <<<"$out")" "[]"
is "fresh data is not stale"      "$(jq -r .stale <<<"$out")" "false"
has "the token is sent"           "$(log)" "token=good-token"
is "all five endpoints are read"  "$(log | grep -c 'GET /api/v3/')" "5"

reset_log
s refs >/dev/null
first=$(log | grep -c 'GET /api/v3/')
s refs >/dev/null
is "a second run is served from cache" "$(log | grep -c 'GET /api/v3/')" "$first"

s refs --force >/dev/null
is "--force refetches" "$(( $(log | grep -c 'GET /api/v3/') > first ))" "1"

reset_log
SHORTCUT_REFS_TTL=0 s refs >/dev/null
SHORTCUT_REFS_TTL=0 s refs >/dev/null
is "an expired cache refetches" "$(log | grep -c 'GET /api/v3/')" "10"

# Losing a picker endpoint is noted, not fatal.
reset_log
route "GET /api/v3/iterations" '[500, {"message": "boom"}]'
out=$(s refs)
is "a lost iteration list still succeeds" "$(jq -r .ok <<<"$out")" "true"
is "the loss is recorded"                 "$(jq -c .partial <<<"$out")" '["iterations"]'
is "the iteration list is empty"          "$(jq -c .iterations <<<"$out")" "[]"
route "GET /api/v3/iterations" '[200, [{"id": 42, "name": "Sprint 12", "status": "started", "start_date": "2026-09-14", "end_date": "2026-09-28", "group_ids": ["g1"]}]]'

# Losing a required endpoint is fatal.
reset_log
route "GET /api/v3/groups" '[500, {"message": "boom"}]'
out=$(s refs)
is "a lost team list fails"     "$(jq -r .ok <<<"$out")" "false"
is "and says why"               "$(jq -r .code <<<"$out")" "http"
has "with the server's reason"  "$out" "boom"
route "GET /api/v3/groups" '[200, [{"id": "g1", "name": "Platform", "archived": false, "default_workflow_id": 500, "workflow_ids": [500]}]]'

# ---- tokens and transport ------------------------------------------------
echo "tokens and transport"
reset_log
out=$("$CLI" refs 2>&1)
is "no token is its own failure" "$(jq -r .code <<<"$out")" "notoken"
is "and calls nothing"           "$(log | wc -l)" "0"

out=$(SHORTCUT_TOKEN=wrong-token "$CLI" refs 2>&1)
is "a rejected token says auth"  "$(jq -r .code <<<"$out")" "auth"

reset_log
out=$(SHORTCUT_API="http://127.0.0.1:1/api/v3" s refs 2>&1)
is "an unreachable server says network" "$(jq -r .code <<<"$out")" "network"

reset_log
route "GET /api/v3/member" '[429, {"message": "Too many"}]'
out=$(s refs)
is "a rate limit has its own code" "$(jq -r .code <<<"$out")" "ratelimit"
has "and repeats Retry-After"      "$(jq -r .error <<<"$out")" "17s"
route "GET /api/v3/member" '[200, {"id": "me-uuid", "name": "Kimm Stensborg", "mention_name": "kimm"}]'

# A cached answer beats an error page when the network is the thing that broke.
# The TTL is forced to zero so the refresh is actually attempted; otherwise the
# fresh cache is served without a call and the stale path never runs.
reset_log
s refs >/dev/null
out=$(SHORTCUT_REFS_TTL=0 SHORTCUT_API="http://127.0.0.1:1/api/v3" s refs 2>&1)
is "an unreachable refresh serves the cache" "$(jq -r .ok <<<"$out")" "true"
is "marked stale"                            "$(jq -r .stale <<<"$out")" "true"
has "with a reason"                          "$(jq -r .staleReason <<<"$out")" "unreachable"

# ---- create --------------------------------------------------------------
echo "create"
reset_log
out=$(printf '%s' '{"name":"Fix the thing"}' | s create)
is "a name alone is enough" "$(jq -r .ok <<<"$out")" "true"
is "the story comes back"   "$(jq -r .story.id <<<"$out")" "1234"
is "with its url"           "$(jq -r .story.appUrl <<<"$out")" "https://app.shortcut.com/acme/story/1234"
is "and sends only a name"  "$(log | sed -n 's/.*body=//p' | tail -1)" '{"name":"Fix the thing"}'

reset_log
out=$(printf '%s' '{"name":"  Trim me  ","description":"body text\n\n","storyType":"bug","groupId":"g1","workflowStateId":5002,"iterationId":42,"ownerId":"ada-uuid"}' | s create)
body=$(log | sed -n 's/.*body=//p' | tail -1)
is "a full form succeeds"        "$(jq -r .ok <<<"$out")" "true"
is "the name is trimmed"         "$(jq -r .name <<<"$body")" "Trim me"
is "trailing blank lines go"     "$(jq -r .description <<<"$body")" "body text"
is "the type is renamed"         "$(jq -r .story_type <<<"$body")" "bug"
is "the team is renamed"         "$(jq -r .group_id <<<"$body")" "g1"
is "the state is a number"       "$(jq -r '.workflow_state_id | type' <<<"$body")" "number"
is "the iteration is a number"   "$(jq -r '.iteration_id | type' <<<"$body")" "number"
is "one owner becomes a list"    "$(jq -c .owner_ids <<<"$body")" '["ada-uuid"]'

reset_log
printf '%s' '{"name":"Whitelisted","bogusKey":"dropped","archived":true}' | s create >/dev/null
body=$(log | sed -n 's/.*body=//p' | tail -1)
hasnt "an unknown key never ships" "$body" "bogusKey"
hasnt "and neither does a key we do not offer" "$body" "archived"

reset_log
out=$(printf '%s' '{"name":"   "}' | s create)
is "a blank name is refused"  "$(jq -r .code <<<"$out")" "usage"
out=$(printf '%s' 'not json' | s create)
is "junk on stdin is refused" "$(jq -r .code <<<"$out")" "usage"
is "and neither calls out"    "$(log | wc -l)" "0"

# A description is the whole reason create reads stdin: it is multiline and
# full of the characters a shell would otherwise eat.
reset_log
printf '%s' '{"name":"Shell bait","description":"$(rm -rf /) `whoami` \"quoted\" '"'"'single'"'"' \\ backslash\nsecond line"}' | s create >/dev/null
body=$(log | sed -n 's/.*body=//p' | tail -1)
is "a hostile description survives intact" \
  "$(jq -r .description <<<"$body")" \
  '$(rm -rf /) `whoami` "quoted" '"'"'single'"'"' \ backslash
second line'

reset_log
route "POST /api/v3/stories" '[422, {"errors": {"story_type": "must be one of feature, bug, chore"}}]'
out=$(printf '%s' '{"name":"Bad type","storyType":"epic"}' | s create)
is "a rejected story fails"     "$(jq -r .ok <<<"$out")" "false"
has "with the field named"      "$(jq -r .error <<<"$out")" "story_type"
route "POST /api/v3/stories" '[201, {"id": 1234, "name": "Fix the thing", "story_type": "bug", "app_url": "https://app.shortcut.com/acme/story/1234", "workflow_state_id": 5002, "group_id": "g1", "iteration_id": 42, "updated_at": "2026-09-22T10:00:00Z"}]'

# ---- mine ----------------------------------------------------------------
echo "mine"
reset_log
out=$(s mine)
is "mine succeeds"            "$(jq -r .ok <<<"$out")" "true"
is "it counts what it found"  "$(jq -r .total <<<"$out")" "2"
is "newest first"             "$(jq -r '[.stories[].name] | join(",")' <<<"$out")" "Newer story,Older story"
body=$(log | sed -n 's/.*body=//p' | tail -1)
is "it asks by owner id"      "$(jq -r .owner_id <<<"$body")" "me-uuid"
is "and by open state types"  "$(jq -c .workflow_state_types <<<"$body")" '["backlog","unstarted","started"]'
is "and skips the archived"   "$(jq -r .archived <<<"$body")" "false"
hasnt "it never guesses a mention name" "$body" "kimm"

out=$(s mine --limit 1)
is "--limit trims the list" "$(jq -r '.stories | length' <<<"$out")" "1"
is "but not the count"      "$(jq -r .total <<<"$out")" "2"
out=$(s mine --limit abc)
is "a junk limit is refused" "$(jq -r .code <<<"$out")" "usage"

# ---- move ----------------------------------------------------------------
echo "move"
reset_log
out=$(s move 1234 5004)
is "move succeeds"          "$(jq -r .ok <<<"$out")" "true"
is "the story is in its new state" "$(jq -r .story.workflowStateId <<<"$out")" "5004"
is "it sends only the state" "$(log | sed -n 's/.*body=//p' | tail -1)" '{"workflow_state_id":5004}'

reset_log
out=$(s move abc 5004)
is "a junk story id is refused" "$(jq -r .code <<<"$out")" "usage"
out=$(s move 1234 abc)
is "a junk state id is refused" "$(jq -r .code <<<"$out")" "usage"
is "and neither calls out"      "$(log | wc -l)" "0"

# ---- show ----------------------------------------------------------------
echo "show"
reset_log
out=$(s show 1234)
is "show succeeds"           "$(jq -r .ok <<<"$out")" "true"
is "it brings the description" "$(jq -r .story.description <<<"$out")" "Body **text**"
is "labels come back by name" "$(jq -c .story.labels <<<"$out")" '["regression","frontend"]'
is "tasks are in order"      "$(jq -r '[.story.tasks[].description] | join(",")' <<<"$out")" "First,Second"
is "deleted comments do not count" "$(jq -r .story.commentCount <<<"$out")" "2"
is "the estimate survives"   "$(jq -r .story.estimate <<<"$out")" "2"
is "it asks for the one story" "$(log | grep -c 'GET /api/v3/stories/1234')" "1"

out=$(s show abc)
is "a junk id is refused"    "$(jq -r .code <<<"$out")" "usage"
out=$(s show 9999)
is "an unknown story fails"  "$(jq -r .ok <<<"$out")" "false"

# ---- demo ----------------------------------------------------------------
echo "demo"
reset_log
out=$(SHORTCUT_DEMO=1 "$CLI" refs)
is "demo refs works with no token" "$(jq -r .ok <<<"$out")" "true"
out=$(printf '%s' '{"name":"  demo  "}' | SHORTCUT_DEMO=1 "$CLI" create)
is "demo create works"             "$(jq -r .ok <<<"$out")" "true"
is "and trims like the real one"   "$(jq -r .story.name <<<"$out")" "demo"
SHORTCUT_DEMO=1 "$CLI" mine >/dev/null
SHORTCUT_DEMO=1 "$CLI" move 1 2 >/dev/null
SHORTCUT_DEMO=1 "$CLI" show 1234 >/dev/null
is "demo never calls Shortcut"     "$(log | wc -l)" "0"

# ---- QML ------------------------------------------------------------------
echo "qml"
# The node cases below never touch the .qml files, and omarchy-shell swallows
# the reason a plugin entry point failed to load, so a missing import shows up
# as a panel that silently does not open. qmllint resolves the same imports the
# shell does and says what is wrong.
#
# `qs.Commons` and `qs.Ui` are the shell's own directories, reached through the
# `qs` prefix, so the lint needs an import root where `qs` is the shell.
QMLLINT=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
if [[ ! -x $QMLLINT ]]; then
  echo "  - skipped: no qmllint (pacman -S qt6-declarative)"
else
  mkdir -p "$WORK/imports"
  ln -sfn /usr/share/omarchy/shell "$WORK/imports/qs"
  # `shell`, `manifest` and `service` are injected as plain objects, so every
  # property read off them is unqualified by design; those categories would
  # drown the ones that mean the file will not load.
  lint() { "$QMLLINT" -I "$WORK/imports" \
    --unqualified disable --missing-property disable --uncreatable-type disable "$@" 2>&1; }

  out=$(cd "$DIR" && lint ./*.qml)
  is "every QML file resolves and parses" "$out" ""

  # A check that cannot fail is not a check: drop an import from a copy and the
  # lint has to notice. IpcHandler comes from Quickshell.Io, which is the one
  # this plugin's overlay was first written without.
  cp "$DIR"/*.qml "$DIR/Model.js" "$WORK/"
  sed -i '/^import Quickshell.Io$/d' "$WORK/Overlay.qml"
  out=$(cd "$WORK" && lint ./Overlay.qml)
  has "a missing import is caught" "$out" "IpcHandler was not found"
  rm -f "$WORK"/*.qml "$WORK/Model.js"
fi

# A singleton is reached from JavaScript rather than declared as an element, so
# dropping its import is not a missing type -- qmllint files it under
# `unqualified`, with all the delegate-scope noise the lint above has to
# silence to stay readable. So they are checked by name instead.
missing=""
for f in "$DIR"/*.qml; do
  body=$(grep -v '^import ' "$f")
  for pair in "Quickshell:Quickshell" "Hyprland:Quickshell.Hyprland"; do
    name=${pair%%:*}; needs=${pair##*:}
    grep -qE "(^|[^.A-Za-z_])$name\." <<<"$body" || continue
    grep -qE "^import $needs\$" "$f" || missing="$missing $(basename "$f"):$needs"
  done
done
is "every singleton used is imported" "${missing:- none}" " none"

# The entry points the manifest promises have to be on disk, or the plugin is
# refused at load with no other clue why.
for entry in $(jq -r '.entryPoints[]' "$DIR/manifest.json"); do
  [[ -f "$DIR/$entry" ]] && ok "$entry is where the manifest says" || no "$entry is where the manifest says" "missing" "a file"
done


# ---- Model.js ------------------------------------------------------------
echo "Model.js"
node - "$DIR/Model.js" "$DIR/manifest.json" <<'JS' || FAIL=$((FAIL+1))
const M = require(process.argv[2])
const manifest = require(process.argv[3])

const refs = {
  ok: true, fetchedAt: 1000, stale: false, partial: [],
  me: { id: "me-uuid", name: "Kimm Stensborg", mentionName: "kimm" },
  groups: [
    { id: "g1", name: "Platform", defaultWorkflowId: 500, workflowIds: [500] },
    { id: "g2", name: "Design", defaultWorkflowId: null, workflowIds: [501] },
    { id: "g3", name: "Orphan", defaultWorkflowId: 999, workflowIds: [] }
  ],
  workflows: [
    { id: 500, name: "Engineering", defaultStateId: 5002, states: [
      { id: 5001, name: "Backlog", type: "backlog", position: 0 },
      { id: 5002, name: "Ready", type: "unstarted", position: 1 },
      { id: 5003, name: "In Progress", type: "started", position: 2 },
      { id: 5004, name: "Done", type: "done", position: 3 }]},
    { id: 501, name: "Design", defaultStateId: null, states: [
      { id: 5012, name: "To Design", type: "unstarted", position: 1 },
      { id: 5011, name: "Icebox", type: "backlog", position: 0 }]}
  ],
  members: [
    { id: "ada-uuid", name: "Ada Lovelace", mentionName: "ada" },
    { id: "me-uuid", name: "Kimm Stensborg", mentionName: "kimm" }
  ],
  iterations: [
    { id: 42, name: "Sprint 12", status: "started", startDate: "2026-09-14", endDate: "2026-09-28", groupIds: ["g1"] },
    { id: 43, name: "Sprint 13", status: "unstarted", startDate: "2026-09-28", endDate: "2026-10-12", groupIds: ["g1"] },
    { id: 44, name: "Design cycle", status: "unstarted", startDate: "2026-09-01", endDate: "2026-09-30", groupIds: ["g2"] },
    { id: 45, name: "Workspace wide", status: "unstarted", startDate: "2026-09-20", endDate: "2026-09-24", groupIds: [] }
  ]
}
const TODAY = "2026-09-22"
const labels = (o) => o.map(x => x.label).join(",")
const values = (o) => o.map(x => x.value).join(",")

const cases = [
  // reference lookups
  ["stale when absent",        M.refsAreStale(null, 2000, 100), true],
  ["stale when marked",        M.refsAreStale({ok:true,fetchedAt:2000,stale:true}, 2000, 100), true],
  ["stale at exactly the ttl", M.refsAreStale(refs, 1100, 100), true],
  ["fresh a second before",    M.refsAreStale(refs, 1099, 100), false],
  ["a group is found",         M.findGroup(refs, "g1").name, "Platform"],
  ["an unknown group is null", M.findGroup(refs, "nope"), null],
  ["an empty group is null",   M.findGroup(refs, ""), null],
  ["a state names its workflow", M.findState(refs, 5012).workflow.name, "Design"],
  ["an unknown state is null", M.findState(refs, 1), null],

  // team -> workflow -> state
  ["the default workflow wins", M.workflowForGroup(refs, "g1").name, "Engineering"],
  ["else the first attached",   M.workflowForGroup(refs, "g2").name, "Design"],
  ["a missing workflow is null", M.workflowForGroup(refs, "g3"), null],
  ["no team, no workflow",      M.workflowForGroup(refs, ""), null],
  ["the default state is used", M.defaultStateFor(refs, "g1").stateId, 5002],
  ["else the lowest position",  M.defaultStateFor(refs, "g2").stateId, 5011],
  ["no team, no state",         M.defaultStateFor(refs, ""), null],
  ["an orphan team has no state", M.defaultStateFor(refs, "g3"), null],

  // a story is only ever offered its own workflow's states
  ["states come from the story's workflow",
    M.statesForStory(refs, {workflowStateId: 5012}).map(s => s.name).join(","), "Icebox,To Design"],
  ["and never another workflow's",
    M.statesForStory(refs, {workflowStateId: 5002}).some(s => s.id === 5012), false],
  ["an unknown state offers nothing",
    M.statesForStory(refs, {workflowStateId: 1}).length, 0],

  // pickers
  ["teams lead with none",     M.groupOptions(refs)[0].label, "No team"],
  ["teams sort by name",       labels(M.groupOptions(refs)), "No team,Design,Orphan,Platform"],
  ["empty refs still offer none", M.groupOptions(null).length, 1],
  ["members lead with unassigned", M.memberOptions(refs, "me-uuid")[0].label, "Unassigned"],
  ["then me",                  M.memberOptions(refs, "me-uuid")[1].label, "Me (@kimm)"],
  ["then the rest by name",    labels(M.memberOptions(refs, "me-uuid")), "Unassigned,Me (@kimm),Ada Lovelace"],
  ["an unknown me is not invented", labels(M.memberOptions(refs, "ghost")), "Unassigned,Ada Lovelace,Kimm Stensborg"],
  ["nobody is listed twice",   new Set(values(M.memberOptions(refs, "me-uuid")).split(",")).size, 3],

  // iterations
  ["a done iteration is gone", M.iterationOptions(refs, "", TODAY).some(o => o.label.startsWith("Sprint 11")), false],
  ["the current one is first", M.iterationOptions(refs, "g1", TODAY)[1].label, "Sprint 12 · current"],
  ["another team's is hidden", M.iterationOptions(refs, "g1", TODAY).some(o => o.label.startsWith("Design cycle")), false],
  ["but shows with no team",   M.iterationOptions(refs, "", TODAY).some(o => o.label.startsWith("Design cycle")), true],
  ["a workspace-wide one always shows", M.iterationOptions(refs, "g1", TODAY).some(o => o.label.startsWith("Workspace wide")), true],
  ["iterations lead with none", M.iterationOptions(refs, "g1", TODAY)[0].label, "No iteration"],
  ["the list is capped",       M.iterationOptions(refs, "", TODAY, 1).length, 2],
  ["today inside is current",  M.iterationIsCurrent(refs.iterations[0], TODAY), true],
  ["today outside is not",     M.iterationIsCurrent(refs.iterations[1], TODAY), false],

  // story types
  ["three types",              M.storyTypes().length, 3],
  ["named as the API wants",   M.storyTypes().map(t => t.value).join(","), "feature,bug,chore"],
  ["every type has a glyph",   M.storyTypes().every(t => t.glyph.charCodeAt(0) > 0xe000), true],
  ["an unknown type still draws", M.storyGlyph("nonsense"), M.storyTypes()[0].glyph],

  // validation
  ["a name is required",       M.validateForm({name: ""}).ok, false],
  ["whitespace is not a name", M.validateForm({name: "   "}).ok, false],
  ["one character will do",    M.validateForm({name: "x"}).ok, true],
  ["512 is the limit",         M.validateForm({name: "x".repeat(513)}).ok, false],

  // the create body
  ["a name alone posts a name alone",
    JSON.stringify(M.buildCreateRequest({name: "  Hi  "}, refs)), '{"name":"Hi","storyType":"feature"}'],
  ["a blank description is left out",
    M.buildCreateRequest({name: "x", description: "  "}, refs).description, undefined],
  ["trailing blank lines go",
    M.buildCreateRequest({name: "x", description: "body\n\n"}, refs).description, "body"],
  ["a team resolves its state",
    M.buildCreateRequest({name: "x", groupId: "g1"}, refs).workflowStateId, 5002],
  ["no team sends no state",
    M.buildCreateRequest({name: "x", groupId: ""}, refs).workflowStateId, undefined],
  ["and no team either",
    M.buildCreateRequest({name: "x", groupId: ""}, refs).groupId, undefined],
  ["an unresolvable team sends no state",
    M.buildCreateRequest({name: "x", groupId: "g3"}, refs).workflowStateId, undefined],
  ["but still names the team",
    M.buildCreateRequest({name: "x", groupId: "g3"}, refs).groupId, "g3"],
  ["an iteration becomes a number",
    M.buildCreateRequest({name: "x", iterationId: "42"}, refs).iterationId, 42],
  ["a blank iteration is left out",
    M.buildCreateRequest({name: "x", iterationId: ""}, refs).iterationId, undefined],
  ["an owner is carried",
    M.buildCreateRequest({name: "x", ownerId: "me-uuid"}, refs).ownerId, "me-uuid"],
  ["a blank owner is left out",
    M.buildCreateRequest({name: "x", ownerId: ""}, refs).ownerId, undefined],

  // the draft
  ["a fresh form is clean",    M.draftIsDirty(M.emptyForm()), false],
  ["spaces are not a draft",   M.draftIsDirty({name: "  ", description: "", storyType: "feature", groupId: "", iterationId: "", ownerId: ""}), false],
  ["a title is a draft",       M.draftIsDirty({name: "x", description: "", storyType: "feature", groupId: "", iterationId: "", ownerId: ""}), true],
  ["so is a changed type",     M.draftIsDirty({name: "", description: "", storyType: "bug", groupId: "", iterationId: "", ownerId: ""}), true],
  ["a default is not a draft", M.draftIsDirty(M.emptyForm({storyType: "bug", groupId: "g1"}), {storyType: "bug", groupId: "g1"}), false],
  ["sticky keeps the team",    M.clearForm({name: "x", groupId: "g1", iterationId: "42", ownerId: "me-uuid"}, {}, true).groupId, "g1"],
  ["and drops the title",      M.clearForm({name: "x", groupId: "g1"}, {}, true).name, ""],
  ["unsticky drops the team",  M.clearForm({name: "x", groupId: "g1"}, {}, false).groupId, ""],

  // where it lands
  ["the destination is named", M.destinationLabel({groupId: "g1"}, refs), "Platform → Ready"],
  ["no team says so",          M.destinationLabel({groupId: ""}, refs), "Your workspace's default workflow"],

  // the story list
  ["a story knows its state",  M.summarizeStory({id: 1, workflowStateId: 5003}, refs).stateName, "In Progress"],
  ["and its reference",        M.summarizeStory({id: 1234}, refs).ref, "sc-1234"],
  ["an unknown state reads Unknown", M.summarizeStory({id: 1, workflowStateId: 9}, refs).stateName, "Unknown"],
  ["a team name is resolved",  M.summarizeStory({id: 1, groupId: "g1"}, refs).groupName, "Platform"],
  ["an iteration name too",    M.summarizeStory({id: 1, iterationId: 42}, refs).iterationName, "Sprint 12"],
]

const stories = [
  { id: 1, name: "A", workflowStateId: 5002, updatedAt: "2026-09-20T10:00:00Z" },
  { id: 2, name: "B", workflowStateId: 5003, updatedAt: "2026-09-21T10:00:00Z" },
  { id: 3, name: "C", workflowStateId: 5004, updatedAt: "2026-09-19T10:00:00Z" },
  { id: 4, name: "D", workflowStateId: 5002, updatedAt: "2026-09-22T10:00:00Z" }
]
cases.push(
  ["in progress comes first", M.sectionStories(stories, refs, false)[0].title, "In progress"],
  ["done is hidden by default", M.sectionStories(stories, refs, false).some(s => s.type === "done"), false],
  ["and shown when asked",    M.sectionStories(stories, refs, true).some(s => s.type === "done"), true],
  ["and comes last",          M.sectionStories(stories, refs, true).slice(-1)[0].title, "Done"],
  ["newest first inside a section",
    M.sectionStories(stories, refs, false)[1].stories.map(s => s.name).join(","), "D,A"],
  ["an empty list has no sections", M.sectionStories([], refs, true).length, 0],
  ["a story in no known state is still shown",
    M.sectionStories([{id: 9, name: "Z", workflowStateId: 7}], refs, false)[0].title, "Elsewhere"],
  ["a move does not touch the input",
    (() => { const before = JSON.stringify(stories); M.applyMove(stories, 1, 5004); return JSON.stringify(stories) === before })(), true],
  ["a move lands",            M.applyMove(stories, 1, 5004).find(s => s.id === 1).workflowStateId, 5004],
  ["a move to nothing is a no-op",
    JSON.stringify(M.applyMove(stories, 99, 5004)), JSON.stringify(stories)],
  ["a new story goes on top", M.prependCreated(stories, {id: 5, name: "E"})[0].name, "E"],
  ["and is never doubled",    M.prependCreated(stories, {id: 1, name: "A again"}).filter(s => s.id === 1).length, 1],
  ["just now",                M.relativeTime("2026-09-22T10:00:00Z", Date.parse("2026-09-22T10:00:30Z") / 1000), "just now"],
  ["minutes",                 M.relativeTime("2026-09-22T10:00:00Z", Date.parse("2026-09-22T10:04:00Z") / 1000), "4 min ago"],
  ["one hour reads singular", M.relativeTime("2026-09-22T10:00:00Z", Date.parse("2026-09-22T11:00:00Z") / 1000), "1 hour ago"],
  ["days",                    M.relativeTime("2026-09-19T10:00:00Z", Date.parse("2026-09-22T10:00:00Z") / 1000), "3 days ago"],
  ["no time reads empty",     M.relativeTime(null, 0), ""],

  // the bar label
  // stories[] holds four, one of which sits in a done state.
  ["the count leaves out what is done", M.barLabel(stories, refs, "count"), "3"],
  ["openCount agrees with it",  M.openCount(stories, refs), 3],
  ["startedCount counts only those", M.startedCount(stories, refs), 1],
  ["a story in an unknown state still counts", M.openCount([{workflowStateId: 7}], refs), 1],
  ["started counts only those", M.barLabel(stories, refs, "started"), "1"],
  ["none is empty",           M.barLabel(stories, refs, "none"), ""],
  ["an empty list shows nothing", M.barLabel([], refs, "count"), ""],

  // settings
  ["every option has a kind", M.SETTINGS.every(s => s.rows.every(r => ["text","number","toggle","choice","multi","picker"].includes(r.kind))), true],
  ["every key is unique",     (() => { const k = M.SETTINGS.flatMap(s => s.rows.map(r => r.key)); return k.length === new Set(k).size })(), true],
  ["a missing value reads its default", M.readSetting({}, "barLabel"), "count"],
  ["a wrong value reads its default",   M.readSetting({barLabel: "nonsense"}, "barLabel"), "count"],
  ["a number is clamped",     M.readSetting({refreshMinutes: 999}, "refreshMinutes"), 60],
  ["a word reads as a toggle", M.readSetting({showDone: "on"}, "showDone"), true],
  ["the default is not written", JSON.stringify(M.nextEntry({id: "x"}, "x", {barLabel: "count"})), '{"id":"x"}'],
  ["a change is written",     M.nextEntry({id: "x"}, "x", {barLabel: "none"}).barLabel, "none"],
  ["reset keeps the id",      JSON.stringify(M.nextEntry({id: "x", barLabel: "none"}, "x", null)), '{"id":"x"}'],
  ["reset spares others",     M.nextEntry({id: "x", barLabel: "none", section: "right"}, "x", null).section, "right"],
  ["columns lose nothing",    M.settingsColumns(3).flat().length, M.SETTINGS.length],
  ["no column is empty",      M.settingsColumns(3).every(c => c.length > 0), true],
  ["an entry is found in any section",
    M.entryFor({layout: {right: [{id: "io.github.kimm-stensborg.shortcut-stories", barLabel: "none"}]}}, "io.github.kimm-stensborg.shortcut-stories").barLabel, "none"],
  ["a clone's entry counts",
    M.entryFor({layout: {left: [{id: "io.github.kimm-stensborg.shortcut-stories#2"}]}}, "io.github.kimm-stensborg.shortcut-stories").id, "io.github.kimm-stensborg.shortcut-stories#2"],

  // the detail view
  ["a detail resolves its owner",
    M.storyDetail({id:1,ownerIds:["me-uuid"]}, refs).ownerLabel, "Kimm Stensborg"],
  ["several owners read as a list",
    M.storyDetail({id:1,ownerIds:["me-uuid","ada-uuid"]}, refs).ownerLabel, "Kimm Stensborg, Ada Lovelace"],
  ["nobody reads as unassigned",
    M.storyDetail({id:1,ownerIds:[]}, refs).ownerLabel, "Unassigned"],
  ["a departed owner is not a crash",
    M.storyDetail({id:1,ownerIds:["ghost"]}, refs).ownerLabel, "Someone who has left"],
  ["the requester is named",
    M.storyDetail({id:1,requestedById:"ada-uuid"}, refs).requesterName, "Ada Lovelace"],
  ["tasks are counted",
    M.storyDetail({id:1,tasks:[{complete:true},{complete:false},{complete:true}]}, refs).taskLabel, "2 of 3 done"],
  ["no tasks says nothing",
    M.storyDetail({id:1,tasks:[]}, refs).taskLabel, ""],
  ["one point is singular",
    M.storyDetail({id:1,estimate:1}, refs).estimateLabel, "1 point"],
  ["more are plural",
    M.storyDetail({id:1,estimate:5}, refs).estimateLabel, "5 points"],
  ["an unestimated story says nothing",
    M.storyDetail({id:1,estimate:null}, refs).estimateLabel, ""],
  ["a deadline is trimmed to a date",
    M.storyDetail({id:1,deadline:"2026-10-01T00:00:00Z"}, refs).deadline, "2026-10-01"],
  ["a missing description is empty, not undefined",
    M.storyDetail({id:1}, refs).description, ""],
  ["a detail still knows its state",
    M.storyDetail({id:1,workflowStateId:5003}, refs).stateName, "In Progress"],
  ["no story, no detail", M.storyDetail(null, refs), null],

  // the facts list leaves out what is not there
  ["empty facts are dropped",
    M.detailFacts(M.storyDetail({id:1,workflowStateId:5003}, refs)).map(f => f.label).join(","),
    "State,Owner"],
  ["a full story lists them all",
    M.detailFacts(M.storyDetail({id:1,workflowStateId:5003,groupId:"g1",iterationId:42,
      ownerIds:["me-uuid"],requestedById:"ada-uuid",estimate:2,deadline:"2026-10-01",
      labels:["a"],tasks:[{complete:true}]}, refs)).map(f => f.label).join(","),
    "State,Team,Iteration,Owner,Requested by,Estimate,Deadline,Labels,Tasks"],
  ["no detail, no facts", M.detailFacts(null).length, 0],

  // defaults for a new story, set from the workspace
  ["a team resolves from its id",   M.resolveTeamSetting(refs, "g1"), "g1"],
  ["and from its name",             M.resolveTeamSetting(refs, "Platform"), "g1"],
  ["whatever the case",             M.resolveTeamSetting(refs, "pLaTfOrM"), "g1"],
  ["a team that is gone reads unset", M.resolveTeamSetting(refs, "vanished"), ""],
  ["no team stays no team",         M.resolveTeamSetting(refs, ""), ""],
  ["me follows the account",        M.resolveOwnerSetting(refs, "me"), "me-uuid"],
  ["a named colleague is kept",     M.resolveOwnerSetting(refs, "ada-uuid"), "ada-uuid"],
  ["someone who has left reads unset", M.resolveOwnerSetting(refs, "ghost"), ""],
  ["unassigned stays unassigned",   M.resolveOwnerSetting(refs, ""), ""],
  ["current finds today's sprint",  M.resolveIterationSetting(refs, "current", "g1", TODAY), "42"],
  ["current works per team",        M.resolveIterationSetting(refs, "current", "g2", TODAY), "44"],
  ["current with nothing running reads unset",
    M.resolveIterationSetting(refs, "current", "g1", "2027-01-01"), ""],
  ["a pinned sprint is kept",       M.resolveIterationSetting(refs, "43", "g1", TODAY), "43"],
  ["a sprint on another team is dropped",
    M.resolveIterationSetting(refs, "44", "g1", TODAY), ""],
  ["a finished sprint is dropped",  M.resolveIterationSetting(refs, "41", "g1", TODAY), ""],
  ["no iteration stays none",       M.resolveIterationSetting(refs, "", "g1", TODAY), ""],

  // what the settings page offers
  ["the team picker leads with none",
    M.settingOptions(M.settingRow("defaultTeam"), refs, TODAY)[0].label, "No team"],
  ["and lists the teams",
    M.settingOptions(M.settingRow("defaultTeam"), refs, TODAY).length, 4],
  ["the owner picker leads with unassigned then me",
    M.settingOptions(M.settingRow("defaultOwner"), refs, TODAY).slice(0, 2).map(o => o.label).join(","),
    "Unassigned,Me"],
  ["and does not list me twice",
    M.settingOptions(M.settingRow("defaultOwner"), refs, TODAY).filter(o => o.value === "me-uuid").length, 0],
  ["the iteration picker offers the current one",
    M.settingOptions(M.settingRow("defaultIteration"), refs, TODAY)[1].value, "current"],
  ["and narrows to the team given",
    M.settingOptions(M.settingRow("defaultIteration"), refs, TODAY, "g1")
      .some(o => o.label.indexOf("Design cycle") === 0), false],
  ["a choice row keeps its own options",
    M.settingOptions(M.settingRow("defaultType"), refs, TODAY).length, 3],
  ["no row, no options", M.settingOptions(null, refs, TODAY).length, 0],

  // the manifest schema and Model.SETTINGS are two copies of one list, because
  // the shell reads one and the settings page reads the other. Nothing but a
  // test keeps them honest.
  ["the manifest offers every setting",
    M.SETTINGS.flatMap(s => s.rows.map(r => r.key)).filter(k => !manifest.barWidget.schema.some(e => e.key === k)).join(","), ""],
  ["and invents none",
    manifest.barWidget.schema.map(e => e.key).filter(k => !M.settingRow(k)).join(","), ""],
  ["with the same defaults",
    manifest.barWidget.schema.filter(e => {
      const row = M.settingRow(e.key)
      const mine = e.defaultValue === undefined ? "" : e.defaultValue
      const theirs = row.kind === "toggle" ? (row.fallback ? "on" : "off") : row.fallback
      if (row.kind === "picker" && e.type !== "string") return true
      return String(mine) !== String(theirs)
    }).map(e => e.key).join(","), ""]
)

let failed = 0
for (const [name, got, want] of cases) {
  const same = typeof got === "object" || typeof want === "object"
    ? JSON.stringify(got) === JSON.stringify(want)
    : got === want
  if (same) console.log("  ✓ " + name)
  else { failed++; console.error(`  ✗ ${name}\n     want: ${JSON.stringify(want)}\n     got:  ${JSON.stringify(got)}`) }
}
console.log(`\n  ${cases.length - failed} Model.js cases passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
JS


echo
echo "$PASS shell checks passed, $FAIL failed"
(( FAIL == 0 ))
