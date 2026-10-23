# To do

## Next: a proxy on the host, for credentials and egress

Today every session can read the shared login (`~/.config/claude-sandbox/auth`),
and the container has unrestricted network access. A proxy running on the host,
outside the containers, would fix both at once.

**Credentials.** Claude Code can send its API traffic over a unix socket
(`ANTHROPIC_UNIX_SOCKET`, with `CLAUDE_CODE_OAUTH_TOKEN` set to the
`ssh-placeholder` sentinel; this is how `claude ssh` works). The proxy holds
the login, refreshes it itself, and adds the token to each request, so no
session ever sees a token. This closes the gaps listed in the README
(Explanation, Claude's configuration):

- a stolen login, usable for weeks;
- a replaced login, used by parallel sessions until it is caught, or never
  caught when the session puts the original back;
- a replaced refresh token that passes the account check once;
- an expired login after a crash, quarantined as if replaced.

The account check, the `auth/` directory and its pruning then go away.

**Egress filtering.** The same proxy can be the containers' only way out
(`HTTPS_PROXY`, and a Docker network with no other route), with an allowlist:
the Anthropic API, package registries, the forges the user names. That narrows
exfiltration, which the threat model does not cover today. Nix fixed-output
derivations still reach the network from the host's nix-daemon, so the README
must keep saying so.

To find out first:

- which endpoints Claude Code needs (a logging pass-through proxy, for a few
  real sessions), and whether it all goes through the socket;
- how the proxy refreshes the token: Claude Code's OAuth client and token
  endpoint are not documented;
- whether concurrent sessions cope with one refresh chain held by the proxy;
- how the `--kind` network fits, and the host's `localhost`;
- the proxy's own isolation: a separate host user, or a sidecar container.
