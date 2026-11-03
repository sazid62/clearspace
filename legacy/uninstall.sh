#!/bin/bash
# uninstall-app.sh — find every file belonging to a Mac app and remove it, with confirmation.
#
# Usage:
#   ./uninstall-app.sh "App Name"
#   ./uninstall-app.sh            # will prompt for a name
#
# What it does:
#   1. Finds the .app bundle(s) matching the name you give it (Spotlight + common dirs).
#   2. Reads the bundle identifier (e.g. com.company.app) and display name from the bundle.
#   3. Searches the whole system for anything tied to that app: prefs, caches, containers,
#      logs, saved state, launch agents/daemons, package receipts, group containers, etc.
#   4. Prints every path found (with sizes) and asks for confirmation.
#   5. Moves confirmed items to Trash (reversible) unless you pass --permanent.
#
# Flags:
#   --permanent   rm -rf instead of moving to Trash (irreversible, asks for extra confirmation)
#   --yes         skip the interactive confirmation (still prints the list first)
#
PERMANENT=0
ASSUME_YES=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --permanent) PERMANENT=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

APP_QUERY="${ARGS[0]:-}"
if [ -z "$APP_QUERY" ]; then
  read -rp "App name to find and remove: " APP_QUERY
fi
if [ -z "$APP_QUERY" ]; then
  echo "No app name given, aborting." >&2
  exit 1
fi

echo "==> Searching for apps matching: $APP_QUERY"

# --- 1. Locate candidate .app bundles -----------------------------------------------------
declare -a CANDIDATES=()

while IFS= read -r line; do
  [ -n "$line" ] && CANDIDATES+=("$line")
done < <(mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '*${APP_QUERY}*'c" 2>/dev/null)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "Spotlight found nothing (maybe indexing is off) — falling back to a filesystem search of common install dirs."
  SEARCH_DIRS=(/Applications "/Applications/Utilities" "$HOME/Applications" "/System/Applications" "/System/Applications/Utilities")
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && CANDIDATES+=("$line")
    done < <(find "$d" -maxdepth 2 -iname "*${APP_QUERY}*.app" 2>/dev/null)
  done
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No app bundle found matching '$APP_QUERY'. Check the name and try again." >&2
  exit 1
fi

# de-dupe (bash 3.2 on macOS has no associative arrays, so scan a plain array)
contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

declare -a UNIQ_CANDIDATES=()
for c in "${CANDIDATES[@]}"; do
  contains "$c" "${UNIQ_CANDIDATES[@]}" || UNIQ_CANDIDATES+=("$c")
done
CANDIDATES=("${UNIQ_CANDIDATES[@]}")

APP_PATH=""
if [ "${#CANDIDATES[@]}" -eq 1 ]; then
  APP_PATH="${CANDIDATES[0]}"
else
  echo ""
  echo "Multiple matches found — pick one:"
  select choice in "${CANDIDATES[@]}"; do
    if [ -n "$choice" ]; then
      APP_PATH="$choice"
      break
    fi
  done
fi

if [ -z "$APP_PATH" ]; then
  echo "Nothing selected, aborting." >&2
  exit 1
fi

# --- 2. Identify the app uniquely ---------------------------------------------------------
BUNDLE_ID="$(mdls -raw -name kMDItemCFBundleIdentifier "$APP_PATH" 2>/dev/null)"
[ "$BUNDLE_ID" = "(null)" ] && BUNDLE_ID=""
APP_NAME="$(basename "$APP_PATH" .app)"

if [ -z "$BUNDLE_ID" ]; then
  BUNDLE_ID="$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null)"
fi

echo ""
echo "App path:   $APP_PATH"
echo "App name:   $APP_NAME"
echo "Bundle ID:  ${BUNDLE_ID:-<unknown>}"

if [ -z "$BUNDLE_ID" ]; then
  echo "Warning: could not determine a bundle identifier. Related-file search will rely on the app name only, which is less precise." >&2
fi

# --- 3. Sweep the system for related files ------------------------------------------------
echo ""
echo "==> Scanning for related files (this can take a moment)..."

declare -a FOUND=()

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
APP_NAME_LC="$(lc "$APP_NAME")"

# true only if $1's basename contains APP_NAME as a whole word, not as a
# substring of a longer name (so "Paste" doesn't match "PasteBar").
name_matches() {
  local base_lc
  base_lc="$(lc "$(basename "$1")")"
  case "$base_lc" in
    "$APP_NAME_LC") return 0 ;;
    "$APP_NAME_LC"[!a-z0-9]*) return 0 ;;
    *[!a-z0-9]"$APP_NAME_LC") return 0 ;;
    *[!a-z0-9]"$APP_NAME_LC"[!a-z0-9]*) return 0 ;;
  esac
  return 1
}

add_if_exists() {
  local p="$1"
  [ -e "$p" ] && FOUND+=("$p")
}

add_glob() {
  # expands a glob pattern and adds any matches
  local pattern="$1"
  for p in $pattern; do
    [ -e "$p" ] && FOUND+=("$p")
  done
}

add_glob_by_name() {
  # like add_glob, but only keeps matches where APP_NAME is a whole word
  # in the matched basename (guards against "Paste" matching "PasteBar")
  local pattern="$1"
  for p in $pattern; do
    [ -e "$p" ] && name_matches "$p" && FOUND+=("$p")
  done
}

FOUND+=("$APP_PATH")

for base in "$HOME/Library" "/Library"; do
  add_if_exists "$base/Application Support/$APP_NAME"
  [ -n "$BUNDLE_ID" ] && add_if_exists "$base/Application Support/$BUNDLE_ID"

  add_if_exists "$base/Caches/$APP_NAME"
  [ -n "$BUNDLE_ID" ] && add_if_exists "$base/Caches/$BUNDLE_ID"

  [ -n "$BUNDLE_ID" ] && add_if_exists "$base/Preferences/$BUNDLE_ID.plist"
  add_glob "$base/Preferences/ByHost/${BUNDLE_ID}.*.plist"

  add_if_exists "$base/Logs/$APP_NAME"

  [ -n "$BUNDLE_ID" ] && add_if_exists "$base/Containers/$BUNDLE_ID"
  [ -n "$BUNDLE_ID" ] && add_if_exists "$base/Application Scripts/$BUNDLE_ID"

  add_if_exists "$base/PreferencePanes/$APP_NAME.prefPane"

  add_glob "$base/LaunchAgents/*${BUNDLE_ID}*.plist"
  add_glob_by_name "$base/LaunchAgents/*${APP_NAME}*.plist"
  add_glob "$base/LaunchDaemons/*${BUNDLE_ID}*.plist"
  add_glob_by_name "$base/LaunchDaemons/*${APP_NAME}*.plist"

  add_glob "$base/WebKit/${BUNDLE_ID}*"
  add_glob "$base/HTTPStorages/${BUNDLE_ID}*"
  add_glob "$base/Saved Application State/${BUNDLE_ID}*.savedState"

  # Group containers: match dirs whose name contains the bundle id or app name
  if [ -d "$base/Group Containers" ]; then
    while IFS= read -r gdir; do
      name="$(basename "$gdir")"
      if { [ -n "$BUNDLE_ID" ] && [[ "$name" == *"$BUNDLE_ID"* ]]; } || name_matches "$gdir"; then
        FOUND+=("$gdir")
      fi
    done < <(find "$base/Group Containers" -maxdepth 1 -mindepth 1 2>/dev/null)
  fi
done

# Package receipts (installed via .pkg)
if [ -n "$BUNDLE_ID" ]; then
  add_glob "/private/var/db/receipts/${BUNDLE_ID}.*"
fi

# Broad supplementary sweep of ~/Library for anything else matching, in case of nonstandard locations.
# Filtered through name_matches so "Paste" doesn't also sweep up "PasteBar".
while IFS= read -r p; do
  [ -n "$p" ] && name_matches "$p" && FOUND+=("$p")
done < <(find "$HOME/Library" -maxdepth 4 -iname "*${APP_NAME}*" 2>/dev/null)

if [ -n "$BUNDLE_ID" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && FOUND+=("$p")
  done < <(find "$HOME/Library" -maxdepth 4 -iname "*${BUNDLE_ID}*" 2>/dev/null)
fi

# de-dupe and sort
declare -a RESULTS=()
for f in "${FOUND[@]}"; do
  contains "$f" "${RESULTS[@]}" || RESULTS+=("$f")
done
IFS=$'\n' RESULTS=($(sort <<<"${RESULTS[*]}")); unset IFS

# --- 4. Show everything to the user --------------------------------------------------------
echo ""
echo "==> Found ${#RESULTS[@]} item(s):"
echo ""
i=0
for f in "${RESULTS[@]}"; do
  i=$((i + 1))
  size="$(du -sh "$f" 2>/dev/null | cut -f1)"
  printf "  %2d) [%6s]  %s\n" "$i" "${size:-?}" "$f"
done
echo ""

if [ "$PERMANENT" -eq 1 ]; then
  echo "Mode: PERMANENT DELETE (rm -rf) — this cannot be undone."
else
  echo "Mode: move to Trash (reversible — empty Trash yourself when ready)."
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Any item numbers to KEEP (exclude from removal)? Comma-separated, or blank for none: " EXCLUDE_LIST
  if [ -n "$EXCLUDE_LIST" ]; then
    declare -a FILTERED=()
    i=0
    for f in "${RESULTS[@]}"; do
      i=$((i + 1))
      case ",${EXCLUDE_LIST}," in
        *",${i},"*) continue ;;
      esac
      FILTERED+=("$f")
    done
    RESULTS=("${FILTERED[@]}")
    echo ""
    echo "==> Proceeding with ${#RESULTS[@]} item(s):"
    for f in "${RESULTS[@]}"; do echo "  $f"; done
    echo ""
  fi

  read -rp "Proceed with removing the ${#RESULTS[@]} item(s) above? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted, nothing removed."
    exit 0
  fi
  if [ "$PERMANENT" -eq 1 ]; then
    read -rp "This is permanent and cannot be undone. Type the app name to confirm: " DOUBLE_CHECK
    if [ "$DOUBLE_CHECK" != "$APP_NAME" ]; then
      echo "Confirmation text did not match app name, aborting."
      exit 1
    fi
  fi
fi

# --- 5. Remove ------------------------------------------------------------------------------
FAILED=()
for f in "${RESULTS[@]}"; do
  if [ "$PERMANENT" -eq 1 ]; then
    if [ -w "$(dirname "$f")" ]; then
      rm -rf "$f" 2>/dev/null || FAILED+=("$f")
    else
      sudo rm -rf "$f" 2>/dev/null || FAILED+=("$f")
    fi
  else
    dest="$HOME/.Trash/$(basename "$f")"
    if [ -e "$dest" ]; then
      dest="$HOME/.Trash/$(basename "$f").$(date +%s 2>/dev/null || echo old)"
    fi
    if [ -w "$(dirname "$f")" ]; then
      mv "$f" "$dest" 2>/dev/null || FAILED+=("$f")
    else
      sudo mv "$f" "$dest" 2>/dev/null || FAILED+=("$f")
    fi
  fi
done

echo ""
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "Done. All items processed."
else
  echo "Done, but ${#FAILED[@]} item(s) could not be removed (permissions?):"
  for f in "${FAILED[@]}"; do echo "  $f"; done
fi

if [ "$PERMANENT" -ne 1 ]; then
  echo "Items are in Trash. Empty Trash to reclaim disk space."
fi
