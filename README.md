# claude-rc-supervisor

> **Fork notes (igbenic):** forked from `mnasyrov/claude-rc-supervisor` at
> `0205c70` after a full read-through. Changes: `SESSION_PREFIX` (machine label
> in session names, so two Macs serving the same repo are distinguishable) and
> `setup-mac.sh` (one-shot installer: `RC_PREFIX=mbp ./setup-mac.sh`, or
> `RC_PREFIX=mini ./setup-mac.sh --always-on` for the always-on box).
> Don't press GitHub's "Sync fork" without reading the upstream diff first.

Always-on [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)
server for macOS: access every repository in your work folder from
claude.ai/code or the Claude mobile app, 24/7, even with the laptop lid closed.

## Why

A single `claude remote-control` process serves exactly one directory, and
worktree mode requires a git repository — one process cannot cover a folder
full of repositories. The supervisor ([supervisor.sh](supervisor.sh)) solves this:

- scans `WORK_DIR` (default `~/work`, up to 2 levels deep:
  `~/work/repo` and `~/work/group/repo`);
- keeps `claude remote-control --spawn worktree --no-create-session-in-dir`
  running for every git repository — each remote session gets an isolated
  git worktree;
- serves non-git folders without nested repositories in
  `--spawn same-dir` mode (disable with `SERVE_NON_GIT=0`);
- rescans the folder every `SCAN_INTERVAL` seconds: **new repositories are
  picked up automatically**, servers of removed ones are stopped, crashed
  ones (e.g. after a network outage longer than ~10 minutes) are restarted;
- automatically marks new repositories as trusted
  (`hasTrustDialogAccepted` in `~/.claude.json`) — otherwise Remote Control
  requires running `claude` once in the directory manually
  (disable with `AUTO_TRUST=0`);
- the supervisor itself runs as a launchd LaunchAgent: starts at login,
  auto-restarts on crash (`KeepAlive`).

`--no-create-session-in-dir` keeps restarts from creating new empty sessions
and cluttering the list on claude.ai/code; sessions are created only on
demand from claude.ai/code or the mobile app.

Claude Desktop is not required — Remote Control lives entirely in the CLI.

## Requirements

- macOS (the scripts are compatible with the system bash 3.2);
- [Claude Code CLI](https://code.claude.com/) ≥ 2.1.200, logged in with
  a subscription account;
- `jq` — for auto-trusting new repositories (without it, trust manually).

## Installation

```bash
git clone git@github.com:mnasyrov/claude-rc-supervisor.git && cd claude-rc-supervisor
./install.sh     # creates the config, installs the LaunchAgent, starts it
./status.sh      # check: supervisor state and the list of servers
./uninstall.sh   # stop everything and remove
```

## Configuration

Personal settings live **outside the repository** — in
`~/.claude-rc-supervisor.env` (bash syntax; `install.sh` creates it from
[claude-rc-supervisor.env.example](claude-rc-supervisor.env.example)).
Main parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `WORK_DIR` | `~/work` | Folder with repositories |
| `SCAN_INTERVAL` | `60` | Rescan period, seconds |
| `IGNORE_PATTERNS` | — | Glob patterns of folders to skip |
| `PERMISSION_MODE` | default | Permission mode of remote sessions (`acceptEdits`, …) |
| `SERVE_NON_GIT` | `1` | Serve non-git folders (same-dir) |
| `AUTO_TRUST` | `1` | Auto-accept the trust dialog for new repositories |
| `CLAUDE_BIN` | from `PATH` | Path to the `claude` binary |

After changing the config:

```bash
launchctl kickstart -k gui/$(id -u)/com.claude-rc-supervisor
```

Logs: `~/Library/Logs/claude-rc-supervisor/` — `supervisor.log` plus one
log per repository (rotated at 10 MB).

### Disable attribution (optional)

```bash
./disable-attribution.sh
```

Turns off Claude Code attribution — the `Co-Authored-By: Claude` trailer in
git commits and the "Generated with Claude Code" note in pull request
bodies — for all projects of the current user, including remote sessions
spawned by the supervisor. The script merges the following into
`~/.claude/settings.json`, keeping the rest of the file intact:

```json
{
  "attribution": {
    "commit": "",
    "pr": ""
  },
  "includeCoAuthoredBy": false
}
```

The `attribution` strings must be strings — empty removes the "Generated
with Claude Code" note — while `includeCoAuthoredBy: false` drops the
`Co-Authored-By: Claude` trailer.

## Running 24/7 (no sleep)

```bash
./setup-power.sh                       # configure pmset
./setup-power.sh --disable-spotlight   # + disable Spotlight indexing
./setup-power.sh --restore             # restore default settings
```

The script sets via `pmset`:

| Setting | Value | Meaning |
|---|---|---|
| `sleep` | `0` | Never sleep |
| `disablesleep` | `1` | Forbid sleep entirely, including lid closed |
| `displaysleep` | `5` | Turn the display off after 5 min (harmless) |
| `disksleep` | `0` | Never spin down disks |
| `autorestart` | `1` | Start automatically after a power failure |
| `lidwake` / `acwake` | `1` | Wake on lid open / power adapter connect |
| `womp` | `1` | Wake on LAN (with Ethernet) |
| `ttyskeepawake` | `1` | Stay awake while ssh sessions are active |
| `powernap` | `0` | Power Nap is pointless without sleep |
| `repeat wake 8:00` | daily | Safety-net wake-up |

With `disablesleep 1`, third-party utilities (Amphetamine, caffeinate) are
redundant.

Important:

1. **Power**: with the lid closed on battery the machine will not sleep,
   but it will drain — keep it plugged in.
2. **Auto-login**: the LaunchAgent starts after login. For self-recovery
   after a power failure enable auto-login
   (System Settings → Users & Groups → Automatically log in as…).
   Auto-login is incompatible with FileVault — either disable FileVault
   or log in manually after a reboot.
3. **Network**: after an outage longer than ~10 minutes remote-control
   processes exit on their own — the supervisor restarts them on the
   next scan.

## Security considerations

- **Everything in `WORK_DIR` becomes remotely accessible** from claude.ai/code
  and the Claude mobile app under your Claude account. Keep the folder to
  code you actually want reachable; exclude the rest via `IGNORE_PATTERNS`.
- **`AUTO_TRUST=1` (default) bypasses Claude Code's trust dialog** — a
  safety barrier that normally makes you confirm each new workspace. Any
  repository that appears in `WORK_DIR` (including a freshly cloned
  third-party one with potentially malicious `CLAUDE.md` or hooks) is
  trusted and served automatically. If untrusted content may land in your
  work folder, set `AUTO_TRUST=0` and accept new repositories manually by
  running `claude` in them once.
- **Avoid `PERMISSION_MODE=bypassPermissions`** for an always-on server:
  remote sessions would execute commands without any confirmation. Prefer
  the default mode or `acceptEdits`.
- Access to the servers is tied to your Claude account session; anyone who
  can sign in to your claude.ai account can open sessions on this machine.

## Resources

One server per repository — one node process (~100–300 MB RAM idle).
Exclude spare clones/sandboxes via `IGNORE_PATTERNS`.

## Files

| File | Purpose |
|---|---|
| [supervisor.sh](supervisor.sh) | The supervisor (core logic) |
| [claude-rc-supervisor.env.example](claude-rc-supervisor.env.example) | Config template (copied to `~/.claude-rc-supervisor.env`) |
| [install.sh](install.sh) | LaunchAgent installation + start |
| [uninstall.sh](uninstall.sh) | Stop and remove |
| [status.sh](status.sh) | Supervisor and server status |
| [setup-power.sh](setup-power.sh) | macOS setup for 24/7 operation |
| [disable-attribution.sh](disable-attribution.sh) | Optional: disable Claude attribution in commits/PRs |

## License

[MIT](LICENSE)
