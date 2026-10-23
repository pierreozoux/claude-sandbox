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

1. Clone this repository and build the image with your own uid/gid:

   ```sh
   git clone https://github.com/pierreozoux/claude-sandbox ~/src/claude-sandbox
   cd ~/src/claude-sandbox
   nix develop -c just build
   ```

   Without the flake, the same build is
   `docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t claude-sandbox .`

2. Load the function in your shell, and add the same line to `~/.zshrc`:

   ```sh
   source ~/src/claude-sandbox/claude-sandbox.zsh
   ```

3. Go to a project that has a `flake.nix` or a `shell.nix`, and start the sandbox:

   ```sh
   cd ~/src/some-project
   claude-sandbox
   ```

   You get a bash prompt inside the project's dev shell, at `/work/some-project-<hash>`
   (the hash keeps projects with the same name apart).
   Run `which` on one of the project's tools: the path is in `/nix/store`,
   served read-only from the host.

4. Look around:

   ```sh
   ls ~          # an empty home, not yours
   ls /work      # only this project
   git log -1    # works; commits are made as you
   ```

5. Start Claude and log in. The login is stored in
   `~/.config/claude-sandbox/claude` on the host, so you do it only once:

   ```sh
   claude
   ```

6. Leave the shell. The container is removed. If Claude left anything your host
   might run without asking, such as a nested git repository or a changed
   `.envrc`, the wrapper lists it before you get your prompt back.

---

## How-to guides

### Run Claude directly, without the intermediate shell

```sh
claude-sandbox claude
claude-sandbox claude --dangerously-skip-permissions
```

Arguments after the options are run inside the dev shell. Use `--` if your
command itself starts with `--`.

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

### Change Claude's settings, or install plugins and skills

Settings, `CLAUDE.md`, agents, commands, skills, hooks and plugins are read-only
inside the sandbox, so a session cannot change how later sessions behave. To
change them, do one of the following:

- edit the files on the host in `~/.config/claude-sandbox/claude/`, or
- start one deliberate session with `claude-sandbox --config-rw claude`,
  in a project you trust, and make the change there.

Claude knows this (see [What Claude is told](#what-claude-is-told)): when you
ask it for such a change in a normal session, it gives you the command to run
on the host instead.

Memory is different: Claude can write it, but it is per project. A preference
you want in every project, such as a commit message convention, belongs in
`~/.config/claude-sandbox/claude/CLAUDE.md`.

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

### Free disk space

Each project has its own cache volume:

```sh
docker volume ls --filter name=claude-cache-
docker volume rm claude-cache-<project>-<hash>
just clean-volumes          # all of them
```

Claude's sessions and memory for each project are in
`~/.config/claude-sandbox/projects/<project>-<hash>/`, and can be deleted the
same way.

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
| `--config-rw` | Do not make Claude's settings, `CLAUDE.md`, agents, commands, skills, hooks and plugins read-only. |
| `--` | End of options. |
| `command` | What to run in the dev shell. Default: `bash`. |

The wrapper refuses to start in `$HOME` or `/`, or when the path contains `:`.
The return value is the container's exit status.

### Environment variables (host)

| Variable | Default | Effect |
|---|---|---|
| `CLAUDE_SANDBOX_DOCKER_HOST` | `unix:///var/run/docker.sock` | Docker daemon to use. |
| `CLAUDE_SANDBOX_IMAGE` | `claude-sandbox` | Image to run (and to build/test with `just`). |
| `CLAUDE_SANDBOX_MEMORY` | `8g` | Container memory limit (`docker run --memory`). |
| `CLAUDE_SANDBOX_ALLOW_TRUSTED` | unset | Start even if the nix-daemon lists you in `trusted-users` (see [Nix](#nix)). |

### Build arguments

| Argument | Default | Effect |
|---|---|---|
| `UID`, `GID` | `1000` | Must match `id -u` / `id -g` on the host. |
| `CLAUDE_VERSION`, `CLAUDE_SHA256_X64`, `CLAUDE_SHA256_ARM64` | pinned | Claude Code version and binary checksums. Set them with `just pin-claude`. |

### Mounts

| Host | Container | Mode |
|---|---|---|
| project (`$PWD`) | `/work/<name>-<hash>` | rw |
| `<project>/.git` | `/work/<name>-<hash>/.git` | rw, as its own mount |
| `.git/config`, `.git/hooks`, and the same for each submodule in `.git/modules/` | same paths | **ro** |
| `config.worktree` (when `extensions.worktreeConfig` is on), `.git/worktrees/*/{commondir,config.worktree}` | same paths | **ro** |
| `/nix/store` | `/nix/store` | **ro** |
| `/nix/var/nix/daemon-socket` | same | rw (socket) |
| `~/.config/claude-sandbox/claude` | `~/.claude` | rw |
| … its `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `hooks/`, `plugins/` | same | **ro** unless `--config-rw` |
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

### Post-session report

| Finding | Action |
|---|---|
| `.git/commondir` exists | It is renamed to `commondir.quarantined`. |
| Nested `.git` (directory or file) or bare-repository layout | Listed. |
| `.envrc`, `flake.nix`, `shell.nix`, `default.nix`, `justfile`, `Makefile`, `package.json`, `.gitattributes`, `.gitmodules`, `.pre-commit-config.yaml`, `.vscode/*`, `.github/workflows/*` modified during the session | Listed. |

### Development

| File | Purpose |
|---|---|
| `flake.nix` | Dev shell (`just`, `zsh`, `git`, `shellcheck`, `kind`; Docker comes from the host) and `checks` (lint, unit tests). |
| `.envrc` | `use flake`: direnv loads the dev shell when you `cd` in (after `direnv allow`). |
| `justfile` | The recipes below. |
| `tests/lib.zsh` | Test harness. Each `test_*` function runs in a subshell, in its own temporary directory, and stops at its first failing command. |
| `tests/unit.zsh` | Wrapper and entrypoint logic. `docker`, `nix`, `nix-instantiate` and `kind` are stubs, and `PATH` holds only the tools needed. |
| `tests/integration.zsh` | Real containers: privileges, git protection, config read-only, dev shells, the nix-daemon's view of you. Uses a temporary `HOME`, and removes the cache volumes it creates. |

| Recipe | Does |
|---|---|
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
   not change how Claude behaves in the next project. This goal has known
   gaps, listed in [Claude's configuration](#claudes-configuration).

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

Claude can still create *new* repositories inside the project: a nested `.git`,
a bare-repository layout, or a top-level `.git/commondir`. The wrapper cannot
prevent this from inside the container. It reports them after the session, and
quarantines `commondir` before your prompt runs git. This is the same class of
attack as
[CVE-2026-45033](https://www.miggo.io/vulnerability-database/cve/CVE-2026-45033)
and [Pillar's Cursor finding](https://www.pillar.security/blog/git-directories-do-not-have-to-be-called-git).

### Claude's configuration

One config directory is shared by all projects, so you log in once. The parts
that change Claude's *behaviour* in every later session (settings and their
hooks, `CLAUDE.md`, agents, commands, skills, plugins) are read-only. Without
this, an injection in one project could install a hook that runs in all the
others.

`~/.claude/projects`, which holds session transcripts and Claude's
auto-memory, is mounted from a separate directory for each project. Memory is
loaded into context at the start of every session, so with one shared
directory a session could plant instructions in another project's memory, and
read every other project's transcripts. Caches (`~/.cache`) are per project as
well, so a poisoned package cache stays in its project.

These remain shared and writable, so goal 3 does not fully hold:

- `.claude.json`, which Claude rewrites constantly, can hold user-wide MCP
  server definitions, which start in every later session.
- `history.jsonl` holds your prompt history for all projects: a session can
  read what you typed elsewhere.
- `.credentials.json` (your login token) is readable by every session.
- Any other file in `~/.claude` that a read-only setting points to, such as a
  `statusLine` script. Keep such scripts in `hooks/`, which is read-only.

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
fails here and why: the read-only config (or not, with `--config-rw`), the
read-only `.git/config`, no credentials for `git push`, no root, per-project
memory, and the kind cluster with `--kind`. So instead of trying and failing,
Claude tells you what to run on the host, with paths you can paste.

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
