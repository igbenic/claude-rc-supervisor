# claude-rc-supervisor

> **Fork notes (igbenic):** forked from `mnasyrov/claude-rc-supervisor` at
> `0205c70` after a full read-through. Changes: `SESSION_PREFIX` (machine label
> in session names, so two Macs serving the same repo are distinguishable) and
> `setup-mac.sh` (one-shot installer: `RC_PREFIX=mbp ./setup-mac.sh`, or
> `RC_PREFIX=mini ./setup-mac.sh --always-on` for the always-on box), and
> [session self-healing](#session-self-healing) (orphaned sessions are
> reattached, idle sleep is blocked while sessions run).
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
- reattaches sessions that a server exit left orphaned and keeps the Mac
  awake while sessions run (see [Session self-healing](#session-self-healing));
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
| `REATTACH` | `1` | Reattach sessions orphaned by a server exit |
| `REATTACH_WINDOW` | `14400` | Seconds a session stays reattachable |
| `REATTACH_MAX_ATTEMPTS` | `5` | Failed reattach attempts before giving up on a session |
| `KEEP_AWAKE` | `1` | `caffeinate -i` while any remote session is active |

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
   next scan and reattaches their sessions (see below).

## Session self-healing

When a `claude remote-control` server exits — the laptop slept and had no
network for ~10 minutes (`Persistent errors for 10 minutes, giving up`), or
the supervisor was restarted — it takes its running sessions down with it.
The restarted server registers a **new** environment, so those sessions stay
"Can't reach <host>" in the app forever, even though the machine is back.

The supervisor heals this:

1. On every scan it reads the newest status block of each server log and
   records the active sessions in `$STATE_DIR/<repo>.sessions`
   (session ID + the session's worktree `.claude/worktrees/bridge-cse_<id>`).
2. When a server is found dead (or the supervisor starts after being
   stopped), each recorded session is reattached with
   `claude remote-control --session-id <id>` in its worktree. The session
   shows up in the app again with its full history.
3. A reattach process that gives up as well is restarted, up to
   `REATTACH_MAX_ATTEMPTS` times (the counter resets after 10 stable
   minutes). When the session ends normally, the entry is dropped.
   Sessions last seen more than `REATTACH_WINDOW` seconds ago are skipped —
   the CLI only allows reattaching for roughly 4 hours.
4. While any session is active, `caffeinate -i` keeps the Mac from
   idle-sleeping, on battery too; it is released when the last session
   ends. Closing the lid on battery still sleeps — step 2 covers that.

`./status.sh` lists active and reattached sessions; logs of reattach
processes are `reattach-<session id>.log`. Test: `tests/reattach-test.sh`
(uses a fake `claude`, touches no real sessions).

To reattach a session by hand (e.g. one orphaned before this existed):

```bash
cd <repo>/.claude/worktrees/bridge-cse_<id without "session_">
claude remote-control --session-id session_<id>
```

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
| [tests/reattach-test.sh](tests/reattach-test.sh) | End-to-end test of session self-healing (fake `claude`) |

## License

[MIT](LICENSE)
