#!/bin/bash
# Wire jgarza.omalens into the shell: enable the plugin, add an "omaLens" row to
# the Omarchy menu (SUPER+SPACE), and drop an app-launcher entry. Idempotent.
set -e
here=$(cd "$(dirname "$0")" && pwd)

# 1. Enable the overlay plugin so `omarchy-shell shell toggle` will summon it.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable jgarza.omalens >/dev/null 2>&1 || true
fi

# 2. App-launcher entry.
mkdir -p ~/.local/share/applications
cp "$here/jgarza-omalens.desktop" ~/.local/share/applications/
update-desktop-database ~/.local/share/applications 2>/dev/null || true

# 3. Omarchy menu entries — merge one line each into the user extension file.
menu=~/.config/omarchy/extensions/omarchy-menu.jsonc
mkdir -p "$(dirname "$menu")"
[[ -f $menu ]] || printf '{\n}\n' > "$menu"

# add_menu_entry KEY LINE: insert LINE before the file's closing brace unless KEY is there.
add_menu_entry() {
  if grep -q "\"$1\"" "$menu"; then
    echo "menu entry $1 already present"
    return
  fi
  local tmp
  tmp=$(mktemp)
  awk -v e="$2" '
    { lines[NR]=$0 }
    END {
      last=NR; while (last>0 && lines[last] !~ /}/) last--
      prev=last-1; while (prev>0 && (lines[prev] ~ /^[[:space:]]*$/ || lines[prev] ~ /^[[:space:]]*\/\//)) prev--
      if (prev>0 && lines[prev] !~ /[{,][[:space:]]*$/) lines[prev]=lines[prev] ","
      for (i=1;i<last;i++) print lines[i]
      print e
      for (i=last;i<=NR;i++) print lines[i]
    }' "$menu" > "$tmp" && mv "$tmp" "$menu"
  echo "added $1 to the Omarchy menu"
}

# Note the '\''{}'\'' — a literal single-quoted {} (empty JSON payload).
add_menu_entry omalens '  "omalens": {"icon":"󰍉","label":"omaLens","aliases":["omalens","lens","magnifier","magnify","zoom"],"description":"Magnifying glass for the screen","action":"omarchy-shell shell toggle jgarza.omalens '\''{}'\''"}'
add_menu_entry omalens-settings '  "omalens-settings": {"icon":"󰒓","label":"omaLens Settings","aliases":["omalens-settings","lens settings","magnifier settings"],"description":"Adjust the lens and set up its key bindings","action":"omarchy-shell omalens settings"}'

# 4. Re-parse the menu if the shell is up.
omarchy menu refresh >/dev/null 2>&1 || true

echo "done. Open it from the Omarchy menu (SUPER+SPACE -> omaLens), the app launcher, or:"
echo "  omarchy-shell shell toggle jgarza.omalens '{}'"
