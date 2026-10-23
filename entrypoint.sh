#!/usr/bin/env bash
# Wrap the command in the project's dev environment, if it declares one.
# Priority: .envrc (direnv) > flake.nix (nix develop) > shell.nix/default.nix (nix-shell).
set -euo pipefail

[ $# -eq 0 ] && set -- claude

# Dev shells put nixpkgs' stdenv bash first in PATH, and that bash is built
# without readline: no tab completion, and PS1 shows a literal "\[\]".
# Pin the image's interactive bash before entering the environment.
[ "$1" = bash ] && set -- /bin/bash "${@:2}"

if [ -f .envrc ] && command -v direnv >/dev/null 2>&1; then
  # The container only sees the project you mounted, so trust its .envrc.
  direnv allow .
  exec direnv exec . "$@"
fi

if command -v nix >/dev/null 2>&1; then
  if [ -f flake.nix ]; then
    exec nix develop --command "$@"
  elif [ -f shell.nix ] || [ -f default.nix ]; then
    exec nix-shell --run "$(printf '%q ' "$@")"
  fi
elif [ -f flake.nix ] || [ -f shell.nix ] || [ -f default.nix ]; then
  # The wrapper puts the host's nix on PATH; without it there is no dev shell.
  echo "entrypoint: nix not found, starting without the project's dev shell" >&2
fi

exec "$@"
