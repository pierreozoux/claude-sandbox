set shell := ["bash", "-euo", "pipefail", "-c"]

image := env("CLAUDE_SANDBOX_IMAGE", "claude-sandbox")
export DOCKER_HOST := env("CLAUDE_SANDBOX_DOCKER_HOST", "unix:///var/run/docker.sock")

# List recipes
default:
    @just --list

# Build the image for your uid/gid (extra docker build flags allowed)
build *flags:
    docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) {{flags}} -t {{image}} .

# Update everything: base image pin, flake inputs, Claude Code pin, then rebuild
update:
    docker pull -q debian:trixie-slim > /dev/null
    digest=$(docker inspect --format '{{{{index .RepoDigests 0}}' debian:trixie-slim); \
      sed -i "s|^FROM debian:trixie-slim@sha256:[0-9a-f]*|FROM debian:trixie-slim@${digest#*@}|" Dockerfile
    nix flake update
    just pin-claude
    just build --no-cache
    git diff --stat -- Dockerfile flake.lock
    @echo "Also check https://github.com/NixOS/nix/security/advisories, and update the"
    @echo "vulnerable versions and _CLAUDE_SANDBOX_ADVISORIES_CHECKED in claude-sandbox.zsh"

# Pin Claude Code to VERSION (default: the latest release) and its checksums
pin-claude version="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    base=https://downloads.claude.ai/claude-code-releases
    v={{version}}
    [[ $v =~ ^[0-9] ]] || v=$(curl -fsSL "$base/$v")
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "pin-claude: not a version: $v" >&2; exit 1; }
    manifest=$(curl -fsSL "$base/$v/manifest.json" | tr -d ' \n')
    checksum() { grep -o "\"linux-$1\":{[^}]*" <<< "$manifest" | grep -o '[0-9a-f]\{64\}'; }
    x64=$(checksum x64)
    arm64=$(checksum arm64)
    sed -i -e "s/^ARG CLAUDE_VERSION=.*/ARG CLAUDE_VERSION=$v/" \
           -e "s/^ARG CLAUDE_SHA256_X64=.*/ARG CLAUDE_SHA256_X64=$x64/" \
           -e "s/^ARG CLAUDE_SHA256_ARM64=.*/ARG CLAUDE_SHA256_ARM64=$arm64/" Dockerfile
    echo "Claude Code $v"

# All tests: lint + unit tests in the Nix sandbox, then real containers
test:
    nix flake check
    just build
    zsh tests/integration.zsh

# Remove the per-project cache volumes
clean-volumes:
    docker volume ls -q --filter name=claude-cache- | xargs -r docker volume rm
