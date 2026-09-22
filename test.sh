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
    "comments": [
      {"id": 3, "deleted": false, "author_id": "ada-uuid", "text": "On it", "created_at": "2026-09-20T11:00:00Z", "position": 2, "parent_id": 1, "blocker": true},
      {"id": 1, "deleted": false, "author_id": "me-uuid", "text": "Seen it too", "created_at": "2026-09-19T11:00:00Z", "position": 1, "parent_id": null},
      {"id": 2, "deleted": true, "author_id": "me-uuid", "text": "Forget this", "position": 3},
      {"id": 4, "deleted": false, "author_id": "me-uuid", "text": "   ", "position": 4}
    ],
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
is "comments are oldest first" "$(jq -r '[.story.comments[].text] | join(",")' <<<"$out")" "Seen it too,On it"
is "a reply keeps its parent" "$(jq -r '.story.comments[1].parentId' <<<"$out")" "1"
is "the author is kept"       "$(jq -r .story.comments[0].authorId <<<"$out")" "me-uuid"
is "a blocker is marked"      "$(jq -r .story.comments[1].blocker <<<"$out")" "true"
is "deleted comments do not count" "$(jq -r .story.commentCount <<<"$out")" "2"
is "a blank comment is left out" "$(jq -r '.story.comments | length' <<<"$out")" "2"
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
out=$(SHORTCUT_DEMO=1 "$CLI" show 1234)
is "demo show includes the comments" "$(jq -r '[.story.comments[].authorId] | join(",")' <<<"$out")" "demo-ada,demo-me"
is "demo never calls Shortcut"     "$(log | wc -l)" "0"

# ---- solve: Herdr, through a stand-in that records every command ----------
echo "solve"
SOLVE="$DIR/bin/solve"
FIX="$WORK/herdr-fix"
mkdir -p "$FIX" "$WORK/bin"
cat >"$WORK/bin/herdr" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${HERDR_LOG:?}"
case "$1 $2" in
  "workspace list") cat "${HERDR_FIX:?}/workspaces.json"; exit 0 ;;
  "pane list") cat "$HERDR_FIX/panes.json"; exit 0 ;;
  "agent list") cat "$HERDR_FIX/agents.json"; exit 0 ;;
  "agent focus") exit 0 ;;
  "agent start")
    if [[ -n ${HERDR_START_CODE:-} ]]; then
      jq -cn --arg code "$HERDR_START_CODE" '{error: {code: $code, message: "not ready"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"name":"started"}}}'
    exit 0 ;;
  "agent prompt")
    printf '%s' "$4" > "$HERDR_FIX/prompt.txt"
    if [[ -n ${HERDR_PROMPT_CODE:-} ]]; then
      jq -cn --arg code "$HERDR_PROMPT_CODE" '{error: {code: $code, message: "blocked"}}' >&2
      exit 1
    fi
    exit 0 ;;
  "tab create")
    printf '%s\n' '{"result":{"type":"tab_created","tab":{"tab_id":"w9:t9"},"root_pane":{"pane_id":"w9:p9"}}}'
    exit 0 ;;
  "worktree list") cat "$HERDR_FIX/worktrees.json"; exit 0 ;;
  "worktree create")
    printf '%s\n' '{"result":{"type":"worktree_created","already_open":false,"workspace":{"workspace_id":"wT"},"tab":{"tab_id":"wT:t1"},"root_pane":{"pane_id":"wT:p1"},"worktree":{"path":"/tmp/wt","branch":"sc-1234"}}}'
    exit 0 ;;
  "worktree open")
    if [[ -n ${HERDR_ALREADY:-} ]]; then
      printf '%s\n' '{"result":{"type":"worktree_opened","already_open":true,"workspace":{"workspace_id":"wT"},"tab":{"tab_id":"wT:t1"},"root_pane":{"pane_id":"wT:p1"},"worktree":{"path":"/tmp/wt","branch":"sc-1234"}}}'
    else
      printf '%s\n' '{"result":{"type":"worktree_opened","already_open":false,"workspace":{"workspace_id":"wT"},"tab":{"tab_id":"wT:t1"},"root_pane":{"pane_id":"wT:p1"},"worktree":{"path":"/tmp/wt","branch":"sc-1234"}}}'
    fi
    exit 0 ;;
esac
printf 'unexpected: %s\n' "$*" >&2
exit 1
SH
chmod +x "$WORK/bin/herdr"
cat >"$FIX/workspaces.json" <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w9","label":"omarchy-shortcut-stories"},
  {"workspace_id":"w2","label":"kvittering"}
]}}
JSON
cat >"$FIX/panes.json" <<'JSON'
{"result":{"panes":[
  {"pane_id":"w9:p1","workspace_id":"w9","cwd":"/home/kimm/Projects/omarchy-shortcut-stories"},
  {"pane_id":"w2:p1","workspace_id":"w2","cwd":"/home/kimm/Projects/kvittering"}
]}}
JSON
printf '%s\n' '{"result":{"agents":[{"agent":"grok","agent_status":"working","pane_id":"w9:p2"}]}}' >"$FIX/agents.json"
printf '%s\n' '{"result":{"worktrees":[]}}' >"$FIX/worktrees.json"
: >"$WORK/herdr.log"
solve() {
  PATH="$WORK/bin:$PATH" HERDR_LOG="$WORK/herdr.log" HERDR_FIX="$FIX" \
    HERDR_START_CODE= HERDR_PROMPT_CODE= HERDR_ALREADY= \
    "$SOLVE" "$@"
}
reset_herdr() { : >"$WORK/herdr.log"; rm -f "$FIX/prompt.txt"; }

mkdir -p "$WORK/empty-bin"
ln -s "$(command -v jq)" "$WORK/empty-bin/jq"
out=$(PATH="$WORK/empty-bin" "$SOLVE" workspaces)
is "no herdr is a clean failure" "$(jq -r .code <<<"$out")" "noherdr"

out=$(solve workspaces)
is "workspaces come back" "$(jq -r '.workspaces | length' <<<"$out")" "2"
is "cwd rides along" "$(jq -r '.workspaces[] | select(.id=="w2").cwd' <<<"$out")" "/home/kimm/Projects/kvittering"

reset_herdr
body='{"workspaceId":"w9","cwd":"/home/kimm/Projects/omarchy-shortcut-stories","worktree":false,"kind":"grok","agent":"s1234","branch":"sc-1234","prompt":"Solve sc-1234"}'
out=$(printf '%s' "$body" | solve start)
is "a tab start succeeds" "$(jq -r .ok <<<"$out")" "true"
is "and it prompted" "$(jq -r .prompted <<<"$out")" "true"
is "in a new tab" "$(jq -r .where <<<"$out")" "tab"
is "the prompt was handed over" "$(cat "$FIX/prompt.txt")" "Solve sc-1234"
has "it opened a tab, not a worktree" "$(cat "$WORK/herdr.log")" "tab create"
hasnt "a checkout start does not create a worktree" "$(cat "$WORK/herdr.log")" "worktree create"
has "the tab keeps the cwd" "$(cat "$WORK/herdr.log")" "--cwd /home/kimm/Projects/omarchy-shortcut-stories"

reset_herdr
out=$(printf '%s' '{"workspaceId":"w9","worktree":true,"kind":"claude","agent":"s1234","branch":"sc-1234","prompt":"go"}' | solve start)
is "a new worktree is created" "$(jq -r .where <<<"$out")" "worktree"
has "create, not open" "$(grep -c 'worktree create' "$WORK/herdr.log")" "1"
hasnt "and no extra tab" "$(cat "$WORK/herdr.log")" "tab create"
has "the agent starts in the new pane" "$(cat "$WORK/herdr.log")" "agent start s1234 --kind claude --pane wT:p1"

reset_herdr
printf '%s\n' '{"result":{"worktrees":[{"branch":"sc-1234","path":"/tmp/wt"}]}}' >"$FIX/worktrees.json"
out=$(printf '%s' '{"workspaceId":"w9","worktree":true,"kind":"grok","agent":"s1234","branch":"sc-1234","prompt":"go"}' | solve start)
is "an existing branch is opened" "$(jq -r .ok <<<"$out")" "true"
has "open, not create" "$(grep -c 'worktree open' "$WORK/herdr.log")" "1"
hasnt "create stays away" "$(cat "$WORK/herdr.log")" "worktree create"

reset_herdr
HERDR_ALREADY=1
out=$(HERDR_ALREADY=1 PATH="$WORK/bin:$PATH" HERDR_LOG="$WORK/herdr.log" HERDR_FIX="$FIX" \
  "$SOLVE" start <<'JSON'
{"workspaceId":"w9","worktree":true,"kind":"grok","agent":"s1234","branch":"sc-1234","prompt":"go"}
JSON
)
is "a busy worktree gets its own tab" "$(jq -r .paneId <<<"$out")" "w9:p9"
has "the tab follows the open" "$(grep -c 'tab create' "$WORK/herdr.log")" "1"
unset HERDR_ALREADY

reset_herdr
printf '%s\n' '{"result":{"agents":[{"name":"s1234","agent_status":"idle","pane_id":"w9:p3"}]}}' >"$FIX/agents.json"
out=$(printf '%s' "$body" | solve start)
is "an agent already on it is not prompted" "$(jq -r .prompted <<<"$out")" "false"
is "it is focused instead" "$(jq -r .where <<<"$out")" "existing"
hasnt "no second start" "$(cat "$WORK/herdr.log")" "agent start"
[[ -f $FIX/prompt.txt ]] && no "no prompt was sent" "prompt file exists" "absent" || ok "no prompt was sent"

reset_herdr
printf '%s\n' '{"result":{"agents":[]}}' >"$FIX/agents.json"
out=$(printf '%s' '{"workspaceId":"w9","worktree":false,"kind":"grok","agent":"s1234","branch":"sc-1234","prompt":"go"}' \
  | HERDR_START_CODE=agent_not_ready PATH="$WORK/bin:$PATH" HERDR_LOG="$WORK/herdr.log" HERDR_FIX="$FIX" "$SOLVE" start)
is "a blocked start waits" "$(jq -r .status <<<"$out")" "blocked"
is "and does not pretend it prompted" "$(jq -r .prompted <<<"$out")" "false"

reset_herdr
out=$(printf '%s' '{"workspaceId":"w9","kind":"nope","agent":"s1","branch":"sc-1","prompt":"go"}' | solve start)
is "an unknown agent is refused" "$(jq -r .code <<<"$out")" "usage"
is "and herdr is not asked" "$(wc -l <"$WORK/herdr.log" | tr -d ' ')" "0"

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
  ["all keeps every story",
    M.storiesInScope([{iterationId:42},{iterationId:43},{iterationId:null}], refs, "all", TODAY).length, 3],
  ["current keeps sprints that contain today",
    M.storiesInScope(
      [{name:"in", iterationId:42},{name:"next", iterationId:43},{name:"none", iterationId:null},{name:"design", iterationId:44}],
      refs, "current", TODAY).map(s => s.name).join(","),
    "in,design"],
  ["a string id still matches",
    M.storiesInScope([{iterationId:"42"}], refs, "current", TODAY).length, 1],
  ["no current sprint shows nothing",
    M.storiesInScope([{iterationId:42}], refs, "current", "2027-01-01").length, 0],
  ["an unknown scope is everything",
    M.storiesInScope([{iterationId:43}], refs, "nope", TODAY).length, 1],
  ["one current sprint is named", M.currentIterationLabel(refs, "2026-10-05"), "Sprint 13"],
  ["several current sprints share a label", M.currentIterationLabel(refs, TODAY), "Current sprints"],
  ["no current sprint has no label", M.currentIterationLabel(refs, "2027-01-01"), ""],
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
  ["the current sprint is the number the list shows",
    M.barLabel(
      [{workflowStateId:5002, iterationId:42},{workflowStateId:5003, iterationId:42},
       {workflowStateId:5004, iterationId:42},{workflowStateId:5002, iterationId:43}],
      refs, "count", "current", TODAY), "2"],
  ["and in progress follows the same filter",
    M.barLabel(
      [{workflowStateId:5003, iterationId:42},{workflowStateId:5003, iterationId:43}],
      refs, "started", "current", TODAY), "1"],
  ["nothing seen means all of them are new", M.unseenCount([{id:1},{id:2}], []), 2],
  ["a seen story is not new", M.unseenCount([{id:1},{id:2}], ["1"]), 1],
  ["a number and a string are the same story", M.unseenCount([{id:1}], [1]), 0],
  ["a story with no id is not a badge", M.unseenCount([{name:"x"}], []), 0],
  ["a new arrival stays unseen",
    M.unseenCount([{id:1},{id:2}], M.noteSeen(["1"], [{id:1},{id:2}], [])), 1],
  ["opening it clears it",
    M.unseenCount([{id:1},{id:2}], M.noteSeen(["1"], [{id:1},{id:2}], [2])), 0],
  ["a story that left is forgotten", M.noteSeen(["1","9"], [{id:1}], []).join(","), "1"],
  ["the first list is the baseline", M.seenIdsOf([{id:7},{id:8}]).join(","), "7,8"],
  ["an empty list baselines to nothing", M.seenIdsOf([]).length, 0],
  ["the same ids agree in either order", M.sameIds(["2","1"], [1, "2"]), true],
  ["a different id does not", M.sameIds(["1"], ["1","2"]), false],

  // handing a story to Herdr
  ["the agent name is the story", M.solveAgentName(18872), "s18872"],
  ["a blank id is no agent", M.solveAgentName(""), ""],
  ["a long id stays inside herdr's limit", M.solveAgentName("9".repeat(40)).length, 32],
  ["the branch is the reference", M.solveBranch(18872), "sc-18872"],
  ["an empty workspace asks", M.solveTarget([{label:"kvittering"}], "").ask, true],
  ["a saved name does not", M.solveTarget([{id:"w2", label:"kvittering"}], "Kvittering").ask, false],
  ["and it resolves the live workspace",
    M.solveTarget([{id:"w2", label:"kvittering"}], "kvittering").workspace.id, "w2"],
  ["a name herdr lost asks again", M.solveTarget([{label:"kvittering"}], "casino").ask, true],
  ["one named workspace is suggested",
    M.suggestWorkspace(
      [{id:"w2", label:"kvittering"}, {id:"w9", label:"omarchy-shortcut-stories"}],
      "Please look at kvittering").id, "w2"],
  ["two names means no guess",
    M.suggestWorkspace([{label:"kvittering"},{label:"casino"}], "kvittering and casino"), null],
  ["a shorter name is not a longer one",
    M.suggestWorkspace([{label:"notes"}], "omarchy-notes"), null],
  ["the prompt keeps the author's line break",
    M.solvePrompt({id:7, name:"Fix", description:"a\nb", appUrl:"https://example/7"}, refs, false).includes("a\nb"), true],
  ["and names the comment's author",
    M.solvePrompt({id:7, name:"Fix", description:"", comments:[
      {authorId:"ada-uuid", text:"Second", position:2},
      {authorId:"me-uuid", text:"First", position:1}]}, refs, false).includes("- Kimm Stensborg: First"), true],
  ["a checkout creates the branch",
    M.solvePrompt({id:7, name:"Fix", description:""}, refs, false).includes("Create a branch named sc-7"), true],
  ["a worktree is already on it",
    M.solvePrompt({id:7, name:"Fix", description:""}, refs, true).includes("already on branch sc-7"), true],
  ["a worktree is not told to check it out again",
    M.solvePrompt({id:7, name:"Fix", description:""}, refs, true).includes("Create a branch"), false],
  ["a long prompt points at the story",
    (() => {
      const text = M.solvePrompt({id:7, name:"Fix", description:"word ".repeat(4000), appUrl:"https://example/7"}, refs, false)
      return text.length <= M.SOLVE_PROMPT_LIMIT && text.endsWith("https://example/7.")
    })(), true],
  ["the caption names the worktree",
    M.solveCaption({label:"kvittering"}, true, 7), "Worktree sc-7 under kvittering"],
  ["and the tab when it stays in the checkout",
    M.solveCaption({label:"kvittering"}, false, 7), "New tab in kvittering"],
  ["workspaces lead with asking",
    M.settingOptions(M.settingRow("solveWorkspace"), null, TODAY, "", [{label:"kvittering"}])[0].label,
    "Ask each time"],
  ["and then the live names",
    M.settingOptions(M.settingRow("solveWorkspace"), null, TODAY, "", [{label:"kvittering"},{label:"casino"}])
      .map(o => o.label).join(","),
    "Ask each time,casino,kvittering"],
  ["the agent defaults to grok", M.readSetting({}, "agentKind"), "grok"],
  ["worktree defaults off", M.readSetting({}, "solveWorktree"), false],

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
  ["the page keeps every section", M.settingsPage().flat().length, M.SETTINGS.length],
  ["new story sits beside solve",
    M.settingsPage()[0][0].title + "|" + M.settingsPage()[1][0].title, "New story|Solve"],
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
  ["comments name their author",
    M.storyDetail({id:1, comments:[{id:1, authorId:"ada-uuid", text:"Hello", createdAt:"2026-09-20T10:00:00Z", position:1}]}, refs).comments[0].authorName,
    "Ada Lovelace"],
  ["a departed author is named as such",
    M.storyDetail({id:1, comments:[{id:1, authorId:"ghost", text:"Hello"}]}, refs).comments[0].authorName,
    "Someone who has left"],
  ["an unsigned comment stays someone",
    M.storyDetail({id:1, comments:[{id:1, text:"Hello"}]}, refs).comments[0].authorName,
    "Someone"],
  ["comments run oldest first",
    M.storyDetail({id:1, comments:[
      {id:2, text:"Later", position:2, createdAt:"2026-09-21T00:00:00Z"},
      {id:1, text:"Earlier", position:1, createdAt:"2026-09-20T00:00:00Z"}
    ]}, refs).comments.map(c => c.text).join(","),
    "Earlier,Later"],
  ["a reply is marked",
    M.storyDetail({id:1, comments:[{id:2, text:"Yep", parentId:1}]}, refs).comments[0].reply, true],
  ["a top-level comment is not",
    M.storyDetail({id:1, comments:[{id:1, text:"Yep", parentId:null}]}, refs).comments[0].reply, false],
  ["a blocker is marked",
    M.storyDetail({id:1, comments:[{id:1, text:"Stopped", blocker:true}]}, refs).comments[0].blocker, true],
  ["a deleted comment is left out",
    M.storyDetail({id:1, comments:[{id:1, text:"Gone", deleted:true},{id:2, text:"Kept"}]}, refs).comments.map(c => c.text).join(","),
    "Kept"],
  ["a blank comment is left out",
    M.storyDetail({id:1, comments:[{id:1, text:"   "},{id:2, text:"Kept"}]}, refs).comments.length, 1],
  ["no comments is an empty list",
    M.storyDetail({id:1}, refs).comments.length, 0],
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
  ["a description keeps its line breaks",
    M.storyDetail({id:1, description:"one\ntwo"}, refs).description, "one  \ntwo"],
  ["a blank line stays a paragraph", M.formatDescription("one\n\ntwo"), "one\n\ntwo"],
  ["extra blank lines collapse", M.formatDescription("one\n\n\ntwo"), "one\n\ntwo"],
  ["a blank description stays blank", M.formatDescription("  \n\t"), ""],
  ["a list is not glued to the line before it",
    M.formatDescription("See:\n1. one\n2. two"), "See:\n\n1. one\n2. two"],
  ["prose after a list starts a new paragraph",
    M.formatDescription("1. one\nThen this"), "1. one\n\nThen this"],
  ["a fence is left as it was typed",
    M.formatDescription("```\nkeep\nthis\n```"), "```\nkeep\nthis\n```"],
  ["a heading stays a heading", M.formatDescription("## Steps\n\nDo it"), "## Steps\n\nDo it"],
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
