#!/usr/bin/env zsh
# Unit tests: no docker, no nix-daemon. docker, nix, nix-instantiate and kind
# are stubs, and PATH holds only the tools listed below, so the results do not
# depend on the machine (this also runs inside `nix flake check`).
source ${0:A:h}/lib.zsh

typeset -gA REAL
for tool in bash sh git find sha256sum mktemp grep rm mv mkdir cat cp touch ls ln sed chmod; do
  REAL[$tool]=${commands[$tool]:-${$(whence -p $tool)}}
  [[ -n ${REAL[$tool]} ]] || { print -u2 "unit: $tool not found"; exit 1 }
done

setup() {
  mkdir -p $T/bin $T/home $T/nixpkgs
  local tool
  for tool in ${(k)REAL}; do ln -s ${REAL[$tool]} $T/bin/$tool; done

  # Records its arguments one per line, then plays the session's side effects
  stub docker <<'EOF'
printf '%s\n' "$@" > "$T/docker.args"
[ -z "$STUB_DOCKER_DOES" ] || sh -c "$STUB_DOCKER_DOES"
exit "${STUB_DOCKER_RC:-0}"
EOF
  stub nix <<'EOF'
[ "$1 $2" = "store info" ] && printf 'Store URL: daemon\nVersion: %s\nTrusted: %s\n' \
  "${STUB_NIX_VERSION-2.31.4}" "${STUB_NIX_TRUSTED-0}" >&2
exit 0
EOF
  stub nix-instantiate <<'EOF'
[ -n "$STUB_NIXPKGS" ] && echo "$STUB_NIXPKGS"
exit 0
EOF
  stub kind <<'EOF'
[ -n "$STUB_KIND_FAIL" ] && { echo partial; exit 1; }
echo "kubeconfig for $5"
EOF

  export T HOME=$T/home PATH=$T/bin STUB_NIXPKGS=$T/nixpkgs
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/home/.gitconfig
  git config --global user.name 'Ada Test'
  git config --global user.email ada@example.test
  git config --global init.defaultBranch main
  unset CLAUDE_SANDBOX_IMAGE CLAUDE_SANDBOX_ALLOW_TRUSTED CLAUDE_SANDBOX_MEMORY
  unset STUB_DOCKER_DOES STUB_DOCKER_RC
  source $ROOT/claude-sandbox.zsh
  # Results must not depend on today's date
  zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS
  strftime -s _CLAUDE_SANDBOX_ADVISORIES_CHECKED %Y-%m $EPOCHSECONDS
}

# stub NAME: a shell script from stdin
stub() {
  { print '#!/bin/sh'; cat } > $T/bin/$1
  chmod +x $T/bin/$1
}

# mkproj NAME [git]: create a project and cd into it
mkproj() {
  mkdir -p "$T/$1" && cd "$T/$1"
  [[ $2 == git ]] && git init -q
  return 0
}

# Run the wrapper; sets $rc, $err, and $args (docker's arguments, one per element)
sandbox() {
  rc=0
  claude-sandbox "$@" 2> $T/stderr || rc=$?
  err=$(<$T/stderr)
  args=()
  [[ -e $T/docker.args ]] && args=(${(f)"$(<$T/docker.args)"})
  return 0
}

# The container's working directory for the project in $PWD
wd() {
  local hash=$(print -rn -- $PWD | sha256sum)
  print -r -- /work/${${PWD:t}//[^A-Za-z0-9_.-]/_}-${hash[1,8]}
}

# The arguments after the image name
cmd_after_image() {
  print -rl -- ${args[$(( ${args[(ie)${CLAUDE_SANDBOX_IMAGE:-claude-sandbox}]} + 1 )),-1]}
}

# --- Refusals and pre-flight checks

test_refuses_home() {
  cd $HOME
  sandbox
  assert_eq $rc 1
  assert_contains "$err" "refusing to mount"
  assert_eq $#args 0 "docker must not run"
}

test_refuses_path_with_colon() {
  mkproj 'a:b'
  sandbox
  assert_eq $rc 1
  assert_contains "$err" "contains ':'"
}

test_requires_host_nix() {
  rm $T/bin/nix
  mkproj p
  sandbox
  assert_eq $rc 1
  assert_contains "$err" "nix not found"
}

test_refuses_trusted_nix_user() {
  mkproj p
  STUB_NIX_TRUSTED=1 sandbox
  assert_eq $rc 1
  assert_contains "$err" "trusted user of the nix-daemon"
  assert_eq $#args 0 "docker must not run"
}

test_trusted_nix_user_can_be_allowed() {
  mkproj p
  STUB_NIX_TRUSTED=1 CLAUDE_SANDBOX_ALLOW_TRUSTED=1 sandbox
  assert_eq $rc 0
}

test_warns_when_trust_unknown() {
  mkproj p
  STUB_NIX_TRUSTED= sandbox
  assert_eq $rc 0
  assert_contains "$err" "could not tell whether the nix-daemon trusts you"
}

test_warns_on_vulnerable_daemon_versions() {
  mkproj p
  local v
  for v in 2.27.9 2.30.3 2.34.4; do
    STUB_NIX_VERSION=$v sandbox
    assert_contains "$err" "nix-daemon $v has known root escalations"
  done
  for v in 2.30.4 2.31.4 2.35.0 2.93.0 3.11.2; do
    STUB_NIX_VERSION=$v sandbox
    assert_not_contains "$err" "root escalations"
  done
}

test_warns_when_the_advisory_list_is_old() {
  mkproj p
  _CLAUDE_SANDBOX_ADVISORIES_CHECKED=2000-01 sandbox
  assert_eq $rc 0
  assert_contains "$err" "vulnerable nix-daemon versions dates from 2000-01"
}

test_warns_without_nixpkgs() {
  mkproj p
  STUB_NIXPKGS= sandbox
  assert_contains "$err" "no <nixpkgs> on host"
  assert_eq ${#${(M)args:#NIX_PATH=*}} 0
}

# --- The docker command line

test_basic_invocation() {
  mkproj 'my proj' git
  sandbox claude --resume
  assert_eq $rc 0
  assert_eq "$err" ""
  local hash=$(print -rn -- "$T/my proj" | sha256sum)
  local id=my_proj-${hash[1,8]}
  assert_eq ${args[1]} run
  assert_has -i $args
  assert_lacks -it $args
  assert_has --init $args
  assert_has --cap-drop=ALL $args
  assert_has --security-opt=no-new-privileges $args
  assert_has bridge $args
  assert_eq ${${(M)args:#claude-my_proj-*}%-*} claude-$id
  assert_has "claude-cache-$id:/home/claude/.cache" $args
  assert_has "$T/my proj:/work/$id" $args
  assert_has /nix/store:/nix/store:ro $args
  assert_has "NIX_PATH=nixpkgs=$T/nixpkgs" $args
  assert_has "PATH=$T/bin:/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin" $args
  assert_has /work/$id $args
  assert_eq "$(cmd_after_image)" $'claude\n--resume'
}

test_same_name_projects_get_distinct_ids() {
  mkproj a/app; sandbox; local one=${(M)args:#claude-cache-*}
  mkproj b/app; sandbox; local two=${(M)args:#claude-cache-*}
  [[ $one != $two ]] || fail "both projects use $one"
}

test_image_can_be_overridden() {
  mkproj p
  export CLAUDE_SANDBOX_IMAGE=my-image
  sandbox echo hi
  assert_eq "$(cmd_after_image)" $'echo\nhi'
}

test_double_dash_ends_options() {
  mkproj p
  sandbox -- --config-rw
  assert_eq "$(cmd_after_image)" --config-rw
  assert_has "$HOME/.config/claude-sandbox/claude/settings.json:/home/claude/.claude/settings.json:ro" $args
}

test_memory_limit() {
  mkproj p
  sandbox
  assert_has --memory=8g $args
  CLAUDE_SANDBOX_MEMORY=32g sandbox
  assert_has --memory=32g $args
}

test_exit_status_is_the_containers() {
  mkproj p
  STUB_DOCKER_RC=7 sandbox
  assert_eq $rc 7
}

# --- Claude's configuration

test_claude_config_is_read_only_by_default() {
  mkproj p
  sandbox
  local cc=$HOME/.config/claude-sandbox/claude f
  assert_has "$cc:/home/claude/.claude" $args
  for f in settings.json CLAUDE.md agents commands skills hooks plugins; do
    assert_has "$cc/$f:/home/claude/.claude/${f}:ro" $args
  done
  assert_eq "$(<$cc/settings.json)" '{}'
}

test_config_rw_leaves_config_writable() {
  mkproj p
  sandbox --config-rw claude
  assert_eq ${#${(M)args:#*/home/claude/.claude/*:ro}} 0
  assert_eq "$(cmd_after_image)" claude
}

test_claude_sessions_are_per_project() {
  mkproj a/app; sandbox; local one=${(M)args:#*:/home/claude/.claude/projects}
  mkproj b/app; sandbox; local two=${(M)args:#*:/home/claude/.claude/projects}
  [[ -n $one && $one != $two ]] || fail "both projects use [$one]"
  [[ $one == $HOME/.config/claude-sandbox/projects/app-*:* ]] || fail "unexpected [$one]"
  [[ -d ${one%%:*} ]] || fail "${one%%:*} should be created"
  assert_has /work/${${two%%:*}:t} $args
}

test_existing_settings_are_kept() {
  mkdir -p $HOME/.config/claude-sandbox/claude
  print '{"model":"x"}' > $HOME/.config/claude-sandbox/claude/settings.json
  mkproj p
  sandbox
  assert_eq "$(<$HOME/.config/claude-sandbox/claude/settings.json)" '{"model":"x"}'
}

# Run the wrapper and keep a copy of the instructions it hands Claude; sets
# $instructions too
sandbox_instructions() {
  STUB_DOCKER_DOES='cp "$(sed -n "s|:/etc/claude-code/CLAUDE.md:ro\$||p" "$T/docker.args")" "$T/instructions.md"' \
    sandbox "$@"
  instructions=$(<$T/instructions.md)
}

test_instructions_describe_the_session() {
  mkproj p git
  sandbox_instructions
  local src=${${(M)args:#*:/etc/claude-code/CLAUDE.md:ro}%%:*}
  [[ -n $src ]] || fail "instructions not mounted"
  [[ ! -e $src ]] || fail "$src left behind"
  local cfg=$HOME/.config/claude-sandbox
  assert_contains "$instructions" "| \`$(wd)\` (this project, read-write) | \`$T/p\` |"
  assert_contains "$instructions" "\`$cfg/claude\`"
  assert_contains "$instructions" "\`$cfg/projects/${$(wd):t}\`"
  assert_contains "$instructions" "Started without \`--config-rw\`"
  assert_not_contains "$instructions" "--kind"
}

test_instructions_follow_the_options() {
  mkproj p
  sandbox_instructions --config-rw --kind dev
  assert_contains "$instructions" "Started with \`--config-rw\`"
  assert_not_contains "$instructions" "read-only. To change them"
  assert_contains "$instructions" "Started with \`--kind dev\`"
}

# --- Git

test_git_config_and_hooks_are_read_only() {
  mkproj p git
  rm -rf .git/hooks
  sandbox
  assert_has "$T/p/.git:$(wd)/.git" $args
  assert_has "$T/p/.git/config:$(wd)/.git/config:ro" $args
  assert_has "$T/p/.git/hooks:$(wd)/.git/hooks:ro" $args
  [[ -d .git/hooks ]] || fail "hooks dir should be created so it can be mounted"
}

test_submodule_gitdirs_are_protected() {
  mkproj p git
  local d
  for d in .git/modules/lib .git/modules/lib/modules/nested; do
    mkdir -p $d/objects && cp .git/config .git/HEAD $d/
  done
  # A submodule branch named "config" is not a gitdir
  mkdir -p .git/modules/lib/refs/heads && touch .git/modules/lib/refs/heads/config
  sandbox
  for d in .git/modules/lib .git/modules/lib/modules/nested; do
    assert_has "$T/p/$d/config:$(wd)/$d/config:ro" $args
    assert_has "$T/p/$d/hooks:$(wd)/$d/hooks:ro" $args
  done
  assert_eq ${#${(M)args:#*/refs/heads*}} 0
}

test_only_gitdirs_are_mounted_without_submodules() {
  # An empty submodule list once produced "." as a gitdir: the project's own
  # config/ and hooks/ were mounted read-only, and hooks/ was created
  mkproj p git
  sandbox
  assert_eq ${#${(M)args:#*:$(wd)/*}} 3 ".git, its config and its hooks only"
  assert_eq ${#${(M)args:#./*}} 0
  [[ ! -e hooks && ! -e config ]] || fail "created files in the project root"
}

test_worktree_config_is_protected_when_enabled() {
  mkproj p git
  sandbox
  assert_eq ${#${(M)args:#*config.worktree*}} 0
  git config extensions.worktreeConfig true
  sandbox
  [[ -f .git/config.worktree ]] || fail "config.worktree should be created"
  assert_has "$T/p/.git/config.worktree:$(wd)/.git/config.worktree:ro" $args
}

test_linked_worktrees_are_protected() {
  mkproj p git
  git commit -q --allow-empty -m init
  git worktree add -q ../elsewhere
  sandbox
  assert_has "$T/p/.git/worktrees/elsewhere/commondir:$(wd)/.git/worktrees/elsewhere/commondir:ro" $args
}

test_no_git_mounts_outside_a_repo() {
  mkproj p
  sandbox
  assert_eq ${#${(M)args:#*/.git*}} 0
}

test_warns_when_git_is_a_file() {
  mkproj p
  print 'gitdir: /elsewhere' > .git
  sandbox
  assert_contains "$err" "is a file (worktree/submodule)"
}

test_commits_as_host_identity() {
  mkproj p
  sandbox
  assert_has "GIT_AUTHOR_NAME=Ada Test" $args
  assert_has "GIT_COMMITTER_EMAIL=ada@example.test" $args
}

test_warns_without_git_identity() {
  : > $GIT_CONFIG_GLOBAL
  mkproj p
  sandbox
  assert_contains "$err" "user.name/user.email not set"
  assert_eq ${#${(M)args:#GIT_*}} 0
}

# --- kind

test_kind_mounts_only_that_cluster() {
  mkproj p
  sandbox --kind dev claude
  local kc=$HOME/.config/claude-sandbox/kind-dev.kubeconfig
  assert_has kind $args
  assert_lacks bridge $args
  assert_has "$kc:/home/claude/.kube/config:ro" $args
  assert_eq "$(<$kc)" "kubeconfig for dev"
  [[ $(ls -l $kc) == -rw-------* ]] || fail "kubeconfig must be private: $(ls -l $kc)"
  [[ ! -e $kc.tmp ]] || fail "leftover $kc.tmp"
  assert_eq "$(cmd_after_image)" claude
}

test_kind_failure_aborts_cleanly() {
  mkproj p
  STUB_KIND_FAIL=1 sandbox --kind dev
  assert_eq $rc 1
  assert_eq $#args 0 "docker must not run"
  [[ ! -e $HOME/.config/claude-sandbox/kind-dev.kubeconfig.tmp ]] || fail "leftover .tmp"
}

test_kind_requires_a_name() {
  mkproj p
  sandbox --kind
  assert_eq $rc 1
  assert_contains "$err" "usage: claude-sandbox --kind"
}

# --- Post-session report

test_report_is_silent_after_a_clean_session() {
  mkproj p git
  print 'use flake' > .envrc
  touch -d '1 minute ago' .envrc
  STUB_DOCKER_DOES='echo hi > notes.txt' sandbox
  assert_eq "$err" ""
}

test_report_lists_nested_repositories() {
  mkproj p git
  STUB_DOCKER_DOES='mkdir -p sub/.git vendor/x/objects vendor/x/refs && touch vendor/x/HEAD && mkdir -p w && echo "gitdir: /tmp" > w/.git' sandbox
  assert_contains "$err" "nested git repositories"
  assert_contains "$err" "$T/p/sub/.git"
  assert_contains "$err" "$T/p/vendor/x"
  assert_contains "$err" "$T/p/w/.git"
  assert_not_contains "$err" "$T/p/.git"$'\n'
}

test_report_quarantines_commondir() {
  mkproj p git
  STUB_DOCKER_DOES='echo /tmp/evil > .git/commondir' sandbox
  assert_contains "$err" "quarantined"
  [[ ! -e .git/commondir ]] || fail ".git/commondir still in place"
  assert_eq "$(<.git/commondir.quarantined)" /tmp/evil
}

test_report_quarantines_dangling_commondir_symlink() {
  mkproj p git
  STUB_DOCKER_DOES='ln -s /nonexistent .git/commondir' sandbox
  assert_contains "$err" "quarantined"
  [[ ! -L .git/commondir ]] || fail ".git/commondir still in place"
}

test_report_lists_changed_host_executed_files() {
  mkproj p git
  mkdir -p .vscode .github/workflows
  touch flake.nix justfile README.md
  touch -d '1 minute ago' flake.nix justfile README.md
  STUB_DOCKER_DOES='echo x >> flake.nix; echo x >> README.md; touch .vscode/tasks.json .github/workflows/ci.yml .envrc' sandbox
  assert_contains "$err" "changed files your host may execute"
  local f
  for f in flake.nix .vscode/tasks.json .github/workflows/ci.yml .envrc; do
    assert_contains "$err" "$T/p/$f"
  done
  assert_not_contains "$err" justfile
  assert_not_contains "$err" README.md
}

# --- Entrypoint (runs entrypoint.sh directly, with stub dev-shell tools)

# ep ARGS...: run the entrypoint in $PWD; sets $out and $err
ep() {
  stub direnv <<<'echo "direnv $*"'
  stub nix-shell <<<'echo "nix-shell $*"'
  stub say <<<'echo "say $*"'
  [[ -n $EP_NO_NIX ]] && rm -f $T/bin/nix || stub nix <<<'echo "nix $*"'
  out=$(bash $ROOT/entrypoint.sh "$@" 2> $T/stderr)
  err=$(<$T/stderr)
}

test_ep_envrc_wins_and_is_allowed() {
  mkproj p
  touch .envrc flake.nix shell.nix
  ep say hi
  assert_eq "$out" $'direnv allow .\ndirenv exec . say hi'
}

test_ep_starts_claude_by_default() {
  mkproj p
  touch flake.nix
  ep
  assert_eq "$out" "nix develop --command claude"
}

test_ep_flake() {
  mkproj p
  touch flake.nix shell.nix
  ep say a b
  assert_eq "$out" "nix develop --command say a b"
}

test_ep_shell_nix_quotes_arguments() {
  mkproj p
  touch shell.nix
  ep say 'a b' "c'd"
  assert_eq "$out" "nix-shell --run say a\\ b c\\'d "
}

test_ep_default_nix() {
  mkproj p
  touch default.nix
  ep say
  assert_eq "$out" "nix-shell --run say "
}

test_ep_plain_project_runs_command() {
  mkproj p
  ep say hello
  assert_eq "$out" "say hello"
}

test_ep_bash_is_the_images_interactive_bash() {
  # Dev shells put a readline-less bash first in PATH (no tab completion)
  mkproj p
  touch flake.nix
  ep bash
  assert_eq "$out" "nix develop --command /bin/bash"
  ep bash -c 'echo x'
  assert_eq "$out" "nix develop --command /bin/bash -c echo x"
}

test_ep_warns_without_nix() {
  mkproj p
  touch default.nix
  EP_NO_NIX=1 ep say hi
  assert_contains "$err" "nix not found"
  assert_eq "$out" "say hi"
}

run_tests "$@"
