# omamac

A macOS theming tool that restyles Ghostty, Neovim, btop, bat, the system
appearance and the wallpaper from a single theme definition, plus a
Hammerspoon-hosted menu (22 real vendored Omarchy v4.0.2 themes).

Press **⌘⌥O** to open the theme menu — pick a theme, font, or wallpaper
and every configured target re-renders live. **⌘⌃Space** cycles the
wallpaper for the current theme without opening the menu.

> **Why ⌘⌥O and not ⌘⌥Space?** macOS reserves ⌥⌘Space for "Show Finder search
> window". Disabling that preference does not release the already-running
> registration without a re-login, so Hammerspoon's bind fails with
> `RegisterEventHotKey failed: -9878`. ⌘⌥O is free and needs no logout. If you
> prefer the Omarchy-faithful chord, disable the Finder shortcut, log out and
> back in, then change the `hs.hotkey.bind` line in `hammerspoon/omamac.lua`.

## CLI

```bash
omamac <command> [args]
  theme [name|--list|--current]
  font [name|--list|--current]
  bg [file|--next|--list|--current]
  menu-data
  preview <wallpaper>
```

`theme <name>` re-renders Ghostty, Neovim, btop, bat and the system
appearance for that theme and records it as current. A missing target (e.g.
a tool that isn't installed) is a warning, not a failure — the only hard
failure is the theme itself being unresolvable. `menu-data` and `preview`
are what the Hammerspoon host calls internally; you won't normally run them
by hand.

## Installing

### Nix / home-manager (this machine)

`~/.dotfiles` wires this repo in as a flake input and a home-manager module
(`home/programs/omamac/omamac.nix`) that puts `omamac` on `PATH` and writes
`~/.hammerspoon/init.lua` to load the Hammerspoon host. That module is gated
like every other program module in that repo: `bin/rebuild` alone does
**not** turn it on. To actually get omamac running via Nix:

1. Set `dotfiles.programs.omamac.enable = true;` in
   `~/.dotfiles/home/users/pedroribeiro.nix`. Without this,
   `home/lib/mkHomeModule.nix` gates the whole module off (it defaults to
   `false`, same as every other `dotfiles.programs.<name>.enable`), and
   `bin/rebuild` will silently do nothing for omamac.
2. Install Hammerspoon yourself first — the module manages no Homebrew cask,
   only the package and the generated `init.lua` (`brew install --cask
   hammerspoon`, or via nix-darwin/home-manager if you prefer).
3. **Back up your current `~/.hammerspoon/init.lua`** before rebuilding.
   `home.file` overwrites it unconditionally, and if you already have one
   (e.g. holding an older omamac host), that content is gone once
   `bin/rebuild` runs.
4. Run `bin/rebuild` in `~/.dotfiles` to activate the home-manager
   generation, install `omamac` onto `PATH`, and regenerate
   `~/.hammerspoon/init.lua`.
5. Launch Hammerspoon and grant it **Accessibility** permission when macOS
   prompts (System Settings > Privacy & Security > Accessibility > enable
   Hammerspoon) — required on this path exactly as on the Homebrew path
   below.
6. Press ⌘⌥O.

**The flake input is a local path.** omamac has not been published anywhere,
so `~/.dotfiles/flake.nix` currently points at it as
`git+file:///Users/pedroribeiro/personal/omamac`. That will not resolve on
any other machine. Once this repo is pushed to a Git host, change the input
to a real URL (e.g. `github:pedroribeiro/omamac`) and re-run `nix flake lock
--update-input omamac` in `~/.dotfiles`.

### Homebrew (non-Nix)

```bash
./install
```

Installs `jq` and Hammerspoon via Homebrew, symlinks `bin/omamac` into
`~/.local/bin`, and writes `~/.hammerspoon/init.lua` (unless one already
exists — in that case it prints the one line to add by hand instead of
overwriting your file). After it runs:

1. Launch Hammerspoon and grant it **Accessibility** permission when macOS
   prompts (System Settings > Privacy & Security > Accessibility).
2. Press ⌘⌥O.

## Wiring individual tools

Most targets (Ghostty, btop, bat, macOS appearance) are re-rendered directly
into files those tools already read, so nothing further is needed once a
theme has been applied once. Two need one line added to their own config,
because omamac writes to a file that has to be explicitly included/loaded:

**Ghostty** — append as the **last** line of `~/.config/ghostty/config` (it
must come after any other `config-file` includes, since later values win):
```
config-file = ?omamac.conf
```

**Neovim** — append to your `init.lua`:
```lua
-- omamac: load the generated colorscheme, and expose a socket so a theme
-- switch can reload it live.
local omamac_theme = os.getenv("HOME") .. "/.local/state/omamac/current/omamac.lua"
if vim.uv.fs_stat(omamac_theme) then pcall(dofile, omamac_theme) end
local sockdir = os.getenv("HOME") .. "/.cache/nvim/servers"
vim.fn.mkdir(sockdir, "p")
pcall(vim.fn.serverstart, sockdir .. "/" .. vim.fn.getpid() .. ".sock")
```
The socket lets a theme switch push the new colorscheme into every running
Neovim instance instead of only the next one you open.

If your config also has something like `vim-lumen` watching the macOS
appearance to switch colorschemes on its own (e.g. between a light and dark
variant of a different theme plugin), point its light/dark callbacks at
omamac's generated colorscheme too, not at that other theme — otherwise it
will win the race on every light↔dark flip and clobber whatever omamac just
rendered. The other theme plugin can stay installed as a fallback for before
omamac's state file exists (a fresh machine, or before the first `omamac
theme` run); vim-lumen's job is only to signal *when* the appearance flips,
never to decide *what* colorscheme to apply once omamac is in the picture.

**bat** — point the `cat` alias at the generated theme, e.g. in your shell rc:
```bash
alias cat='bat -p --theme=omamac'
```

On this machine, `~/.dotfiles` already carries all three edits.

## OMAMAC_DIR

Every `omamac-*` script resolves its siblings through `OMAMAC_DIR`. The CLI
dispatcher (`bin/omamac`) sets it from its own resolved location if unset, so
running it from a checkout or from a Nix store path both work with no
configuration.

The Hammerspoon host (`hammerspoon/omamac.lua`) cannot rely on a shell
environment variable, because GUI apps launched through LaunchServices
inherit no shell rc exports — `home.sessionVariables` in home-manager, or an
export in `.zshrc`, is invisible to `Hammerspoon.app`. It resolves
`OMAMAC_DIR` in this order:
1. A global `OMAMAC_DIR` Lua variable, set by whatever wrote `init.lua`
   (home-manager writes the Nix store path in literally; `./install` writes
   the checkout path the same way).
2. The `OMAMAC_DIR` environment variable, for non-GUI invocations.
3. `~/personal/omamac`, as a last resort.

## Checking it works

`omamac doctor` verifies that every target actually reflects the current
theme, and exits non-zero if any does not:

```bash
omamac doctor
```

It is read-only: it never re-renders and never repairs. Drift is the finding,
and a diagnostic that fixes what it inspects can never tell you something was
wrong. Most failures it reports are cleared by re-applying the theme:

```bash
omamac theme "$(omamac theme --current)"
```

Beyond checking that generated files exist, it asks whether each artefact
carries the *current* theme's colours, whether the pointer that makes it take
effect is in place (Ghostty's `config-file` include, btop's `color_theme`,
Claude's `custom:omamac`, delta's `[include]`), and whether the tool itself
can see it — `bat`, for instance, only uses themes it has compiled into its
cache, so a perfectly correct `.tmTheme` can still be invisible.

## Development

Run tests with:
```bash
./tests/run
```

Build the Nix package:
```bash
nix build .#
./result/bin/omamac theme --list
```
