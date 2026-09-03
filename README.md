# omamac

**[Omarchy](https://omarchy.org) Quattro's theming, on macOS.**

One keystroke restyles your terminal, editor, pager, system appearance and
wallpaper together — from a single theme definition, with 22 themes ported
from Omarchy v4.0.2.

Press <kbd>⌘</kbd><kbd>⌥</kbd><kbd>O</kbd> to open the menu. Pick a theme and
everything re-renders at once; Ghostty and Claude Code retint without a
restart.

<!-- screenshot goes here: the Theme coverflow. -->

Omarchy is a Linux desktop, and its theming reaches into Hyprland, GTK,
Quickshell and friends. omamac ports the parts that make sense on a Mac,
copying Omarchy's real values rather than approximating them — the menu's
geometry, the picker's coverflow, the thumbnail recipe and the colour
mappings are all lifted from the upstream QML and shell sources at a pinned
release tag.

## What it themes

| Target | What omamac writes | Takes effect |
| --- | --- | --- |
| **Ghostty** | `~/.config/ghostty/themes/omamac`, `omamac.conf` (colours, font family, font size, background opacity) | live — running terminals reload |
| **Neovim** | `~/.local/state/omamac/current/omamac.lua` | live — pushed to running instances over their sockets |
| **Claude Code** | `~/.claude/themes/omamac.json` | live — Claude Code watches the directory |
| **Zed** | `~/.config/zed/themes/omamac.json` | live — Zed watches the directory |
| **delta** (git's pager) | `~/.config/git/omamac.ini` | next git command |
| **btop** | `~/.config/btop/themes/omamac.theme` | next launch |
| **bat** | `~/.config/bat/themes/omamac.tmTheme` | next launch |
| **macOS appearance** | light/dark system setting, from the theme's `mode` | live |
| **Wallpaper** | per-Space desktop picture, from the theme's backgrounds | live |

A target that isn't installed is a warning, not a failure. The only hard
failure is a theme that can't be resolved at all.

## Requirements

- **macOS.** `sips`, `osascript`, `defaults` and `plutil` are used directly.
- **[Hammerspoon](https://www.hammerspoon.org)** for the menu, with
  Accessibility permission granted. The CLI works without it.
- `bash`, `jq`, `curl` — `sips` and the rest ship with macOS.
- Optionally the tools above. Nothing is required for omamac to run.

Backgrounds and theme previews are downloaded from Omarchy on demand and
cached under `~/.cache/omamac`, so the first open of a picker needs network.

## Install

### Homebrew

```bash
git clone https://github.com/pedroagribeiro/omamac.git ~/personal/omamac
cd ~/personal/omamac
./install
```

That installs `jq` and Hammerspoon, symlinks `bin/omamac` into
`~/.local/bin`, and writes `~/.hammerspoon/init.lua` — unless you already
have one, in which case it prints the single line to add by hand rather than
overwriting your config.

Then launch Hammerspoon, grant it Accessibility permission when macOS
prompts (System Settings → Privacy & Security → Accessibility), and press
<kbd>⌘</kbd><kbd>⌥</kbd><kbd>O</kbd>.

### Nix flake

Add the input:

```nix
inputs.omamac.url = "github:pedroagribeiro/omamac";
```

`packages.default` puts `omamac` on `PATH`, wrapped with the tools it needs.
The Hammerspoon host has to be loaded from `~/.hammerspoon/init.lua`, and the
path must be written in **literally** — a GUI app launched through
LaunchServices inherits no shell environment, so `home.sessionVariables` and
`.zshrc` exports are both invisible to `Hammerspoon.app`:

```nix
home.file.".hammerspoon/init.lua".text = ''
  OMAMAC_DIR = "${inputs.omamac.packages.${pkgs.system}.default}/share/omamac"
  OMAMAC_BIN = "${inputs.omamac.packages.${pkgs.system}.default}/bin/omamac"
  dofile(OMAMAC_DIR .. "/hammerspoon/omamac.lua")
'';
```

`OMAMAC_BIN` should point at the **wrapped** binary in `bin/`, not the copy
under `share/omamac/bin/` — only the wrapper has `jq`/`curl` on `PATH`.

Install Hammerspoon yourself (`brew install --cask hammerspoon`); the flake
packages no cask. And back up any existing `~/.hammerspoon/init.lua` first —
`home.file` overwrites it unconditionally.

## Wiring individual tools

Most targets are written straight into files those tools already read, so
they need nothing further. Four need one line each, because omamac writes to
a file that has to be explicitly included:

**Ghostty** — the **last** line of `~/.config/ghostty/config`, after any
other `config-file` includes, since later values win:

```
config-file = ?omamac.conf
```

**delta** — the **last** include in your git config, after your own `[delta]`
section so these values win (notably `light`, which omamac drives from the
theme):

```ini
[include]
  path = ~/.config/git/omamac.ini
```

**Zed** — in `~/.config/zed/settings.json`:

```json
{ "theme": "omamac" }
```

The generated theme declares its own `appearance`, following the active theme,
so there is no light/dark pair to switch between — use the plain string form
rather than `{"mode": "system", …}`.

omamac drives Zed's **colours only**, not its font. Fonts are settings rather
than theme — Zed's theme schema has no font fields — and Zed has no include
mechanism like Ghostty's `config-file`, so the only place to write one is
`settings.json` itself. Where that file is version-controlled, writing it on
every font change means generated values landing in git, which is why omamac
leaves it alone. Set `buffer_font_family` yourself to match.

**Claude Code** — in `~/.claude/settings.json`:

```json
{ "theme": "custom:omamac" }
```

**bat** — point it at the generated theme, and build the cache once so bat
can see it (`bat cache --build`):

```bash
alias cat='bat -p --theme=omamac'
```

**Neovim** — in your `init.lua`:

```lua
-- Load omamac's generated colorscheme, and expose a socket so a theme
-- switch can push the new one into this instance live.
local omamac_theme = os.getenv("HOME") .. "/.local/state/omamac/current/omamac.lua"
if vim.uv.fs_stat(omamac_theme) then pcall(dofile, omamac_theme) end
local sockdir = os.getenv("HOME") .. "/.cache/nvim/servers"
vim.fn.mkdir(sockdir, "p")
pcall(vim.fn.serverstart, sockdir .. "/" .. vim.fn.getpid() .. ".sock")
```

If something like [vim-lumen](https://github.com/vimpostor/vim-lumen) also
watches the macOS appearance and switches colorscheme on its own, point its
light/dark callbacks at omamac's generated file too — otherwise it will
clobber omamac's colours on every light↔dark flip. Its job is to signal
*when* the appearance changes, never to decide *what* to apply:

```lua
vim.api.nvim_create_autocmd("User", { pattern = "LumenLight", callback = load_omamac })
vim.api.nvim_create_autocmd("User", { pattern = "LumenDark",  callback = load_omamac })
```

## Usage

| Key | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>⌥</kbd><kbd>O</kbd> | Open the menu |
| <kbd>⌘</kbd><kbd>⌃</kbd><kbd>Space</kbd> | Next wallpaper in the current theme |

In the menu: type to filter, <kbd>↑</kbd>/<kbd>↓</kbd> or
<kbd>←</kbd>/<kbd>→</kbd> to move, <kbd>Enter</kbd> to apply,
<kbd>Esc</kbd> to go back one level and then close.

> **Why <kbd>⌘</kbd><kbd>⌥</kbd><kbd>O</kbd> and not <kbd>⌘</kbd><kbd>⌥</kbd><kbd>Space</kbd>?**
> macOS reserves ⌥⌘Space for "Show Finder search window". Disabling that
> preference does not release the running registration without a re-login, so
> Hammerspoon's bind fails with `RegisterEventHotKey failed: -9878`. Change
> the `hs.hotkey.bind` line in `hammerspoon/omamac.lua` if you'd rather have
> the Omarchy-faithful chord and don't mind logging out.

### CLI

```
omamac theme      [name|--list|--current]
omamac font       [name|--list|--current]
omamac font-size  [points|--list|--current]
omamac opacity    [percent|--list|--current]
omamac bg         [file|--next|--list|--current]
omamac slack      [--copy]
omamac doctor
omamac menu-data
omamac preview    <wallpaper>|--theme <name>|--paths [--theme]
```

`menu-data` and `preview` are what the Hammerspoon host calls; you won't
normally run them by hand.

The font list is restricted to Nerd Fonts. Every source omamac reads already
reports only monospace families, so "monospace" wouldn't narrow anything —
what it would still let through is CJK system faces that are fixed-width but
useless for code. Override the pattern to widen it:

```bash
OMAMAC_FONT_FILTER='.' omamac font --list          # everything available
```

### Transparency

`omamac opacity 85` makes the terminal background 85% opaque; the menu offers
50–100% under **Applications → Ghostty → Opacity**. Like the font family and size, it is a preference
rather than a theme property, so it survives theme switches — Omarchy has no
equivalent (its own "Transparency" entry toggles the Quickshell bar, not the
terminal), so this is omamac's own.

Transparency alone can be hard to read, so **Blur** sits beside it
(`background-blur`, 0–40) — it only shows through a background below full
opacity. **Padding** (`window-padding`, 0–30) is the space inside the terminal
window, the counterpart to AeroSpace's gaps between windows; the two are
usually worth tuning together.

### Slack

Slack cannot be themed directly, so omamac produces the string and stops
there. **Applications → Slack** in the menu copies the sidebar theme for the
current theme to your clipboard; paste it into any Slack message and Slack
renders its own *"Switch sidebar theme"* button. `omamac slack` prints it
instead.

**Applications** holds what belongs to one specific app: Ghostty's font size
and opacity, and Slack's copy action. The root keeps what does not — the
theme, the wallpaper, and the monospace font **family**, which is a
system-wide choice that any app added later shares rather than picking its
own. Adding an app is an entry in that level's `items` plus either `into` (it
has settings of its own) or `runs` (a single action), and a glyph in
`APP_ICONS` — all in `menu/menu.html`.

Why not automatic: Slack registers no theme deep link (only `slack://app`,
`channel`, `doc`, `noop` and `open`), and its sole local store is an Electron
leveldb that is locked while Slack runs, has no stable external API, and caches
an **account-level** setting that syncs — so even a successful write would
likely be overwritten, and a failed one would corrupt Slack rather than error.

### AeroSpace

**Applications → AeroSpace → Gaps** sets the window gaps, applied live via
`aerospace reload-config` (validated with `--dry-run` first, so a config
AeroSpace would reject is never adopted).

AeroSpace can only change gaps by editing its config — its CLI is read-only
and there is no include mechanism — and that config is usually
version-controlled, where generated values do not belong. So omamac renders
it. Link your config as `~/.config/aerospace/aerospace.template.toml` and mark
the values omamac owns:

```toml
[gaps]
  inner.horizontal = 10  # omamac:gaps
  outer.top =        10  # omamac:gaps
```

**Applications → AeroSpace → Workspaces** pins a workspace to a monitor. Mark
those the same way — the value is a quoted string and each line is addressed by
its key, so assigning one leaves the rest alone:

```toml
[workspace-to-monitor-force-assignment]
1 = 'main'       # omamac:workspace
4 = 'secondary'  # omamac:workspace
```

The monitor list offers AeroSpace's positional keywords (`main`, `secondary`)
plus whatever is connected, by name — names survive replugging in a way the
keywords do not.

omamac writes `aerospace.toml` beside the template, substituting only the
marked values. The template holds real defaults rather than placeholders, so it
stays a complete, valid AeroSpace config on its own — nothing breaks if omamac
never runs. `omamac aerospace --render` rebuilds it, which is worth running on
activation so template edits take effect.

## omamac doctor

```bash
omamac doctor
```

Checks that every target actually reflects the current theme, and exits
non-zero if any doesn't. It's **read-only**: it never re-renders and never
repairs, because drift is the finding and a diagnostic that fixes what it
inspects can never tell you something was wrong. Most failures clear with:

```bash
omamac theme "$(omamac theme --current)"
```

It deliberately asks more than "does the file exist". Each check asks whether
the artefact carries the *current* theme's colours, whether the pointer that
makes it take effect is in place, and whether the consuming tool can really
see it — `bat`, for instance, only uses themes it has compiled into its
cache, so a perfectly correct `.tmTheme` can be invisible; and delta's values
only win if the `[include]` is ordered after your own `[delta]` block, so
that check resolves through your real git config rather than reading the
generated file.

## Configuration

| Variable | Purpose |
| --- | --- |
| `OMAMAC_FONT_FILTER` | Case-insensitive ERE for which font families the picker offers. Default matches Nerd Fonts. |
| `OMAMAC_OMARCHY_REV` | Upstream tag backgrounds and previews are fetched from. Default `v4.0.2`. |
| `OMAMAC_CONFIG_ROOT` | Where per-tool configs are written. Default `~/.config`. |
| `OMAMAC_CLAUDE_DIR` / `CLAUDE_CONFIG_DIR` | Claude Code's config directory. Default `~/.claude`. |
| `OMAMAC_STATE` / `OMAMAC_CACHE` | State and cache roots. Default `~/.local/state/omamac`, `~/.cache/omamac`. |
| `OMAMAC_THEMES_DIR` | Where themes are read from. Default the checkout's `themes/`. |
| `OMAMAC_DIR` | Install root. Resolved automatically; see below. |

The remaining `OMAMAC_*` variables (`OMAMAC_PS`, `OMAMAC_KILL`,
`OMAMAC_OSASCRIPT`, `OMAMAC_SIPS`, `OMAMAC_FETCH`, `OMAMAC_BAT`,
`OMAMAC_GIT`, `OMAMAC_DEFAULTS`, `OMAMAC_GHOSTTY`, `OMAMAC_NVIM`,
`OMAMAC_FCLIST`) exist so the test suite can substitute stubs for anything
that would touch the real machine. They work at runtime too, but that's not
what they're for.

### OMAMAC_DIR

Every `omamac-*` script finds its siblings through `OMAMAC_DIR`. The
dispatcher sets it from its own resolved location if unset, so running from a
checkout or from a Nix store path both work unconfigured. The Hammerspoon
host can't use the environment at all (GUI apps inherit no shell), so it
resolves, in order: a global `OMAMAC_DIR` Lua variable written into
`init.lua`, then the environment variable, then `~/personal/omamac`.

## How it works

```
bin/omamac            dispatcher; every verb is bin/omamac-<verb>
lib/                  colours (Omarchy's schema + mix), state, fetch, logging
render/               one script per target, all driven from colors.toml
themes/<name>/        vendored colors.toml + backgrounds.index
menu/menu.html        the menu, rendered in a WKWebView
hammerspoon/omamac.lua  hotkeys, the webview host, message plumbing
```

A theme switch renders Ghostty first and reloads it immediately — it's the
thing you're looking at — then runs the remaining renderers concurrently.

**Themes are vendored, backgrounds are not.** Each theme directory holds the
`colors.toml` and an index of its background filenames; the images and
preview screenshots are fetched on demand from a pinned upstream tag and
cached. Re-vendor with `tools/sync-themes`.

**Colour resolution is its own layer** (`lib/colors.sh`). Omarchy's `master`
branch uses a legacy `color0`–`color15` palette while the v4 release tags use
named colours (`red`, `bright_blue`, …) plus an explicit `mode`. Renderers
ask for whichever they want and an alias chain resolves it, so both schemas
work and a missing key degrades loudly instead of emitting an empty value.

### Adding a target

1. Write `render/<tool>`, taking a theme directory and wherever it should
   write. Use `omamac_hex_or_warn` for colours and `omamac_is_light` for
   light/dark. Rename generated files into place rather than writing in situ
   if anything might read them concurrently.
2. Add it to the concurrent block in `bin/omamac-theme`, with its own
   `wait`/`log_warn` pair so its failure is reported as its own.
3. Add checks to `bin/omamac-doctor` — including whether the pointer that
   makes it take effect is present.
4. Add `tests/render_<tool>_test.sh`, and a test in `tests/theme_test.sh`
   asserting a real theme switch writes it.

## Development

```bash
./tests/run
```

The suite is plain bash — no framework — and needs `node`, a Lua front-end,
`jq` and macOS's `plutil`. There's deliberately no flake `checks` output:
none of those exist in a Nix sandbox, and a check that can never pass is
worse than none.

Tests here are expected to be **mutation-checked**: break the thing on
purpose and confirm a test fails. This codebase has produced a long line of
tests that passed for the wrong reason — presence assertions that couldn't
detect a swap, a harness whose exit gate was swallowed by a subshell, a
colour comparison that couldn't see a reversed interpolation. If a test
didn't fail against a deliberate break, it isn't testing anything.

## Credits

Themes, colour schema, menu geometry, picker behaviour and thumbnail recipe
all come from [Omarchy](https://github.com/omacom/omarchy) by David
Heinemeier Hansson and contributors, MIT licensed. omamac vendors each
theme's `colors.toml` and fetches its backgrounds from a pinned release tag.
It is not affiliated with or endorsed by the Omarchy project.
