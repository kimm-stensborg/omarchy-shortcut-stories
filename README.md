# Shortcut Stories

Write a [Shortcut](https://shortcut.com) story from a panel that drops over
whatever you are doing, and put the ones assigned to you where they belong
without opening a browser. Drawn like the rest of Omarchy: the menu's
background, border and font, with Hyprland's corner rounding.

![Shortcut Stories](preview.png)

- **Plugin ID:** `io.github.kimm-stensborg.shortcut-stories`
- **Kind:** service + bar widget + overlay
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`, and a Shortcut account

## Dependencies

| Package | Used for |
|---------|----------|
| `curl` | Talking to the Shortcut API |
| `jq` | Reading and building the JSON that goes over it |
| `libsecret` (`secret-tool`) | Keeping your API token in the keyring |

`secret-tool` is optional. Without it the token goes in a `0600` file under
`~/.config/omarchy-shortcut-stories/` instead.

The tests additionally want `python3` (the mock API server), `node` (the
`Model.js` cases) and `qt6-declarative` (`qmllint`).

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-shortcut-stories
~/.config/omarchy/plugins/io.github.kimm-stensborg.shortcut-stories/install.sh
```

`omarchy plugin add` clones the repository into
`~/.config/omarchy/plugins/`. A plugin runs unsandboxed inside the shell
process, so read what you are installing first -- this one included.

`install.sh` enables the plugin and binds a key to the panel, proposing
**SUPER + ALT + T** and offering the next free combination if Hyprland already
has that one. It backs up `bindings.lua` before touching it. `--no-bind` skips
the key, `--key "SUPER + ALT + C"` names one.

To put the count in the bar as well:

```bash
omarchy bar put io.github.kimm-stensborg.shortcut-stories --section right
```

The icon carries a small badge when a story has been assigned to you since
you last opened it. Opening the story clears that one. The stories already
assigned the first time the plugin looks are not new, so the badge starts
clear. Hovering the icon does not list them.

### Your token

The panel is locked until it has one. The first time you open it there is no
form -- just what the plugin needs and a button, and `Enter` presses it. That
opens a terminal running:

```bash
~/.config/omarchy/plugins/io.github.kimm-stensborg.shortcut-stories/bin/shortcut login
```

Create a token under **Settings → API Tokens** in Shortcut. It is read without
echoing it and checked against the API before it is stored, so a typo fails in
the terminal rather than later in the bar. The panel watches for the token
while you type it and unlocks itself once it works, for the next two minutes.

A token that Shortcut later rejects -- revoked, or from another workspace --
locks the panel again and says so, rather than showing a form whose pickers
are empty and whose Create button cannot work.

Settings stay reachable while locked, so **Demo workspace** can be turned on
without a token.

The token goes to your keyring where there is one. It is never passed on a
command line, so it does not show up in `ps`, and the shell process never sees
it: only `bin/shortcut` reads it.

## Remove

```bash
~/.config/omarchy/plugins/io.github.kimm-stensborg.shortcut-stories/bin/shortcut logout
omarchy plugin remove io.github.kimm-stensborg.shortcut-stories
```

Then delete the `-- Shortcut Stories overlay` block from
`~/.config/hypr/bindings.lua`.

## Keys

| Key | Does |
|-----|------|
| **SUPER + ALT + T** | Show the panel, ready to write. Again hides it. |
| `Enter` (locked) | Opens the terminal to set up your token. |
| `Enter` | From the title, files the story. The fast path: summon, type, Enter. |
| `Ctrl + Enter` | Files the story from anywhere, including the description. |
| `Tab` / `Shift + Tab` | The next field, and the one before. |
| `Alt + F` / `Alt + B` / `Alt + C` | Feature, bug, chore, from any field. |
| `Alt + 1` / `Alt + 2` | A new story, or the ones assigned to you. |
| `Ctrl + Tab` | Swaps between those two. |
| `Ctrl + ,` | Settings. |
| `Ctrl + R` | Re-read your workspace and your stories. |
| `Alt + I` | In the list, only the sprint today falls inside. Again shows everything. |
| `Esc` | Closes a dropdown, then gives a field back its focus, then closes the panel. |

In **My stories**: `↑` `↓` walk the list, `Enter` (or a click) opens the story,
and `Ctrl + O` opens it in your browser. **All** and the current sprint sit
above the list. `Alt + I`, or a click, switches between them. The sprint is
whichever one today falls inside. Where more than one does, the list shows
all of them, and the button says so. A story with no sprint is not in that
list. The choice is remembered.

In an **open story**: `←` `→` pick a state and `Enter` moves it there,
`Ctrl + O` opens it in your browser, and `Esc` goes back to the list.

## Writing a story

Only a name is required; everything else is optional and Shortcut fills in
what you leave out. The line under the form says where the story is about to
land -- `Platform → Ready for Dev` -- so you can see what picking a team did
before you file it.

A story's board is decided by its workflow state and not by its team, so
naming a team without a state would file it under the right team on the
workspace's default board, in a column that team never looks at. Picking a
team therefore resolves its workflow's default state and sends that too. With
no team picked, nothing is sent and Shortcut applies its own default.

Filing a story clears the title, the description and the type, and leaves the
team, iteration and owner where they were -- five stories in a row usually
belong to the same sprint. Turn that off with **Keep team and iteration after
filing**.

`Esc` on a story you have started writing asks once before throwing it away.

## Reading a story

A row in the list is a glance -- reference, name, state. `Enter` or a click
opens the story itself: who it is for, which sprint, the estimate, the
deadline and its labels, and under all of that the description, the tasks
and the comments. The description and the comments are rendered rather than
left as markdown source. That is the part you need in front of you to
actually do the work, and it is why the list does not try to show it.

The description runs the full width of the card rather than sharing it with
the facts, because it is prose and a narrow column of prose is harder to read.
It wraps mid-word where it has to, so a pasted URL stays inside the card.
The line breaks it was written with stay line breaks: markdown would otherwise
fold them into one paragraph. A blank line stays a paragraph, and a list or a
heading stays its own block. A comment is wrapped the same way.
Comments do the same, oldest first, with who wrote each one and when. A reply
is indented. A comment Shortcut has deleted is left out, and so is one with
no text left. A comment marked as a blocker says so on its byline.

Tasks sit between the description and the comments, each one marked done or
still open. A story with neither says so, rather than leaving a gap you would
otherwise go to Shortcut to check.

The list carries only what a row needs. Opening a story fetches the rest,
because pulling every description, task and comment for every story would be
a lot of bytes nobody reads. Comments come back on that same story; there is
no second request.

## Moving a story

The states run along the bottom of an open story, wrapping onto as many rows
as they need -- a workspace with a dozen of them, named things like "Review -
Definition of Done", would otherwise run off the card. `←` `→` pick one and
`Enter` moves it; a click does the same. The state the story is in keeps a dot
beside it.

Only that story's own workflow is ever offered: Shortcut will accept a state
from a different workflow without complaint and quietly move the story to a
board nobody on that team reads.

The story moves the moment you pick, and moves back if Shortcut refuses.

## Settings

`Ctrl + ,`, or the gear. Changes apply as you make them; there is no Save. A
dot marks an option that is no longer the default.

**Team**, **Iteration** and **Owner** are filled from your workspace, so you
pick a real team and a real sprint rather than typing a name and hoping. Set
them and every new story starts there.

Each is resolved against the workspace every time rather than trusted: a team
that has been archived, a sprint that has finished or moved to another team,
or a colleague who has left all read as unset instead of being sent to
Shortcut. **Owner** stores "me" rather than your user id, so it still means
you after a re-invite, and **Iteration** stores "current" rather than a sprint
id when you pick "whichever one is current", so it follows the sprint over
rather than going stale when this one ends.

| Option | Default | Does |
|--------|---------|------|
| Team | none | The team a new story starts on |
| Iteration | none | A sprint by name, or whichever one today falls inside |
| Owner | Me | Who a new story is assigned to |
| Type | Feature | What a new story starts as |
| Keep team and iteration after filing | on | Leaves them set for the next story |
| Next to the glyph | Open stories | What the bar shows: nothing, the count, or how many are in progress |
| Opens on | New story | Which pane the keybinding lands on |
| Show finished stories | off | Keeps done stories in the list |
| Stories | Everything assigned to me | The list, or only the sprint today falls inside |
| Refresh while closed | 5 min | How often the count is brought up to date |
| Demo workspace | off | A made-up workspace; never calls Shortcut |

## What it stores

| Path | What |
|------|------|
| keyring, service `shortcut` | Your API token, or `~/.config/omarchy-shortcut-stories/token` at `0600` without a keyring |
| `~/.cache/omarchy-shortcut-stories/refs.json` | Teams, workflows, people and iterations, so the pickers are filled before you open the panel |
| `~/.cache/omarchy-shortcut-stories/status.json` | The count and how many stories you have not opened, for the bar widget to read |
| `~/.cache/omarchy-shortcut-stories/seen.json` | The stories you have opened, so the badge only counts new ones |
| `~/.config/omarchy/shell.json` | The settings above, on the widget's entry. Team is stored as its id, so renaming a team in Shortcut does not unset it; a team name typed by hand still works. |

The reference cache is re-read every six hours, and whenever the panel opens
on data more than fifteen minutes old. When Shortcut cannot be reached the
cached copy is shown, marked as older, rather than an empty panel.

## Why the bar widget reads a file

The shell hands `shell` to the bar itself, to services and to panel loaders,
but never to a bar widget, and `pluginServiceFor` refuses a caller with no id.
So a widget cannot reach its own plugin's service at all. Rather than give
every monitor's copy of the widget its own poller, the service writes what the
bar needs to `status.json` and the widgets watch that one file.

## A note on Shortcut's search

A story you have just filed does not appear in Shortcut's search for a few
seconds. The list is told about it rather than asked, so it shows up at once
and is reconciled ten seconds later.

## Command line

`bin/shortcut` is the whole backend and works on its own:

```bash
bin/shortcut refs | jq '[.groups[].name]'   # your teams
bin/shortcut mine | jq '.stories[].name'    # what is assigned to you
echo '{"name":"From the terminal"}' | bin/shortcut create
bin/shortcut show 1234 | jq -r .story.description
bin/shortcut move 1234 5002
```

Everything but `login` and `logout` prints one JSON object, `{"ok": false,
"code": ..., "error": ...}` when something went wrong. `create` reads its
story from stdin rather than taking flags, so a description with quotes,
newlines and `$` in it survives.

## Files

| Path | What |
|------|------|
| `manifest.json` | Plugin id, entry points, and the bar widget's settings schema |
| `bin/shortcut` | The only thing that holds the token or speaks HTTP |
| `Model.js` | Every pure decision: picker lists, the create body, the story list |
| `Store.qml` | The service: one poller, one reference cache, every CLI call |
| `Overlay.qml` | The card, the mode switch and the key handling |
| `ComposePane.qml` | The new-story form |
| `StoriesPane.qml` | The stories assigned to you |
| `StoryDetail.qml` | One story opened up: description, tasks, comments, and the states it can move to |
| `SettingsPane.qml`, `SettingsColumn.qml` | The settings page |
| `BarWidget.qml` | The glyph, the count, and the badge for stories you have not opened |
| `install.sh` | Enables the plugin and binds a key |
| `test.sh` | Mock-API tests, `Model.js` under node, and `qmllint` |

## Developing

```bash
git -C ~/.config/omarchy/plugins/io.github.kimm-stensborg.shortcut-stories pull ~/Projects/omarchy-shortcut-stories main
omarchy restart shell
```

Do not edit the installed copy: the plugin manager marks it dirty and refuses
to fast-forward, and the work is somewhere unpushed.

**Restart the shell after changing `Model.js`.** Saving any file under
`~/.config/omarchy/plugins/` makes the shell reload the plugin's QML, but the
QML engine keeps the `Model.js` it already compiled. The reloaded QML then
calls functions the cached copy does not have, the call throws, and whatever
was being built -- a settings column, a pane -- renders as nothing at all,
with no error anywhere you would look. It is not a bug in the plugin and it
does not happen to anyone installing a release; it only bites while a checkout
is linked and being edited.

Turn on **Demo workspace** to work on the panel without a token or a network.

## Tests

```bash
./test.sh
```

Runs `bin/shortcut` against a local mock of the Shortcut API -- asserting the
exact JSON that goes over the wire, not just that a call succeeded -- the pure
helpers in `Model.js` under node, and `qmllint` over the QML. Nothing reaches
the real API, your keyring or your token.
