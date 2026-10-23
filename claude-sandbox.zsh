# Source from ~/.zshrc:  source ~/path/to/claude-sandbox.zsh
#
# Build once (`just update` moves the Claude Code pin, since auto-update is off):
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t claude-sandbox .
#
# Usage:
#   claude-sandbox [options] [--] [command...]     # default command: claude
#     --kind NAME    also join the kind docker network, with that cluster's kubeconfig only
#     --config-rw    leave Claude's settings, CLAUDE.md, skills, hooks... writable (to install plugins etc.)
#
# See README.md for what this protects against, and what it does not.

claude-sandbox() {
  emulate -L zsh
  # Rootful docker on purpose: container uid == host uid, so file ownership just works
  local -x DOCKER_HOST=${CLAUDE_SANDBOX_DOCKER_HOST:-unix:///var/run/docker.sock}
  local proj=$PWD
  local cfg=$HOME/.config/claude-sandbox
  local -a extra env net=(--network bridge)
  local config_rw= cluster= f

  while (( $# )); do
    case $1 in
      --kind)
        if [[ -z $2 ]]; then
          print -u2 "usage: claude-sandbox --kind <cluster-name> [command...]"
          return 1
        fi
        cluster=$2
        shift 2 ;;
      --config-rw) config_rw=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  # Never hand the container your home directory (or /)
  if [[ $proj == $HOME || $proj == / ]]; then
    print -u2 "claude-sandbox: refusing to mount $proj, cd into a project"
    return 1
  fi
  # docker -v splits on ':'
  if [[ $proj == *:* ]]; then
    print -u2 "claude-sandbox: project path contains ':', which docker -v cannot mount"
    return 1
  fi

  # Docker names allow [A-Za-z0-9_.-]; the hash keeps same-named projects apart
  local name=${${PWD:t}//[^A-Za-z0-9_.-]/_}
  local hash=$(print -rn -- $proj | sha256sum)
  local id=${name}-${hash[1,8]}
  # Claude keys sessions and memory on the working directory, so it must be
  # unique per project too
  local wd=/work/$id

  # --- Nix: host store read-only, builds go through the host daemon (untrusted user)
  if (( ! $+commands[nix] )); then
    print -u2 "claude-sandbox: nix not found on PATH, the container uses the host's nix"
    return 1
  fi
  env+=(-e PATH=${commands[nix]:A:h}:/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin)
  _claude_sandbox_check_daemon || return 1

  # Same <nixpkgs> as the host, resolved to a store path the container can read
  local nixpkgs=$(nix-instantiate --find-file nixpkgs 2>/dev/null)
  if [[ -n $nixpkgs ]]; then
    env+=(-e NIX_PATH=nixpkgs=${nixpkgs:A})
  else
    print -u2 "claude-sandbox: no <nixpkgs> on host, shell.nix files using <nixpkgs> will fail"
  fi

  # --- Optional kind cluster access
  if [[ -n $cluster ]]; then
    local kc=$cfg/kind-$cluster.kubeconfig
    mkdir -p $cfg
    # Admin credentials: keep them private, and never leave a half-written file
    if ! ( umask 077; kind get kubeconfig --internal --name $cluster > $kc.tmp ); then
      rm -f $kc.tmp
      return 1
    fi
    mv $kc.tmp $kc
    net=(--network kind)
    extra+=(-v $kc:/home/claude/.kube/config:ro)
  fi

  # --- Git: Claude can commit, but cannot change what your host git executes.
  # .git stays writable (objects, refs, index), while everything git reads
  # config or hooks from is read-only, so no planted hooks, core.fsmonitor,
  # core.hooksPath, pager, etc. Mounting .git itself makes it a mountpoint,
  # so it cannot be renamed away and replaced by a fresh one.
  if [[ -d $proj/.git ]]; then
    local g=$proj/.git d
    extra+=(-v $g:$wd/.git)
    # The main repo's gitdir and every submodule's gitdir (nested under
    # modules/). A branch named "config" matches the glob too, hence the check.
    for d in $g $g/modules/**/config(N.:h); do
      [[ -f $d/HEAD && -d $d/objects ]] || continue
      mkdir -p $d/hooks
      extra+=(
        -v $d/config:$wd/${d#$proj/}/config:ro
        -v $d/hooks:$wd/${d#$proj/}/hooks:ro
      )
      # Only read when extensions.worktreeConfig is on; then it must exist to be protected
      if git config --file $d/config --type bool --get extensions.worktreeConfig 2>/dev/null | grep -qx true; then
        [[ -e $d/config.worktree ]] || : > $d/config.worktree
        extra+=(-v $d/config.worktree:$wd/${d#$proj/}/config.worktree:ro)
      fi
    done
    # Linked worktrees living elsewhere on the host: their commondir decides
    # which config they read
    for d in $g/worktrees/*(N/); do
      for f in commondir config.worktree; do
        [[ -f $d/$f ]] && extra+=(-v $d/$f:$wd/${d#$proj/}/${f}:ro)
      done
    done
  elif [[ -f $proj/.git ]]; then
    print -u2 "claude-sandbox: $proj/.git is a file (worktree/submodule); its config is NOT protected"
  fi

  # Commit as you (Claude Code adds its own Co-Authored-By trailer)
  local gname=$(git config --get user.name) gmail=$(git config --get user.email)
  if [[ -n $gname && -n $gmail ]]; then
    env+=(
      -e GIT_AUTHOR_NAME=$gname -e GIT_COMMITTER_NAME=$gname
      -e GIT_AUTHOR_EMAIL=$gmail -e GIT_COMMITTER_EMAIL=$gmail
    )
  else
    print -u2 "claude-sandbox: git user.name/user.email not set on host, commits will fail"
  fi

  # --- Claude config: shared across projects (login, history), but what changes
  # Claude's behaviour in every later session is read-only unless --config-rw.
  local cc=$cfg/claude
  mkdir -p $cc/{agents,commands,skills,hooks,plugins}
  [[ -e $cc/settings.json ]] || print '{}' > $cc/settings.json
  [[ -e $cc/CLAUDE.md ]] || : > $cc/CLAUDE.md
  if [[ -z $config_rw ]]; then
    for f in settings.json CLAUDE.md agents commands skills hooks plugins; do
      extra+=(-v $cc/$f:/home/claude/.claude/${f}:ro)
    done
  fi
  # Sessions, transcripts and auto-memory: one directory per project, so a
  # session cannot read other projects' transcripts or plant memory in them
  mkdir -p $cfg/projects/$id
  extra+=(-v $cfg/projects/$id:/home/claude/.claude/projects)

  # -t only with a terminal, so scripts and tests can pipe in and out
  local -a tty=(-i)
  [[ -t 0 && -t 1 ]] && tty=(-it)

  # Tell Claude where it is and what it cannot change, as managed-policy
  # instructions: loaded in every session, read-only, outside ~/.claude
  local instructions=$(mktemp)
  _claude_sandbox_instructions $proj $wd $cfg $id "$config_rw" "$cluster" > $instructions
  extra+=(-v $instructions:/etc/claude-code/CLAUDE.md:ro)

  local stamp=$(mktemp) rc
  docker run $tty --rm --init \
    --name claude-$id-$$ \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --pids-limit=2048 \
    --memory=${CLAUDE_SANDBOX_MEMORY:-8g} \
    $net \
    -v /nix/store:/nix/store:ro \
    -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
    -v claude-cache-$id:/home/claude/.cache \
    -v $cc:/home/claude/.claude \
    -e CLAUDE_CONFIG_DIR=/home/claude/.claude \
    $env \
    -v $proj:$wd \
    $extra \
    -w $wd \
    ${CLAUDE_SANDBOX_IMAGE:-claude-sandbox} "$@"
  rc=$?

  _claude_sandbox_audit $proj $stamp
  rm -f $stamp $instructions
  return $rc
}

# The session's instructions for Claude, in Markdown:
#   _claude_sandbox_instructions PROJECT WORKDIR CONFIG ID CONFIG_RW CLUSTER
_claude_sandbox_instructions() {
  emulate -L zsh
  local proj=$1 wd=$2 cfg=$3 id=$4 config_rw=$5 cluster=$6
  local cc=$cfg/claude
  cat <<EOF
# claude-sandbox

You run in claude-sandbox: a throwaway Docker container that sees only this
project. The user's host is outside it, so when something must change there,
give the user the exact command to run on the host, with the host paths below.

| In the container | On the host |
|---|---|
| \`$wd\` (this project, read-write) | \`$proj\` |
| \`~/.claude\` | \`$cc\` |
| \`~/.claude/projects\` (sessions and memory of this project only) | \`$cfg/projects/$id\` |
| \`~/.cache\` | Docker volume \`claude-cache-$id\` |

- Everything else is lost when the session ends: \`/tmp\`, the rest of \`~\`,
  anything installed outside the project.
- \`~\` is not the user's home: no SSH keys, cloud credentials or other
  projects. \`git push\`, \`gh\` and anything needing the user's credentials
  fail: ask the user to run them on the host.
- \`.git/config\` and \`.git/hooks\` (and those of submodules) are read-only:
  the repository's \`git config\` cannot change. Give the user the host command.
- No root, no sudo, no apt, no Docker. Get tools with Nix:
  \`nix shell nixpkgs#tool\`, or add them to the project's dev shell. Builds run
  on the host's nix-daemon, as an untrusted user; \`/nix/store\` is read-only.
- Your memory is per project: what you saved in other projects, or outside
  the sandbox, is not visible here, and what you save here stays here. A
  preference for every project belongs in the global \`CLAUDE.md\`.
- The container clock is UTC.
EOF
  if [[ -z $config_rw ]]; then
    cat <<EOF
- Started without \`--config-rw\`: \`settings.json\`, \`CLAUDE.md\`, \`agents/\`,
  \`commands/\`, \`skills/\`, \`hooks/\` and \`plugins/\` in \`~/.claude\` are
  read-only. To change them, give the user the command that edits
  \`$cc/<file>\` on the host, or suggest restarting with
  \`claude-sandbox --config-rw\` in a project they trust.
EOF
  else
    cat <<EOF
- Started with \`--config-rw\`: \`~/.claude\` settings, \`CLAUDE.md\`, agents,
  commands, skills, hooks and plugins are writable, and changes apply to every
  project's sessions. Make only the changes the user asked for.
EOF
  fi
  if [[ -n $cluster ]]; then
    cat <<EOF
- Started with \`--kind $cluster\`: \`~/.kube/config\` (read-only) is a
  cluster-admin kubeconfig for the kind cluster \`$cluster\` only.
EOF
  fi
}

# When the list of vulnerable nix-daemon versions below was last checked
# against https://github.com/NixOS/nix/security/advisories (`just update`
# reminds you). The wrapper warns once it is more than 6 months old.
typeset -g _CLAUDE_SANDBOX_ADVISORIES_CHECKED=2026-10

# Refuse to hand the container a nix-daemon that treats you as trusted:
# trusted users can turn off the build sandbox, which is root on the host.
_claude_sandbox_check_daemon() {
  emulate -L zsh
  # nix store info reports on stderr
  local -a info=(${(f)"$(nix store info 2>&1)"})
  local trusted=${${(M)info:#Trusted:*}#Trusted: }
  local version=${${(M)info:#Version:*}#Version: }

  if [[ $trusted == 1 && -z $CLAUDE_SANDBOX_ALLOW_TRUSTED ]]; then
    print -u2 "claude-sandbox: you are a trusted user of the nix-daemon (trusted-users),"
    print -u2 "  which makes the container root-equivalent on the host. Remove yourself from"
    print -u2 "  trusted-users, or set CLAUDE_SANDBOX_ALLOW_TRUSTED=1 to accept that."
    return 1
  elif [[ -z $trusted ]]; then
    print -u2 "claude-sandbox: could not tell whether the nix-daemon trusts you (nix < 2.19?)"
  fi

  # First releases fixing CVE-2026-39860 (build user -> root), per minor version
  local -A fixed=(28 6 29 3 30 4 31 4 32 7 33 4 34 5)
  local -a v=(${(s:.:)version%%[^0-9.]*})
  local old=
  if [[ ${v[1]} == 2 ]]; then
    if (( v[2] < 28 )); then
      old=1
    elif [[ -n ${fixed[${v[2]}]} ]] && (( v[3] < fixed[${v[2]}] )); then
      old=1
    fi
  fi
  if [[ -n $old ]]; then
    print -u2 "claude-sandbox: nix-daemon $version has known root escalations, upgrade it"
  fi

  zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS
  local checked=$_CLAUDE_SANDBOX_ADVISORIES_CHECKED now
  strftime -s now %Y-%m $EPOCHSECONDS
  if (( (${now%-*} - ${checked%-*}) * 12 + ${now#*-} - ${checked#*-} > 6 )); then
    print -u2 "claude-sandbox: the list of vulnerable nix-daemon versions dates from $checked;"
    print -u2 "  update claude-sandbox, or check https://github.com/NixOS/nix/security/advisories"
  fi
  return 0
}

# Things the container may have planted that your host runs without asking.
# Best effort: this catches mistakes and lazy injections, not a determined
# attacker (mtimes can be forged). Read the diff before running project code.
_claude_sandbox_audit() {
  emulate -L zsh
  local proj=$1 stamp=$2 f
  local -a repos bare touched

  # A gitdir never has a commondir; one here would redirect config elsewhere.
  # Move it aside now, before your prompt runs git in this directory.
  if [[ -e $proj/.git/commondir || -L $proj/.git/commondir ]]; then
    mv $proj/.git/commondir $proj/.git/commondir.quarantined
    print -u2 "claude-sandbox: quarantined $proj/.git/commondir (redirects git config)"
  fi

  # Nested repositories (dirs, gitdir files) and bare-repo lookalikes: entering
  # them on the host makes git read their config, e.g. core.fsmonitor.
  repos=(${(f)"$(find $proj -path $proj/.git -prune -o -name .git -print 2>/dev/null)"})
  for f in ${(f)"$(find $proj -path $proj/.git -prune -o -type f -name HEAD -print 2>/dev/null)"}; do
    [[ -d ${f:h}/objects && -d ${f:h}/refs ]] && bare+=(${f:h})
  done
  if (( $#repos || $#bare )); then
    print -u2 "claude-sandbox: nested git repositories in the project; their config runs"
    print -u2 "  code when git touches them (your prompt included). Check before cd-ing in:"
    print -u2 -l -- "    "${^repos} "    "${^bare}
  fi

  touched=(${(f)"$(find $proj -path $proj/.git -prune -o -newer $stamp \( \
      -name .envrc -o -name flake.nix -o -name shell.nix -o -name default.nix \
      -o -iname justfile -o -name Makefile -o -name package.json \
      -o -name .gitattributes -o -name .gitmodules -o -name .pre-commit-config.yaml \
      -o -path '*/.vscode/*' -o -path '*/.github/workflows/*' \) -print 2>/dev/null)"})
  if (( $#touched )); then
    print -u2 "claude-sandbox: changed files your host may execute (direnv, nix, make, editors):"
    print -u2 -l -- "    "${^touched}
  fi
}
