#!/usr/bin/env zsh
# `just install`: set up the reviewed config in ~/.config/claude-sandbox,
# migrate the read-only layout of earlier versions, and import what your host's
# Claude Code learned (~/.claude: CLAUDE.md, agents, commands, skills, and each
# project's memory), through the same review as a session's changes.
# Safe to run again: it only adds what is not there yet.
#
#   CLAUDE_SANDBOX_IMPORT_FROM   what to import (default: ~/.claude; empty: nothing)
typeset -g _CLAUDE_SANDBOX_HERE=${${(%):-%x}:A:h}
source $_CLAUDE_SANDBOX_HERE/claude-sandbox.zsh

# _claude_sandbox_migrate CFG: move the shared state of the read-only layout
# (CFG/claude) to where sessions now find it
_claude_sandbox_migrate() {
  emulate -L zsh
  local cfg=$1 old=$1/claude p id st
  # A project id as the wrapper makes it: name, dash, 8 hex digits
  local idpat='/work/*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  local -a theirs=($old/plugins/*(DN)) ours=($cfg/plugins/*(DN))
  if [[ -f $old/.credentials.json && ! -e $cfg/auth/.credentials.json ]]; then
    mv $old/.credentials.json $cfg/auth/ && print "Moved your login to $cfg/auth"
  fi
  if (( $#theirs && ! $#ours )); then
    mv $theirs $cfg/plugins/ && print "Moved plugins to $cfg/plugins"
  fi
  if [[ -f $old/.claude.json ]]; then
    # New projects start from the harmless part: no project, no MCP server
    [[ -e $cfg/claude.json.template ]] ||
      jq 'del(.projects, .mcpServers)' $old/.claude.json > $cfg/claude.json.template
    for p in ${(f)"$(jq -r '.projects // {} | keys[]' $old/.claude.json)"}; do
      [[ $p == ${~idpat} && ${p#/work/} != */* ]] || continue
      st=$cfg/state/${p#/work/}
      [[ -e $st/claude.json ]] && continue
      mkdir -p $st
      jq --arg p $p 'del(.mcpServers) | .projects = {($p): .projects[$p]}' \
        $old/.claude.json > $st/claude.json
    done
  fi
  if [[ -f $old/history.jsonl ]]; then
    for p in ${(ou)${(f)"$(jq -r '.project // empty' $old/history.jsonl)"}}; do
      [[ $p == ${~idpat} && ${p#/work/} != */* ]] || continue
      st=$cfg/state/${p#/work/}
      [[ -e $st/history.jsonl ]] && continue
      mkdir -p $st
      jq -c --arg p $p 'select(.project == $p)' $old/history.jsonl > $st/history.jsonl
    done
  fi
  [[ -e $cfg/claude.json.template ]] ||
    print '{"hasCompletedOnboarding": true}' > $cfg/claude.json.template
}

# _claude_sandbox_import_config CFG SRC: CLAUDE.md, agents, commands and skills
# from SRC, as a pending change (branch session/import-*). Hooks and settings
# run code, so they are only pointed out.
_claude_sandbox_import_config() {
  emulate -L zsh
  zmodload -F zsh/datetime p:EPOCHSECONDS
  zmodload -F zsh/system b:zsystem
  local cfg=$1 src=$2 repo=$1/config
  local sid=import-$EPOCHSECONDS
  local wt=$cfg/sessions/$sid fd f rel d mine theirs
  [[ -d $src ]] || return 0

  mkdir $wt && : >> $wt.lock || return 1
  zsystem flock -t 0 -f fd $wt.lock || return 1
  _claude_sandbox_cgit $repo rev-parse HEAD > $wt.base
  _claude_sandbox_wgit $repo $wt read-tree HEAD &&
    _claude_sandbox_wgit $repo $wt checkout-index -a || return 1

  if [[ -f $src/CLAUDE.md && ! -L $src/CLAUDE.md && -s $src/CLAUDE.md ]]; then
    mine=$(<$wt/CLAUDE.md) theirs=$(<$src/CLAUDE.md)
    if [[ -z $mine ]]; then
      cp $src/CLAUDE.md $wt/CLAUDE.md
    elif [[ $mine != *$theirs* ]]; then
      print -r -- $'\n'$theirs >> $wt/CLAUDE.md
    fi
  fi
  # Only regular files, and never over what the sandbox already has
  for d in agents commands skills; do
    for f in $src/$d/**/*(.DN); do
      rel=${f#$src/}
      [[ -e $wt/$rel || -L $wt/$rel ]] && continue
      mkdir -p $wt/${rel:h} && cp -p $f $wt/$rel
    done
  done
  local -a hooks=($src/hooks/*(DN))
  if (( $#hooks )) || { [[ -f $src/settings.json ]] &&
       [[ $(<$src/settings.json) != (|'{}'|$'{\n}') ]] }; then
    print "Not imported, because they run code: $src/settings.json and $src/hooks."
    print "  Read them, then copy what you want into $repo and commit it there."
  fi

  _claude_sandbox_session_commit $cfg $sid
  rm -rf $wt $wt.base $wt.index $wt.lock
  zsystem flock -u $fd
}

# _claude_sandbox_import_memory CFG SRC: each project's memory in SRC, into
# the sandbox's memory of the same project, after review
_claude_sandbox_import_memory() {
  emulate -L zsh
  local cfg=$1 src=$2 mdir cwd line name hash id key dest f t i n
  local tmp=$(mktemp -d)
  local -a files todo dirs dests cwds found
  for mdir in $src/projects/*/memory(N/); do
    files=($mdir/*.md(.N))
    (( $#files )) || continue
    # The project's path, from its transcripts (the directory name is lossy)
    found=(${(f)"$(grep -h -o -m1 -E '"cwd":"[^"]+"' ${mdir:h}/*.jsonl(.N) 2>/dev/null)"})
    line=${found[1]}
    cwd=${${line#\"cwd\":\"}%\"}
    if [[ -z $cwd ]]; then
      print "Skipped the memory in $mdir: no transcript says which project it is"
      continue
    fi
    [[ $cwd == /work/* ]] && continue
    # The same id and directory as the wrapper and Claude Code give it
    name=${${cwd:t}//[^A-Za-z0-9_.-]/_}
    hash=$(print -rn -- $cwd | sha256sum)
    id=$name-${hash[1,8]}
    key=/work/$id
    dest=$cfg/projects/$id/${key//[^a-zA-Z0-9]/-}/memory
    # Only projects with something new
    todo=()
    for f in $files; do
      [[ ${f:t} == MEMORY.md || ! -e $dest/${f:t} ]] && todo+=($f)
    done
    (( ${#${todo:#*/MEMORY.md}} )) || continue
    n=$(( $#dirs + 1 ))
    for f in $todo; do print -r -- "### ${f:t}"; cat $f; print; done > $tmp/$n.txt
    dirs+=($mdir) dests+=($dest) cwds+=($cwd)
  done
  if (( ! $#dirs )); then
    rm -rf $tmp
    return 0
  fi
  if ! _claude_sandbox_interactive; then
    print "Skipped importing the memory of $#dirs project(s): it needs a terminal to review"
    rm -rf $tmp
    return 0
  fi

  print "Asking Opus to review the memory of $#dirs project(s)..."
  for i in {1..$#dirs}; do
    _claude_sandbox_reviewer $cfg memory $tmp/$i.txt > $tmp/$i.review &
  done
  wait
  for i in {1..$#dirs}; do
    print -rn -u2 -- "Memory of "; print -r -- "${cwds[i]}:" | _claude_sandbox_sanitize >&2
    _claude_sandbox_review $cfg memory $tmp/$i.txt $tmp/$i.review || continue
    mkdir -p ${dests[i]}
    for f in ${dirs[i]}/*.md(.N); do
      t=${dests[i]}/${f:t}
      if [[ ! -e $t ]]; then
        cp $f $t
      elif [[ ${f:t} == MEMORY.md ]]; then
        # The index: add its lines that are not there yet
        local -a have=(${(f)"$(<$t)"}) add=()
        for line in ${(f)"$(<$f)"}; do (( ${have[(Ie)$line]} )) || add+=($line); done
        (( $#add )) && print -rl -- $add >> $t
      fi
    done
    print -u2 "  imported into ${dests[i]}"
  done
  rm -rf $tmp
}

_claude_sandbox_install() {
  emulate -L zsh
  local cfg=$HOME/.config/claude-sandbox
  local src=${CLAUDE_SANDBOX_IMPORT_FROM-$HOME/.claude}
  if (( ! $+commands[jq] )); then
    print -u2 "install: jq not found; run it from the dev shell (nix develop -c just install)"
    return 1
  fi
  [[ -d $cfg/config/.git ]] || print "Creating $cfg/config, Claude's reviewed global config"
  _claude_sandbox_init_config $cfg || return 1
  _claude_sandbox_migrate $cfg
  if [[ -n $src && -d $src ]]; then
    _claude_sandbox_import_config $cfg $src
    _claude_sandbox_review_pending $cfg
    _claude_sandbox_import_memory $cfg $src
  fi
  _claude_sandbox_auth_check $cfg
  if [[ -d $cfg/claude ]]; then
    print "The previous layout, $cfg/claude, is not used any more; delete it once"
    print "  you are happy with the new one."
  fi
  print "Done. Load the wrapper in your shell: source $_CLAUDE_SANDBOX_HERE/claude-sandbox.zsh"
}

# Run as a script; sourced (by the tests), only define the functions
if [[ $ZSH_EVAL_CONTEXT == toplevel ]]; then
  _claude_sandbox_install "$@"
fi
