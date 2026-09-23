#!/bin/bash

# Enable Shortcut Stories and bind a key to it.
#
#   ./install.sh                 pick a shortcut interactively
#   ./install.sh --key "SUPER + ALT + T"
#   ./install.sh --shot-key "SUPER + ALT + B"
#   ./install.sh --no-shot-key   no key for a bug from a screenshot
#   ./install.sh --no-bind       just enable the plugin
#
# The shortcut proposed first is SUPER + ALT + T, unless Hyprland already has
# that combination, in which case the first free candidate is proposed instead.
# Whatever is proposed can be edited; Enter accepts it. A second key, SUPER +
# ALT + B, screenshots a region and opens a new bug with it -- bound only
# when it is free, never taken over.

set -euo pipefail

ID="io.github.kimm-stensborg.shortcut-stories"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MARKER="-- Shortcut Stories overlay ($ID)"

# T for ticket, in the SUPER + ALT family the other plugins here live in. Every
# SUPER + S combination is taken on a stock Omarchy, so the obvious mnemonic is
# not available; the rest are here for when the first one is taken too.
CANDIDATES=(
  "SUPER + ALT + T"
  "SUPER + ALT + C"
  "SUPER + SHIFT + T"
  "SUPER + CTRL + Y"
)

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

interactive() { [[ -t 0 && -t 1 ]]; }

for tool in jq hyprctl omarchy-shell curl; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

key=""
bind=1
shot_key="SUPER + ALT + B"
while (($# > 0)); do
  case "$1" in
  --key)
    key="${2:-}"
    [[ -n $key ]] || fail "--key requires a shortcut"
    shift 2
    ;;
  --shot-key)
    shot_key="${2:-}"
    [[ -n $shot_key ]] || fail "--shot-key requires a shortcut"
    shift 2
    ;;
  --no-shot-key)
    shot_key=""
    shift
    ;;
  --no-bind)
    bind=0
    shift
    ;;
  -h | --help)
    sed -n '3,15p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) fail "unknown option: $1" ;;
  esac
done

# Any spelling of a combination reduced to one, so "SUPER+Alt+t" and
# "SUPER + ALT + T" are recognised as the same shortcut.
normalize() {
  local combo=${1,,}
  combo=${combo// /}
  local IFS='+' part
  local -a parts=()
  for part in $combo; do
    [[ -n $part ]] || continue
    parts+=("$part")
  done
  local mods=() key=""
  for part in "${parts[@]}"; do
    case $part in
    super | mod | win | meta) mods+=("super") ;;
    shift) mods+=("shift") ;;
    alt) mods+=("alt") ;;
    ctrl | control) mods+=("ctrl") ;;
    *) key=$part ;;
    esac
  done
  local sorted
  sorted=$(printf '%s\n' "${mods[@]}" | sort -u | tr '\n' '+')
  printf '%s%s' "$sorted" "$key"
}

# Hyprland's modmask is a bitfield: 1 shift, 4 ctrl, 8 alt, 64 super.
bound_combos() {
  hyprctl binds -j | jq -r '.[]
    | [(if (.modmask / 64 | floor) % 2 == 1 then "super" else empty end),
       (if (.modmask / 8  | floor) % 2 == 1 then "alt"   else empty end),
       (if (.modmask / 4  | floor) % 2 == 1 then "ctrl"  else empty end),
       (if .modmask % 2 == 1               then "shift" else empty end)]
      as $mods
    | ($mods | sort | join("+")) as $m
    | "\($m)\(if $m == "" then "" else "+" end)\(.key | ascii_downcase)\t\(.description // .dispatcher)"'
}

# Every combination an earlier run of this script bound, so re-running and
# keeping the same shortcuts does not look like a collision with itself.
ours() {
  [[ -f $BINDINGS ]] || return 0
  awk -v marker="$MARKER" '
    $0 == marker { found = 1; next }
    found && /^o\.bind\(/ {
      match($0, /"[^"]+"/)
      print substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    found && !/^hl\.unbind\(/ { exit }
  ' "$BINDINGS"
}

is_taken() {
  local wanted=$1 mine
  while IFS= read -r mine; do
    [[ -n $mine && $wanted == "$(normalize "$mine")" ]] && return 1
  done < <(ours)
  bound_combos | cut -f1 | grep -qx "$wanted"
}

describe_conflict() {
  bound_combos | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }'
}

pick_default() {
  local candidate
  for candidate in "${CANDIDATES[@]}"; do
    is_taken "$(normalize "$candidate")" || {
      printf '%s\n' "$candidate"
      return
    }
  done
  printf '%s\n' "${CANDIDATES[0]}"
}

write_binding() {
  local combo="$1" conflict="$2" shot="$3"
  mkdir -p "$(dirname "$BINDINGS")"
  touch "$BINDINGS"
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"

  # Drop a previous run's block so re-running replaces the shortcut rather
  # than stacking a second one.
  local tmp
  tmp=$(mktemp)
  awk -v marker="$MARKER" '
    $0 == marker { skip = 1; next }
    skip && ($0 ~ /^hl\.unbind\(/ || $0 ~ /^o\.bind\(/) { next }
    { skip = 0; lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$BINDINGS" >"$tmp"
  mv "$tmp" "$BINDINGS"

  {
    printf '\n%s\n' "$MARKER"
    [[ -z $conflict ]] || printf 'hl.unbind("%s")\n' "$combo"
    printf 'o.bind("%s", "New Shortcut story", "omarchy-shell shell toggle %s '"'"'{}'"'"'")\n' "$combo" "$ID"
    # The installed path, not this checkout's: it is the same file whether
    # the plugin is a clone or a link, and it survives the checkout moving.
    [[ -z $shot ]] || printf 'o.bind("%s", "Shortcut bug from a screenshot", "%s shot --open")\n' \
      "$shot" "$HOME/.config/omarchy/plugins/$ID/bin/shortcut"
  } >>"$BINDINGS"

  hyprctl reload >/dev/null
  local errors
  errors=$(hyprctl configerrors)
  [[ -z ${errors//[[:space:]]/} || $errors == "no errors"* ]] ||
    fail "Hyprland reported config errors:"$'\n'"$errors"
}

if ((bind)); then
  [[ -n $key ]] || key=$(pick_default)

  if interactive && [[ -z ${1:-} ]]; then
    proposed=$key
    if command -v gum >/dev/null; then
      key=$(gum input --value "$proposed" --prompt "Shortcut: ") || exit 1
    else
      read -rp "Shortcut [$proposed]: " key
      key=${key:-$proposed}
    fi
    [[ -n $key ]] || fail "no shortcut given"
  fi

  normalized=$(normalize "$key")
  conflict=""
  if is_taken "$normalized"; then
    conflict=$(describe_conflict "$normalized")
    echo "$key is already bound to: ${conflict:-something else}"
    if interactive; then
      if command -v gum >/dev/null; then
        gum confirm "Take it over?" || fail "left alone"
      else
        read -rp "Take it over? [y/N] " answer
        [[ ${answer,,} == y* ]] || fail "left alone"
      fi
    fi
  fi

  # The screenshot key is a convenience, so it never takes a combination
  # over: a busy one is skipped and said so, and --shot-key picks another.
  if [[ -n $shot_key ]]; then
    shot_normalized=$(normalize "$shot_key")
    if [[ $shot_normalized == "$normalized" ]]; then
      echo "$shot_key is the panel's own key; no screenshot key bound."
      shot_key=""
    elif is_taken "$shot_normalized"; then
      echo "$shot_key is already bound to: $(describe_conflict "$shot_normalized"); no screenshot key bound."
      echo "Pick another with --shot-key."
      shot_key=""
    fi
  fi

  write_binding "$key" "$conflict" "$shot_key"
  echo "Bound $key to Shortcut Stories."
  [[ -z $shot_key ]] || echo "Bound $shot_key to a new bug from a screenshot."
fi

omarchy plugin enable "$ID"

echo
echo "Next: set up your API token, which is read without echoing it."
echo "  $(dirname "$(readlink -f "$0")")/bin/shortcut login"
echo "Create a token under Settings -> API Tokens in Shortcut."
