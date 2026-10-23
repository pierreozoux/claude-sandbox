# claude-sandbox

Run [Claude Code](https://code.claude.com) in a throwaway Docker container that
sees only the current project, while reusing the host's Nix store and
nix-daemon. As a result, `flake.nix`, `shell.nix` and `.envrc` dev shells work
inside the container with nothing to download again.

It is for Linux hosts with multi-user Nix and rootful Docker, and is written as a
zsh function.

[Tutorial](#tutorial) · [How-to guides](#how-to-guides) · [Reference](#reference) · [Explanation](#explanation)

---

## Tutorial

### Your first sandboxed session

In this tutorial you build the image, open a project in the sandbox, and see
what the container can and cannot touch.

You need: Linux, Docker (with your user in the `docker` group), Nix in
multi-user (daemon) mode, and zsh.

1. Clone this repository, then install: this builds the image with your own
   uid/gid, and sets up Claude's global config in `~/.config/claude-sandbox`:

   ```sh
   git clone https://github.com/pierreozoux/claude-sandbox ~/src/claude-sandbox
   cd ~/src/claude-sandbox
   nix develop -c just install
   ```

   If you already use Claude Code on this machine, the installer offers to
   import what it learned in `~/.claude` (your `CLAUDE.md`, skills, agents,
   commands, and each project's memory). Opus reviews each part first, and you
   accept or reject it.

2. Load the function in your shell, and add the same line to `~/.zshrc`:

   ```sh
   source ~/src/claude-sandbox/claude-sandbox.zsh
   ```

3. Go to a project that has a `flake.nix` or a `shell.nix`, and start a shell
   in the sandbox:

   ```sh
   cd ~/src/some-project
   claude-sandbox bash
   ```

   You get a bash prompt inside the project's dev shell, at the same path as on
   your host.
   Run `which` on one of the project's tools: the path is in `/nix/store`,
   served read-only from the host.

4. Look around:

   ```sh
   ls ~          # an empty home, not yours
   ls ..         # only this project
   git log -1    # works; commits are made as you
   ```

5. Start Claude and log in. The login is stored in
   `~/.config/claude-sandbox/auth` on the host, shared by all sessions, so you
   do it only once:

   ```sh
   claude
   ```

   Ask Claude to remember a preference for all your projects, for example
   "always write commit messages in Conventional Commits format, in the global
   CLAUDE.md".

6. Leave Claude, then the shell. The container is removed. If Claude left
   anything your host might run without asking, such as a nested git
   repository or a changed `.envrc`, the wrapper lists it. Then it shows you
   what Claude changed in its global config, with Opus's review of it, and asks
   you to accept it: press `a`. It also shows the email address of the account
   you logged in with, and asks you to confirm it: from then on, a change of
   account is caught.

From now on, `claude-sandbox` alone starts Claude directly in the dev shell,
and every session, in every project, starts with the preference you accepted.

---

## How-to guides

### Pass arguments to Claude, or run something else

```sh
claude-sandbox claude --resume
claude-sandbox claude --dangerously-skip-permissions
claude-sandbox bash
```

Arguments after the options are run inside the dev shell. Use `--` if your
command itself starts with `--`.

### Work in a git worktree

Use Claude Code's own option:

```sh
claude-sandbox claude --worktree my-task      # or -w; the name is optional
```

Claude works in `.claude/worktrees/my-task`, on a new branch
`worktree-my-task`. Claude Code starts that branch from the remote's default
branch, which it fetches first, not from the branch you are on. When the
session ends, it asks whether to keep the worktree. Add `.claude/worktrees/`
to the project's `.gitignore`, so your main checkout does not list it.

The container sees the project at the same path as your host, so the
worktree works on both sides: `cd` into it on the host, or merge its branch
from your main checkout. Worktrees you make on the host inside the project
work in the sandbox too; those outside the project do not, since the container
cannot see them.

### Give Claude access to a kind cluster

```sh
claude-sandbox --kind my-cluster claude
```

The container joins the `kind` Docker network and gets that cluster's kubeconfig
(and no other) at `~/.kube/config`, read-only. It is a **cluster-admin**
kubeconfig, so only use this with throwaway clusters.

### Update everything

Auto-update is disabled inside the container, so updates go through one command:

```sh
just update
```

This pins the Dockerfile to the current `debian:trixie-slim` digest, runs
`nix flake update`, pins the latest Claude Code release with its checksums, and
rebuilds the image without the cache. It ends with a summary of what changed in
`Dockerfile` and `flake.lock`: review it, run `just test`, then commit. It also
reminds you to check the [Nix security advisories](https://github.com/NixOS/nix/security/advisories)
and update the wrapper's list of vulnerable daemon versions.

To install a specific Claude Code version instead:
`just pin-claude 2.1.170 && just build`.

### Teach Claude something for all your projects

Ask Claude in any session to change its global config: `CLAUDE.md`,
`settings.json` (permissions, for example), skills, agents, commands or hooks.
It edits its own copy, and when the session ends the wrapper asks you:

```
claude-sandbox: app-1a2b3c4d-4242-1792750000123456 changed Claude's global config (all projects):
 CLAUDE.md | 1 +
  asking Opus to review it...
  Opus: harmless
    - adds a commit message convention: an ordinary preference
  [a]ccept, [r]eject, [d]iff, [l]ater?
```

- `a` merges it into `~/.config/claude-sandbox/config`: later sessions get it.
- `r` drops it. `d` shows the diff. `l` (or no answer) keeps it for later: the
  next `claude-sandbox` you start in a terminal asks again, before its session
  starts.

When Opus finds the change suspicious, when it could not review it, or when the
change has anything that runs code (hooks, `settings.json`, an executable, a
skill's `hooks:` or `allowed-tools:`, an inline `` !`command` ``, URLs, invisible
Unicode), the wrapper shows you the whole diff before asking. See
[Claude's configuration](#claudes-configuration) for why you, not Opus, decide.

Memory is different: Claude writes it without review, but only for the project
it is in.

### Change Claude's config by hand

`~/.config/claude-sandbox/config` is a git repository. Edit it and commit:

```sh
cd ~/.config/claude-sandbox/config
$EDITOR CLAUDE.md
git commit -am "Prefer tabs"
```

Sessions start from its last commit. While it has uncommitted changes, the
wrapper does not merge accepted changes into it, and keeps them waiting. `git
log` shows every change you accepted, and `git revert` undoes one.

### Install a plugin

Plugins are too big to review as a diff, so `~/.claude/plugins` is read-only.
Start one deliberate session with the plugins writable, in a project you trust:

```sh
claude-sandbox --config-rw claude
```

and install the plugin there. Enabling it changes `settings.json`, which you
review at the end like any other change.

### Recover from a session that died

If you close the terminal or kill the shell while a session runs, the wrapper
cannot clean up. The next `claude-sandbox` you start finds the session's copy
of the config, saves what it changed as a pending change (you review it as
usual), and removes the copy. A copy whose wrapper or container still runs is
left alone.

If saving a session's changes fails, the wrapper keeps its copy in
`~/.config/claude-sandbox/failed/` and says so: look at it, copy what you want
into `config/`, and commit.

### When the wrapper quarantines your login

After your first login, the wrapper shows the account's email address and asks
you to confirm it, then records the account. Whenever the login changes after
that (a token refresh does this every few hours), the wrapper asks Anthropic
which account it belongs to. It quarantines the login when it is another
account, when Anthropic rejects it, when it is not written the way Claude Code
writes it, or when its refresh token changed without its access token. Any of
these means a session probably replaced it, for example to sign every later
session into an account that receives your prompts and code. The login goes to
`~/.config/claude-sandbox/quarantine`, and the next session asks you to log in
again.

If you switched accounts yourself, delete `~/.config/claude-sandbox/account`
and log in again: you confirm the new account.

### Harden your host git against planted repositories

The sandbox protects the project's own `.git` (see [Git](#git)). It cannot stop
Claude from *creating* new repositories inside the project. Make your host git
ignore embedded bare repositories:

```sh
git config --global safe.bareRepository explicit
```

When the wrapper reports a nested `.git`, check its `config` before you `cd`
into that directory. Your prompt's git integration runs git there as soon as you
enter it.

### Review a session's changes safely

1. Read the wrapper's report printed after the session ends.
2. Run `git status` and `git diff` at the project root. This is safe, because the
   root's config and hooks were read-only.
3. Read changes to anything your machine runs without asking (`.envrc`,
   `flake.nix` `shellHook`, `justfile`, `Makefile`, `package.json` scripts,
   `.vscode/`, CI files) *before* you `cd` into subdirectories, run `direnv allow`,
   or run builds and tests on the host.
4. Read changes to what the next Claude session in this project loads: the
   project's `.claude/` (settings, hooks, skills), `.mcp.json`, `CLAUDE.md` and
   `CLAUDE.local.md`. Unlike the global config, these are not reviewed for you.

### Free disk space

Each project has its own cache volume:

```sh
docker volume ls --filter name=claude-cache-
docker volume rm claude-cache-<project>-<hash>
just clean-volumes          # all of them
```

Claude's sessions and memory for each project are in
`~/.config/claude-sandbox/projects/<project>-<hash>/`, and its `claude.json` and
prompt history in `~/.config/claude-sandbox/state/<project>-<hash>/`. Both can
be deleted the same way.

### Run the tests

From the repository, inside the dev shell (`nix develop`, or direnv):

```sh
just test
```

This runs the lint and the unit tests with `nix flake check`, in the Nix build
sandbox, then builds the image and runs the integration tests against real
containers. Nix only sees files that git tracks, so `git add` new files first.

To also test `--kind`, point it at a throwaway cluster:
`CLAUDE_SANDBOX_TEST_KIND=my-cluster just test`.

### Use a different Docker daemon

```sh
CLAUDE_SANDBOX_DOCKER_HOST=unix:///run/other/docker.sock claude-sandbox
```

The daemon must not remap uids, otherwise files in the project end up owned by
another uid, and the nix-daemon sees a user other than you. Rootless Docker
therefore does not work as is. For rootless engines in general, see
[Why rootful Docker](#why-rootful-docker-with-no-uid-remapping).

---

## Reference

### Command

```
claude-sandbox [--kind NAME] [--config-rw] [--] [command [args...]]
```

| Option | Effect |
|---|---|
| `--kind NAME` | Join the `kind` network and mount the kubeconfig of cluster `NAME` read-only. |
| `--config-rw` | Make `~/.claude/plugins` writable, to install or update plugins. |
| `--` | End of options. |
| `command` | What to run in the dev shell. Default: `claude`. |

The wrapper refuses to start in `$HOME` or `/`, when the path contains `:`,
under a directory the container needs (`/nix`, `/usr`, `/etc`, `/bin`, `/sbin`,
`/lib*`, `/proc`, `/sys`, `/dev`, `/run`, `/boot`, the container's home
`/home/claude` or what contains it, and its `.claude`, `.claude-auth`, `.cache`,
`.local` and `.kube`), or before `just install` (no `~/.config/claude-sandbox/config`). The return value
is the container's exit status.

### Files on the host

In `~/.config/claude-sandbox`:

| Path | What | Seen by sessions |
|---|---|---|
| `config/` | Git repository of the approved global config: `CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`, `commands/`, `skills/`, `hooks/`, `output-styles/`, `agent-memory/`. Branches `session/*` are changes waiting for review. | never directly |
| `sessions/<id>-<pid>-<time>/` | One running session's copy of `config/`, with `.base`, `.index`, `.lines` and `.lock` files next to it. Removed when the session ends. | as `~/.claude`, rw |
| `auth/` | The login (`.credentials.json`, and `.device-keys.json` if Claude Code writes one), shared by all sessions. Anything else is removed. | rw |
| `account`, `auth.verified` | The account you confirmed at the first login, and the sha256 of the login (file, access token, refresh token) as last checked. | no |
| `quarantine/` | Logins that were not your account. | no |
| `failed/` | Copies of sessions whose changes could not be saved. | no |
| `plugins/` | Installed plugins. | ro, rw with `--config-rw` |
| `projects/<name>-<hash>/` | Transcripts and auto-memory, per project. | rw, its own only |
| `state/<name>-<hash>/` | `claude.json` and `history.jsonl` (prompt history), per project. | copied in and out |
| `claude.json.template` | What a new project's `claude.json` starts from: the previous shared one, without projects or MCP servers. | no |
| `review.lock` | Held while one terminal reviews, so two do not merge at once. | no |
| `kind-NAME.kubeconfig` | Written by `--kind NAME`. | ro, with `--kind` |

### Environment variables (host)

| Variable | Default | Effect |
|---|---|---|
| `CLAUDE_SANDBOX_DOCKER_HOST` | `unix:///var/run/docker.sock` | Docker daemon to use. |
| `CLAUDE_SANDBOX_IMAGE` | `claude-sandbox` | Image to run (and to build/test with `just`). |
| `CLAUDE_SANDBOX_MEMORY` | `8g` | Container memory limit (`docker run --memory`). |
| `CLAUDE_SANDBOX_ALLOW_TRUSTED` | unset | Start even if the nix-daemon lists you in `trusted-users` (see [Nix](#nix)). |
| `CLAUDE_SANDBOX_IMPORT_FROM` | `~/.claude` | What `just install` imports from; empty imports nothing. |

### Build arguments

| Argument | Default | Effect |
|---|---|---|
| `UID`, `GID` | `1000` | Must match `id -u` / `id -g` on the host. |
| `CLAUDE_VERSION`, `CLAUDE_SHA256_X64`, `CLAUDE_SHA256_ARM64` | pinned | Claude Code version and binary checksums. Set them with `just pin-claude`. |

### Mounts

| Host | Container | Mode |
|---|---|---|
| project (`$PWD`) | the same path, symlinks resolved | rw |
| `<project>/.git` | same path | rw, as its own mount |
| `.git/config`, `.git/hooks`, and the same for each submodule in `.git/modules/` | same paths | **ro** |
| `config.worktree` (when `extensions.worktreeConfig` is on), `.git/worktrees/*/{commondir,config.worktree}` | same paths | **ro** |
| `/nix/store` | `/nix/store` | **ro** |
| `/nix/var/nix/daemon-socket` | same | rw (socket) |
| `~/.config/claude-sandbox/sessions/<session>` (this session's copy of the config) | `~/.claude` | rw, reviewed when the session ends |
| `~/.config/claude-sandbox/auth` | `~/.claude-auth` (`CLAUDE_SECURESTORAGE_CONFIG_DIR`) | rw, shared |
| `~/.config/claude-sandbox/plugins` | `~/.claude/plugins` | **ro** unless `--config-rw` |
| `~/.config/claude-sandbox/projects/<name>-<hash>` | `~/.claude/projects` | rw, one per project |
| `~/.config/claude-sandbox/kind-NAME.kubeconfig` | `~/.kube/config` | **ro**, with `--kind` only |
| session instructions, generated by the wrapper | `/etc/claude-code/CLAUDE.md` | **ro** |
| volume `claude-cache-<name>-<hash>` | `~/.cache` | rw, one per project |

### Container settings

`--rm --init --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=2048 --memory=8g`
(the memory limit is `CLAUDE_SANDBOX_MEMORY`),
network `bridge` (or `kind`), no sudo in the image, and no Docker socket.

Environment: `PATH` starts with the host's nix binary; `NIX_PATH=nixpkgs=` the host's
`<nixpkgs>`; `NIX_REMOTE=daemon`; flakes enabled; `GIT_AUTHOR_*` and `GIT_COMMITTER_*`
from your host git identity; `DISABLE_AUTOUPDATER=1`.

### Dev shell selection (entrypoint)

The first match wins:

1. `.envrc`: it is allowed automatically, then the command runs with `direnv exec .`.
2. `flake.nix`: `nix develop --command …`
3. `shell.nix` or `default.nix`: `nix-shell --run …`
4. Otherwise, the command runs as is.

A bare `bash` is replaced by `/bin/bash`, the image's interactive bash.

### Pre-flight checks

| Check | Result |
|---|---|
| `nix` not on host `PATH` | Refuses to start. |
| `nix store info` reports `Trusted: 1` | Refuses to start, unless `CLAUDE_SANDBOX_ALLOW_TRUSTED=1`. |
| Daemon is Nix 2.x older than 2.28, or older than the CVE-2026-39860 fix for its series | Warning. |
| That list of vulnerable versions was checked more than 6 months ago | Warning: update claude-sandbox. |
| Host git has no `user.name` / `user.email` | Warning. |
| `.git` is a file (linked worktree or submodule checkout) | Warning: its config is not protected. |
| No `~/.config/claude-sandbox/config` | Refuses to start: run `just install`. |
| A session's copy of the config whose wrapper and container are gone | Its changes become a pending change, and the copy is removed. |
| The project's sessions, memory, trust or prompt history are still kept under `/work/<name>-<hash>`, where earlier versions mounted it | Moved to the project's path, unless something is there already. |
| The login changed since it was last checked | Checked against the recorded account (see below). |
| Changes to the config wait for review, and there is a terminal | Reviewed before the session starts. |

### Post-session report and review

| Finding | Action |
|---|---|
| The session changed the config (`CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`, `commands/`, `skills/`, `hooks/`, `output-styles/`, `agent-memory/`) | Committed on a branch `session/<id>` (dots in the id become `_`), then reviewed: Opus's verdict and notes, flags (below), then `[a]ccept, [r]eject, [d]iff, [l]ater`. Without a terminal, it waits. |
| A `.git` or `.gitattributes` inside those directories (a cloned skill, say) | Dropped before the commit, and listed: the skill's files are kept. |
| Saving the change fails | The copy is moved to `failed/`, with a warning. |
| Anything else written in `~/.claude` (`plans/`, `todos/`, `file-history/`, …) | Dropped with the copy. |
| The session added MCP servers to the project's `claude.json` | Listed. |
| Anything in `auth/` but the login files | Removed, and listed. |
| The login changed: another account, rejected by Anthropic (401/403), not valid JSON, a new refresh token with the old access token, not a regular file | Moved to `quarantine/`, with a warning. |
| The login changed and could not be checked (offline, curl missing) | Warning; checked again next time. |
| First login | You confirm the account, shown by its email address; without a terminal, it waits. |

Flags, which show the whole diff whatever Opus says: changes in `hooks/` or
`settings.json`, an executable file, a symlink, a nested repository, a binary
file, skill or agent frontmatter with `hooks`, `allowed-tools`, `shell`,
`mcpServers` or `permissionMode` (quoted or not), an inline `` !`command` ``
or a fenced ```` ```! ```` block, `curl`, `wget`, a URL, `base64` or a pipe
into a shell, an
`@import` (it loads a file the diff does not show), a mention of
`.claude-auth`, `/nix/store` or `.cache` (places other sessions can write),
and zero-width, bidirectional, variation-selector, soft-hyphen, line-separator
or tag Unicode characters. Diffs, Opus's answer, and every name a session
chose (files left in `auth/` or in the project) are shown with control
characters replaced by `?` (so no escape sequence reaches your terminal), and
with `cat -v` when invisible characters were found. Git on the config ignores
your global and system git config, so that `diff.noprefix` or a filter driver
cannot change what the flags see or run on what a session wrote.

The login is read with `jq` (yours, or the image's when you have none), the
way Claude Code reads it: only `claudeAiOauth`, not the MCP servers' tokens
stored next to it, and with the last of duplicate keys. It is checked before
and after the reviews, since the reviewer's container can refresh it.

### Post-session report on the project

| Finding | Action |
|---|---|
| `.git/commondir` exists | It is renamed to `commondir.quarantined`. |
| Nested `.git` (directory or file) or bare-repository layout | Listed, except a worktree of the project's repository: its `.git` is exactly `gitdir: <project>/.git/worktrees/<name>`, nothing on that path is a symlink, the gitdir links back to it, `commondir` is `../..`, and there is no `config.worktree`. |
| `.envrc`, `flake.nix`, `shell.nix`, `default.nix`, `justfile`, `Makefile`, `package.json`, `.gitattributes`, `.gitmodules`, `.pre-commit-config.yaml`, `.vscode/*`, `.github/workflows/*` modified during the session | Listed. |
| `.claude/*`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md` modified during the session | Listed: the next session in this project loads them. |

### Development

| File | Purpose |
|---|---|
| `claude-sandbox.zsh` | The wrapper: pre-flight checks, mounts, the post-session report. |
| `config.zsh` | Claude's reviewed global config: sessions' copies, recovery, review, merge, and the login check. Sourced by the wrapper. |
| `install.zsh` | `just install`: the layout, the migration from the read-only layout, and the import from `~/.claude`. |
| `TODO.md` | What to build next: the credential and egress proxy. |
| `flake.nix` | Dev shell (`just`, `zsh`, `git`, `jq`, `shellcheck`, `kind`; Docker comes from the host) and `checks` (lint, unit tests). |
| `.envrc` | `use flake`: direnv loads the dev shell when you `cd` in (after `direnv allow`). |
| `justfile` | The recipes below. |
| `tests/lib.zsh` | Test harness. Each `test_*` function runs in a subshell, in its own temporary directory, and stops at its first failing command. |
| `tests/unit.zsh` | Wrapper, config review, installer and entrypoint logic. `docker` (including the reviewer), `curl`, `nix`, `nix-instantiate` and `kind` are stubs, the prompts are scripted, and `PATH` holds only the tools needed. |
| `tests/integration.zsh` | Real containers: privileges, git protection, config changes waiting for review, the shared login directory, dev shells, the nix-daemon's view of you. Uses a temporary `HOME`, makes no API calls, and removes the cache volumes it creates. |

| Recipe | Does |
|---|---|
| `just install` | `build`, then set up `~/.config/claude-sandbox`, migrate the read-only layout of earlier versions, and import from `~/.claude` after review. Safe to run again. |
| `just build [flags]` | `docker build` for your uid/gid; extra flags go to `docker build`. |
| `just update` | Pin the base image to the current `debian:trixie-slim` digest, `nix flake update`, `pin-claude`, then `build --no-cache`. |
| `just pin-claude [VERSION]` | Pin Claude Code to `VERSION` (default: the latest release) and its checksums in the `Dockerfile`. |
| `just test` | `nix flake check` (shellcheck, `zsh -n`, unit tests), then `build` and the integration tests. |
| `just clean-volumes` | Remove every `claude-cache-*` volume. |

Integration test variables: `CLAUDE_SANDBOX_TEST_KIND` (cluster for the
`--kind` test, which is skipped otherwise), and `NIXPKGS_PATH` (nixpkgs for the
dev-shell fixtures; the dev shell sets it, and it falls back to `<nixpkgs>`).

---

## Explanation

### Threat model

The sandbox assumes Claude may be **prompt-injected**, for example by a README,
an issue, or a dependency, and may then try to do harm with the access it has.
The goals, from strongest to weakest:

1. **The rest of the host is out of reach.** Your home directory, SSH keys,
   cloud credentials, other projects and the Docker daemon are not mounted.
2. **Your tools do not run what Claude planted.** Host git must not run
   hooks or config written by Claude.
3. **Sessions do not contaminate each other.** One project's session must
   not change how Claude behaves in the next project without you accepting
   it. This goal has known gaps, listed in
   [Claude's configuration](#claudes-configuration).

What it does **not** try to do:

- **Protect the project itself.** Claude can rewrite any file in it. Anything
  your host later runs from the project (dev shells, builds, tests, editor tasks)
  runs code Claude may have written. The post-session report points at the
  usual suspects. It relies on mtimes, which a deliberate attacker can forge,
  so reading the diff is still your job.
- **Stop exfiltration.** The container has unrestricted network access (see below).
- **Withstand kernel or nix-daemon exploits.** It is a container, not a VM.

### Nix

The host's `/nix/store` is mounted read-only, and builds go through the host
nix-daemon's socket. That is what makes the sandbox fast and lets it share the
store, and it has consequences:

- **The daemon runs as root, and the container can talk to it.** Builds run on
  the host, in the daemon's own build sandbox, as `nixbld` users. The daemon
  has had privilege escalations reachable by any user allowed to build:
  [CVE-2024-27297](https://nvd.nist.gov/vuln/detail/cve-2024-27297),
  [CVE-2025-52991/52992/52993](https://nvd.nist.gov/vuln/detail/cve-2025-52992),
  [CVE-2026-39860](https://discourse.nixos.org/t/nix-security-advisory-privilege-escalation-via-symlink-following-during-fod-output-registration/76900).
  Keep the host's Nix up to date. The wrapper warns about known-bad versions.
- **Being a trusted user is equivalent to being root.** Trusted users can turn
  off the build sandbox or use unsigned substituters, and the daemon sees the
  container as you, because the uids are the same. Tools like devenv and Cachix
  often ask you to add yourself to `trusted-users`, so the wrapper refuses to
  start in that case.
- **Fixed-output derivations reach the network from the host.** They bypass the
  container's network entirely, including your LAN, services on the host's
  `localhost`, and the kind API server.
- **The whole store is readable.** That includes anything that ended up in it,
  such as secrets in a NixOS configuration.

With these risks the trade is good for your own projects and dependencies you
mostly trust. For truly hostile code, use a VM.

### Git

You want Claude to commit, so `.git` has to be writable. You also want host
git (and your prompt, which runs git in every directory you enter) not to run
anything Claude wrote. Git runs code from a few places: hooks, and config keys
such as `core.fsmonitor`, `core.hooksPath`, `core.pager`, `diff.external`, and
filter drivers. The wrapper therefore makes these read-only:

- `.git/config` and `.git/hooks`, for the repository and each submodule;
- `config.worktree` and linked worktrees' `commondir`, which can redirect config.

`.git` itself is a separate mount. A mountpoint cannot be renamed, so Claude
cannot move it aside and create a fresh `.git` with its own config.

The project is mounted at its own path, not under a fixed directory such as
`/work`, because git writes absolute paths into the repository: a linked
worktree and its gitdir point at each other. Made at a path the host does not
have, a worktree is broken on the host, and `git worktree prune` there deletes
what git keeps of it. Git 2.48 can write relative links instead, but it marks
the repository with `extensions.relativeWorktrees`, and Nix (libgit2) then
refuses to open the repository: every flake in it breaks, on the host too.

A worktree Claude makes has its gitdir in `.git/worktrees/`, which the session
can write. The report leaves such a worktree out only when nothing in it leads
git away from the repository's own read-only config and hooks: its `.git`
is exactly the line git writes, `gitdir: <project>/.git/worktrees/<name>`,
compared as text, nothing on that path is a symlink, the gitdir links back to
it, `commondir` is `../..`, and it has no `config.worktree`. Text, because
resolving the path in the wrapper can disagree with git: zsh drops `..`
before it follows symlinks, git after, so `link/../..` could pass a resolved
check and still lead git to a repository planted in `.git`. Later sessions
mount the worktree's `commondir` read-only, like any linked worktree's.

Claude can still create *new* repositories inside the project: a nested `.git`,
a bare-repository layout, or a top-level `.git/commondir`. The wrapper cannot
prevent this from inside the container. It reports them after the session, and
quarantines `commondir` before your prompt runs git. This is the same class of
attack as
[CVE-2026-45033](https://www.miggo.io/vulnerability-database/cve/CVE-2026-45033)
and [Pillar's Cursor finding](https://www.pillar.security/blog/git-directories-do-not-have-to-be-called-git).

### Claude's configuration

You want Claude to learn with you: a convention, a permission, a skill, kept
for every later session in every project. A prompt injection wants the same
thing: one line in `CLAUDE.md` or one hook, and it runs in all your projects
from then on. So the global config can change, but only through you.

**One copy per session.** The approved config is a git repository that no
container sees. Each session gets its own copy as `~/.claude`, so sessions
running in parallel never see each other's unreviewed changes. A copy is a
plain directory, not a git worktree: there is no `.git` in it for a session to
point elsewhere, and the wrapper runs git on it with an explicit git dir and
index, no hooks and no fsmonitor. It is mounted as a directory because Claude
Code saves a file by writing a temporary one and renaming it, which fails on a
file mounted on its own.

**You decide, Opus helps.** When the session ends, what it changed in the
config (`CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`,
`commands/`, `skills/`, `hooks/`, `output-styles/`, and `agent-memory/`, which
subagents with user-scope memory write) becomes a commit on a branch, and
anything else it wrote in `~/.claude` is dropped. Then Opus reviews the diff, in a container with no tools, no project
and an empty config (it must not load the `CLAUDE.md` it reviews), and you
decide. Opus does not decide alone, because there is no safe "text only"
part to let through: a skill's or an agent's frontmatter can declare hooks,
allowed tools, a shell and MCP servers; a skill can run an inline
`` !`command` `` when it loads; and a `CLAUDE.md` line saying "run this first"
works. The diff is written by the attacker, for a model to read, so it can
address the reviewer too. Opus's verdict, and flags that need no model (hooks,
executables, frontmatter, URLs, invisible Unicode), decide only how much you
are shown: a one-line summary, or the whole diff.

**One login for all sessions, checked.** The login is in its own directory
(`CLAUDE_SECURESTORAGE_CONFIG_DIR`), shared by all sessions, because a token
refreshed by one session invalidates the copy another one holds. A session can
also write it, for example to sign every later session into an attacker's
account, which then receives your prompts and code. So whenever the login
changed (by content: a session sets file times at will), the wrapper asks
Anthropic's profile endpoint which account it belongs to, and quarantines it
if that is not the account you confirmed at your first login, if Anthropic
rejects it, or if it is written so that the wrapper could read one token and
Claude Code use another. The token goes to `curl` on stdin, not on its command
line. Nothing but the login stays in that directory: a file left there would
otherwise be a channel between all projects' sessions, read through an
accepted `@import`.

**Per project.** `~/.claude/projects` (transcripts and auto-memory),
`claude.json` and `history.jsonl` (prompt history) come from one directory per
project. Memory is loaded into context at the start of every session, so with
one shared directory a session could plant instructions in another project's
memory; `claude.json` holds MCP servers and per-project approvals; and the
history holds what you typed. Caches (`~/.cache`) are per project as well, so
a poisoned package cache stays in its project.

What goal 3 still does not cover:

- **The login can be stolen.** Every session can read it. A stolen refresh
  token gives its holder your account for weeks, and the account check only
  catches a login that was *replaced*. Revoke it from your claude.ai settings
  if you suspect a session. A credential proxy on the host, which keeps the
  token out of the containers, would close this and the next three gaps; it is
  the next thing to build (see [TODO.md](TODO.md)).
- **A replaced login may never be caught.** Until the session that replaced it
  ends (or the next wrapper starts), sessions running in parallel use it. And
  a session that puts your original login back before it ends leaves nothing
  to catch: the parallel sessions it redirected meanwhile go unnoticed.
- **An expired login after a crash looks replaced.** If a wrapper dies after a
  session refreshed the login, and the next one starts once the new token has
  expired (hours later), Anthropic rejects it, and the wrapper quarantines it:
  you log in again.
- **A replaced refresh token can pass once.** A session that refreshes your
  login itself gets your new access token, and can store it with *its own*
  refresh token: the check sees your account. The next refresh then signs that
  session into the other account, which is caught when it ends. Only the host
  doing the refreshes (the credential proxy above) closes this.
- **Detaching from the container** (`Ctrl-p Ctrl-q`) makes the wrapper believe
  the session ended while it still runs: it then saves and checks too early.
  Leave sessions with `/exit` or `Ctrl-d`.
- **Memory imported by `just install`** goes to the project id of the path the
  host's Claude Code recorded (the physical path). A project you reach through
  a symlink gets another id in the sandbox, and does not see that memory.
- **Plugins**, installed with `--config-rw`, are not reviewed.
- **You can be fooled too.** The review shows you exactly what changed, with
  control characters and invisible Unicode made visible, but reading a skill
  carefully is your job: accept what you understand.
- **The project's own Claude config** (`.claude/`, `.mcp.json`, `CLAUDE.md`)
  loads in the next session in that project. The report lists its changes,
  but nothing reviews them for you.

### Network

The container is on Docker's `bridge` network (or `kind`), with full outbound
access. It can also reach host services bound to `0.0.0.0` or the Docker
gateway, and cloud metadata endpoints if the host is a cloud VM. The sandbox
has no egress filtering, for three reasons: an allowlist firewall needs
`NET_ADMIN` in the container, it does not cover Nix builds (see above), and
Claude itself needs the network. If exfiltration matters to you, see the
alternatives below.

### Why rootful Docker, with no uid remapping

The container's uid is your uid, so files Claude writes are owned by you,
and the nix-daemon treats the container as you, an untrusted user, rather than
a new user. The cost is that a container escape lands as your host user, not
as an unprivileged uid. Another cost is on the host: being in the `docker`
group is equivalent to being root, for anything that runs as you.

Rootless Docker cannot keep the uid: it maps your uid to root inside the
container, and the container's users to subordinate uids on the host. Rootless
Podman can, with `--userns=keep-id`, and the rest of the design (read-only
mounts over `.git`, `--cap-drop=ALL`, `no-new-privileges`, named volumes) would
work the same, without a root daemon or the `docker` group.

It is not used, because of **`--kind`**. kind clusters run on rootful Docker's
`kind` network, and a rootless container cannot join that network. The
workarounds are worse than the problem:

- kind's Podman provider, in rootless mode, is still fragile: it needs cgroup
  delegation that many hosts lack, and some workloads do not run in it.
- Reaching the API server through the port kind publishes on the host means
  opening the host's loopback to the container, with a different kubeconfig
  than the one the cluster's own containers use.

Smaller issues would also need work: memory and pids limits need cgroup v2
delegation to the user, Ubuntu's AppArmor rules for user namespaces only cover
the distribution's own `podman` (not one from the Nix store), SELinux hosts need
`--security-opt label=disable` (relabelling `/nix/store` with `:z` would be a
disaster), and the tests would have to run against both engines. Without
`--kind`, rootless Podman would be the better trade.

### What Claude is told

The wrapper mounts a generated `/etc/claude-code/CLAUDE.md`, the place Claude
Code reads managed-policy instructions from. Claude loads it in every session,
before your own `CLAUDE.md`, and cannot change it. It says that Claude is in a
container, maps the paths Claude sees to the host paths you see, and lists what
fails here and why: the read-only `.git/config` (and not to run
`git worktree prune`, which deletes worktrees it cannot see from the
container), no credentials for `git push`,
no root, per-project memory, the reviewed global config (change it only when
asked, and say it will be reviewed), read-only plugins (or not, with
`--config-rw`), and the kind cluster with `--kind`. So instead of trying and
failing, Claude tells you what to run on the host, with paths you can paste.

### Tab completion in dev shells

Dev shells put nixpkgs' `stdenv` bash first in `PATH`, and that bash is built
without readline: there is no completion, and the prompt shows a literal `\[\]`.
The entrypoint therefore always starts the image's `/bin/bash`. A `bash` you
start yourself inside the dev shell is the stdenv bash again; use `/bin/bash`.

### Alternatives

| Tool | Isolation | Compared with this one |
|---|---|---|
| [Claude Code `/sandbox`](https://code.claude.com/docs/en/sandboxing) | bubblewrap (Linux), Seatbelt (macOS), and a proxy with a domain allowlist | Built in, with egress filtering. It wraps the commands Claude runs, not Claude itself. |
| [Claude Code devcontainer](https://code.claude.com/docs/en/devcontainer) | Container and an iptables allowlist | Egress filtering. No Nix store sharing. |
| [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) | microVM with a private Docker daemon and a credential-injecting proxy | Much stronger isolation. Tied to Docker Desktop. |
| [aibox](https://github.com/ruifm/aibox) | bubblewrap, host nix-daemon | The closest design. Lighter, but no git or network separation. Calls itself "accident-safety, not hostile-code containment". |
| [ai-jail](https://lib.rs/crates/ai-jail) | bubblewrap / sandbox-exec, allowlisted paths | No container image, packaged as a Nix flake. |
| [ClaudeBox](https://github.com/RchGrav/claudebox) | Container per project, with language profiles | No Nix. |

## License

[AGPL-3.0](LICENSE)
