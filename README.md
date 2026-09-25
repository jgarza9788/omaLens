# omaLens

A live magnifying glass for Omarchy. A round lens floats just beside your
pointer and shows a magnified, live view of what's under the pointer.

The lens never takes the keyboard or the mouse: clicks, typing, and **every
Hyprland binding keep working while it's open**. You control the lens with
key bindings of your own (see below), and it stays up until you toggle it off.

## Install

```sh
~/.config/omarchy/plugins/omaLens/extras/install.sh
```

This enables the `jgarza.omalens` plugin, adds an **omaLens** row to the
Omarchy menu, and drops an app-launcher entry. It's safe to run again.

## Open and close it

- **Menu:** `SUPER + SPACE` → **omaLens** (or type `lens`, `magnifier`, `zoom`).
  Pick it again to close.
- **App launcher:** search for *omaLens*
- **Command line:** `~/.config/omarchy/plugins/omaLens/bin/omalens toggle`

## Add key bindings

Put these in `~/.config/hypr/bindings.lua`. They use `SUPER + ALT` with keys that are
free on a stock Omarchy install (`SUPER + ALT + S` is taken, so smoothing is on `P`):

```lua
local omalens = os.getenv("HOME") .. "/.config/omarchy/plugins/omaLens/bin/omalens"

o.bind("SUPER + ALT + Z",            "Magnifying glass",       omalens .. " toggle")
o.bind("SUPER + ALT + equal",        "Magnifier zoom in",      omalens .. " zoom-in")
o.bind("SUPER + ALT + minus",        "Magnifier zoom out",     omalens .. " zoom-out")
o.bind("SUPER + ALT + bracketright", "Magnifier bigger",       omalens .. " bigger")
o.bind("SUPER + ALT + bracketleft",  "Magnifier smaller",      omalens .. " smaller")
o.bind("SUPER + ALT + backslash",    "Magnifier cycle size",   omalens .. " size")
o.bind("SUPER + ALT + O",            "Magnifier circle/square", omalens .. " shape")
o.bind("SUPER + ALT + P",            "Magnifier smooth/sharp", omalens .. " smooth")
```

Only the first line is needed to open and close the lens. Add the others if you
want to adjust it while it's open.

Hyprland reloads the file on save. Check that it took with:

```sh
hyprctl configerrors
```

If a combo you pick is already bound, unbind it first:

```lua
hl.unbind("SUPER + ALT + Z")
```

### `omalens` commands

| Command    | Action                              |
|------------|-------------------------------------|
| `toggle`   | open or close the lens (default)    |
| `close`    | close the lens                      |
| `zoom-in`  | magnify more (×1.25, up to 24×)     |
| `zoom-out` | magnify less (down to 1.25×)        |
| `size`     | cycle small → medium → large        |
| `size small` / `size medium` / `size large` | jump to that size |
| `bigger`   | next size up (stops at large)       |
| `smaller`  | next size down (stops at small)     |
| `shape`    | circle ↔ square                     |
| `smooth`   | smooth ↔ sharp pixels               |

The three sizes are small (300 px), medium (600 px), and large (900 px).
Zoom, size, shape, and smoothing are kept between uses until the shell
restarts.

### Starting with other settings

To open the lens with particular settings, summon it with a JSON payload. Every
field is optional:

| Field    | Values                        | Default      |
|----------|-------------------------------|--------------|
| `zoom`   | `1.25`–`24`                   | `2.5`        |
| `size`   | `"small"` / `"medium"` / `"large"` | `"medium"` |
| `shape`  | `"circle"` / `"square"`       | `"circle"`   |
| `smooth` | `true` / `false`              | `false` (sharp pixels) |

For example, a large square lens for inspecting pixels:

```lua
o.bind("SUPER + ALT + SHIFT + Z", "Pixel lens",
  [[omarchy-shell shell toggle jgarza.omalens '{"zoom":8,"size":"large","shape":"square"}']])
```

## How it works

- `OmaLens.qml` draws the lens on a small layer surface that takes no input,
  so clicks and keys go to whatever is underneath it. The surface shows a live
  capture of the monitor under the pointer, magnified around the pointer.
- The lens sits below and to the right of the pointer. Near a screen edge it
  glides around the pointer to whichever side fits, and moves back once there's
  room again. It travels around the pointer rather than across it, so it never
  covers the area it magnifies and never magnifies itself.
- Opening and closing animate like lifting a glass off the screen and putting
  it back. On open it springs up from 90% size, comes into focus from a blur,
  its shadow deepens, and the magnification ramps up to the set zoom. Closing
  is quicker and plays the same steps in reverse without the bounce. Every
  animation, including zoom, size, shape, and the glide around the pointer, is
  a spring, so it keeps its momentum if you change your mind mid-animation.
- `bin/omalens-cursor` polls Hyprland for the pointer position about 60 times
  a second, and only while the lens is open.
- The crosshair in the lens marks the pointer's spot.
- A small tail on the rim always points at the real pointer, so you can see
  which spot the lens is showing even when it's pushed against a screen edge.

Screenshots and screen recordings include the lens.

For a whole-screen zoom instead, use Hyprland's built-in keys:
`SUPER + CTRL + Z` to zoom in, `SUPER + CTRL + ALT + Z` to reset.

Requires `python3` and `hyprctl`, which ship with Omarchy.

## Uninstall

```sh
omarchy plugin disable jgarza.omalens
rm ~/.local/share/applications/jgarza-omalens.desktop
```

Then delete the `"omalens"` line from
`~/.config/omarchy/extensions/omarchy-menu.jsonc`.
