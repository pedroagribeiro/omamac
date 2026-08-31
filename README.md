# omamac

A macOS theming tool that restyles Ghostty, Neovim, btop, bat, the system
appearance and the wallpaper from a single theme definition, plus a
Hammerspoon-hosted menu (22 real vendored Omarchy v4.0.2 themes).

Press **⌘⌥Space** to open the theme menu — pick a theme, font, or wallpaper
and every configured target re-renders live. **⌘⌃Space** cycles the
wallpaper for the current theme without opening the menu.

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
(`home/programs/omamac/omamac.nix`). It puts `omamac` on `PATH` and writes
`~/.hammerspoon/init.lua` to load the Hammerspoon host. Running `bin/rebuild`
in `~/.dotfiles` activates it — see the dotfiles README/that repo's own docs
for what that entails.

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
2. Press ⌘⌥Space.

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
