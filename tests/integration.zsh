#!/usr/bin/env zsh
# Integration tests: the real image, real docker, and the host's nix-daemon.
# Build the image first (`just build`). Each test gets a temporary HOME, so
# your own ~/.config/claude-sandbox is never touched.
#
#   CLAUDE_SANDBOX_IMAGE=name        image to test (default: claude-sandbox)
#   CLAUDE_SANDBOX_TEST_KIND=name    also test --kind against that existing cluster
#   NIXPKGS_PATH=/nix/store/...      nixpkgs for the dev-shell fixtures
#                                    (set by the flake's dev shell)
source ${0:A:h}/lib.zsh

export DOCKER_HOST=${CLAUDE_SANDBOX_DOCKER_HOST:-unix:///var/run/docker.sock}
typeset -g IMAGE=${CLAUDE_SANDBOX_IMAGE:-claude-sandbox}
typeset -g NIXPKGS=${NIXPKGS_PATH:-${$(nix-instantiate --find-file nixpkgs 2>/dev/null):A}}
typeset -g SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem 2>/dev/null)

if ! docker image inspect $IMAGE > /dev/null 2>&1; then
  print -u2 "integration: image $IMAGE not found, build it first: just build"
  exit 1
fi
if [[ $(nix store info 2>&1) == *'Trusted: 1'* ]]; then
  print -u2 "integration: the nix-daemon trusts you, so claude-sandbox refuses to start (see README)"
  exit 1
fi

setup() {
  export HOME=$T/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/home/.gitconfig
  mkdir -p $HOME
  git config --global user.name 'Ada Test'
  git config --global user.email ada@example.test
  git config --global init.defaultBranch main
  [[ -n $NIXPKGS ]] && export NIX_PATH=nixpkgs=$NIXPKGS
  unset CLAUDE_SANDBOX_ALLOW_TRUSTED
  typeset -ga PROJECTS=()
  source $ROOT/claude-sandbox.zsh
  CFG=$HOME/.config/claude-sandbox
  _claude_sandbox_init_config $CFG
}

# The pending changes to Claude's config (branches session/*)
pending() { git -C $CFG/config for-each-ref --format='%(refname:short)' refs/heads/session/ }

# Remove the per-project cache volumes the tests created
teardown() {
  local p hash
  for p in $PROJECTS; do
    hash=$(print -rn -- $p | sha256sum)
    docker volume rm -f claude-cache-${p:t}-${hash[1,8]} > /dev/null 2>&1
  done
  return 0
}

# mkproj NAME [git]: create a project and cd into it
mkproj() {
  mkdir -p $T/$1 && cd $T/$1
  PROJECTS+=($T/$1)
  if [[ $2 == git ]]; then
    git init -q && git commit -q --allow-empty -m init
  fi
  return 0
}

# Run the wrapper; sets $rc, $out and $err
sandbox() {
  rc=0
  out=$(CLAUDE_SANDBOX_IMAGE=$IMAGE claude-sandbox "$@" 2> $T/stderr) || rc=$?
  err=$(<$T/stderr)
  return 0
}

need_nixpkgs() {
  [[ -n $NIXPKGS && -n $SYSTEM ]] ||
    skip "no nixpkgs found: run from \`nix develop\`, or set NIXPKGS_PATH"
}

# --- Isolation

test_runs_as_you_without_privileges() {
  mkproj p
  sandbox sh -c 'id -u; grep ^CapEff /proc/self/status; grep ^NoNewPrivs /proc/self/status; cat /proc/1/comm'
  assert_eq $rc 0
  local -a lines=(${(f)out})
  assert_eq ${lines[1]} $(id -u) "same uid as the host"
  assert_eq ${lines[2]} $'CapEff:\t0000000000000000'
  assert_eq ${lines[3]} $'NoNewPrivs:\t1'
  assert_eq ${lines[4]} docker-init
}

test_sees_only_the_project() {
  mkproj p
  sandbox sh -c 'ls /work; test -e /var/run/docker.sock && echo docker-socket; test -e ~/.ssh && echo ssh; true'
  [[ $out == p-???????? ]] || fail "expected only the project, got [$out]"
}

test_exit_status_comes_back() {
  mkproj p
  sandbox sh -c 'exit 3'
  assert_eq $rc 3
}

# --- Git

test_git_config_and_hooks_cannot_be_changed() {
  mkproj p git
  local config=$(<.git/config)
  sandbox sh -c '
    echo "[core] fsmonitor = touch $PWD/pwned" >> .git/config 2>/dev/null && echo config-writable
    rm -f .git/config 2>/dev/null; test -e .git/config || echo config-removable
    touch .git/hooks/post-checkout 2>/dev/null && echo hooks-writable
    git config core.pager "touch $PWD/pwned" 2>/dev/null && echo git-config-worked
    true'
  assert_eq "$out" ""
  assert_eq "$(<.git/config)" "$config"
  [[ ! -e pwned ]] || fail "planted command ran"
}

test_git_dir_cannot_be_swapped() {
  # Moving .git aside and writing a fresh one would bypass the read-only config
  mkproj p git
  sandbox sh -c 'mv .git .git-aside 2>&1 && echo SWAPPED; true'
  assert_not_contains "$out" SWAPPED
  assert_contains "$out" "busy"
  [[ -d .git && ! -e .git-aside ]] || fail ".git was moved"
}

test_commits_land_as_you() {
  mkproj p git
  sandbox sh -c 'echo hi > f && git add f && git commit -q -m from-sandbox'
  assert_eq $rc 0
  assert_eq "$(git log -1 --format='%an <%ae> %s')" "Ada Test <ada@example.test> from-sandbox"
  [[ -O f ]] || fail "files written in the sandbox should be owned by you"
}

test_report_flags_planted_repositories() {
  mkproj p git
  sandbox sh -c 'mkdir -p sub/.git && echo /tmp > .git/commondir'
  assert_contains "$err" "quarantined"
  assert_contains "$err" "$T/p/sub/.git"
  [[ ! -e .git/commondir ]] || fail "commondir left in place"
  git status > /dev/null || fail "host git should still work"
}

# --- Claude

test_claude_is_installed() {
  mkproj p
  sandbox claude --version
  assert_eq $rc 0
  assert_contains "$out" "Claude Code"
}

test_config_changes_wait_for_review() {
  mkproj p
  # Claude Code saves files by writing a temporary file and renaming it: that
  # must work on the config, which is why ~/.claude is mounted as a directory
  sandbox sh -c '
    echo "{\"model\": \"x\"}" > ~/.claude/settings.json.tmp &&
      mv ~/.claude/settings.json.tmp ~/.claude/settings.json && echo renamed
    echo learned >> ~/.claude/CLAUDE.md
    touch ~/.claude/plugins/x 2>/dev/null && echo plugins-writable
    true'
  assert_eq "$out" renamed
  assert_eq "$(git -C $CFG/config show HEAD:CLAUDE.md)" "" "not applied before review"
  local ref=$(pending)
  [[ -n $ref ]] || fail "expected a pending change"
  assert_eq "$(git -C $CFG/config show ${ref}:CLAUDE.md)" learned
  assert_eq "$(git -C $CFG/config show ${ref}:settings.json)" '{"model": "x"}'
  assert_contains "$err" "wait for your review"
  local -a left=($CFG/sessions/*(DN))
  assert_eq $#left 0 "the session's copy is removed"
}

test_config_rw_makes_plugins_writable() {
  mkproj p
  sandbox --config-rw sh -c 'touch ~/.claude/plugins/x && echo plugins-writable'
  assert_eq "$out" plugins-writable
}

test_login_directory_is_shared_by_sessions() {
  mkproj a
  # Anything but the login files is removed between sessions: probe with one
  sandbox sh -c 'echo $CLAUDE_SECURESTORAGE_CONFIG_DIR; echo from-a > ~/.claude-auth/.device-keys.json'
  assert_eq "$out" /home/claude/.claude-auth
  mkproj b
  sandbox sh -c 'cat ~/.claude-auth/.device-keys.json'
  assert_eq "$out" from-a
}

test_claude_gets_read_only_sandbox_instructions() {
  mkproj p
  sandbox sh -c '
    grep -q "^# claude-sandbox" /etc/claude-code/CLAUDE.md && echo present
    touch /etc/claude-code/CLAUDE.md 2>/dev/null && echo writable'
  assert_eq "$out" present
}

test_claude_sessions_of_other_projects_are_invisible() {
  # Planting memory in another project's directory must not be possible
  mkproj a
  sandbox sh -c 'mkdir -p ~/.claude/projects/-work-b/memory && echo planted > ~/.claude/projects/-work-b/memory/MEMORY.md'
  assert_eq $rc 0 "$err"
  mkproj b
  sandbox sh -c 'ls -A ~/.claude/projects'
  assert_eq "$out" ""
}

# --- Dev shells

test_envrc_is_loaded() {
  mkproj p
  print 'export SANDBOX_TEST=from-envrc' > .envrc
  sandbox printenv SANDBOX_TEST
  assert_eq "$out" from-envrc
}

test_flake_dev_shell_with_interactive_bash() {
  need_nixpkgs
  mkproj p git
  cat > flake.nix <<EOF
{
  inputs.nixpkgs.url = "path:$NIXPKGS";
  outputs = { nixpkgs, ... }: {
    devShells.$SYSTEM.default = nixpkgs.legacyPackages.$SYSTEM.mkShell {
      packages = [ nixpkgs.legacyPackages.$SYSTEM.hello ];
    };
  };
}
EOF
  git add flake.nix
  sandbox bash -c 'hello; type -t bind; echo $BASH'
  assert_eq $rc 0 "$err"
  # bind is a builtin only in a bash built with readline (tab completion)
  assert_eq "$out" $'Hello, world!\nbuiltin\n/bin/bash'
}

test_shell_nix_uses_host_nixpkgs() {
  need_nixpkgs
  mkproj p
  print 'with import <nixpkgs> {}; mkShell { packages = [ hello ]; }' > shell.nix
  sandbox hello
  assert_eq $rc 0 "$err"
  assert_eq "$out" "Hello, world!"
}

test_nix_daemon_sees_an_untrusted_user() {
  mkproj p
  sandbox sh -c 'nix store info 2>&1'
  assert_contains "$out" "Trusted: 0"
}

# --- kind

test_kind_cluster_is_reachable() {
  [[ -n $CLAUDE_SANDBOX_TEST_KIND ]] ||
    skip "set CLAUDE_SANDBOX_TEST_KIND=<cluster> to test --kind"
  mkproj p
  sandbox --kind $CLAUDE_SANDBOX_TEST_KIND sh -c \
    'curl -sk "$(sed -n "s/^ *server: //p" ~/.kube/config)/version"'
  assert_contains "$out" gitVersion
}

run_tests "$@"
