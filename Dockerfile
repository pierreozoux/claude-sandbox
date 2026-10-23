# debian:trixie-slim, pinned by digest. `just update` refreshes the pin.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

# Must match your host uid/gid: files in the project keep your ownership,
# and the host nix-daemon sees you as yourself (untrusted), not a new user.
ARG UID=1000
ARG GID=1000
# Claude Code, pinned by version and checksum: `just pin-claude [VERSION]`
# rewrites these three lines from the release manifest
ARG CLAUDE_VERSION=2.1.308
ARG CLAUDE_SHA256_X64=356733f185fa988e6bf3aa9a555269fdd167982a2e2a80d3c8a78037bb92ad58
ARG CLAUDE_SHA256_ARM64=fdd22e6cbb734d580f5664c48df4294eeec850218ff07f186f9af30426396ee1

# No Nix install here: /nix/store and the daemon socket come from the host.
# No sudo: nothing in the container should be able to become root.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates git less direnv bash-completion \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "${GID}" claude \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash claude

USER claude
WORKDIR /home/claude

# Pre-create so the named cache volume is seeded with the right owner
RUN mkdir -p /home/claude/.cache /home/claude/.claude

# The same layout as the official installer, without running it: download the
# pinned binary and check it against the checksum above, not the server's
RUN case "$(uname -m)" in \
      x86_64)  platform=linux-x64   sha="${CLAUDE_SHA256_X64}" ;; \
      aarch64) platform=linux-arm64 sha="${CLAUDE_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && bin="/home/claude/.local/share/claude/versions/${CLAUDE_VERSION}" \
 && mkdir -p "${bin%/*}" /home/claude/.local/bin \
 && curl -fsSL -o "${bin}" \
      "https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}/${platform}/claude" \
 && echo "${sha}  ${bin}" | sha256sum -c --quiet \
 && chmod +x "${bin}" \
 && ln -s "${bin}" /home/claude/.local/bin/claude

# direnv hook so cd-ing between projects in an interactive shell loads their .envrc
RUN echo 'eval "$(direnv hook bash)"' >> /home/claude/.bashrc

# Runs the command inside the project's dev shell (.envrc / flake.nix / shell.nix)
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV PATH="/home/claude/.local/bin:${PATH}" \
    NIX_REMOTE=daemon \
    NIX_CONFIG="experimental-features = nix-command flakes" \
    DISABLE_AUTOUPDATER=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
