{
  description = "Run Claude Code in a Docker sandbox that reuses the host's Nix store";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Docker itself comes from the host: the sandbox needs its rootful daemon
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ just zsh git shellcheck kind ];
          # nixpkgs for the integration tests' dev-shell fixtures
          NIXPKGS_PATH = "${nixpkgs}";
        };
      });

      # `nix flake check`: lint and the unit tests (they need no docker or daemon)
      checks = forAllSystems (pkgs: {
        unit = pkgs.runCommand "claude-sandbox-unit-tests"
          { nativeBuildInputs = with pkgs; [ zsh bash git findutils coreutils gnugrep gnused ]; }
          ''
            cp -r ${self} src && chmod -R u+w src && cd src
            HOME=$TMPDIR zsh tests/unit.zsh
            touch $out
          '';
        lint = pkgs.runCommand "claude-sandbox-lint"
          { nativeBuildInputs = with pkgs; [ shellcheck zsh ]; }
          ''
            shellcheck ${./entrypoint.sh}
            for f in ${./claude-sandbox.zsh} ${./tests}/*.zsh; do zsh -n $f; done
            touch $out
          '';
      });
    };
}
