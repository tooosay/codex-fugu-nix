{
  description = "Codex bundled with the SakanaAI Fugu profile";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream Fugu profile data. This is pinned by flake.lock, not vendored
    # into this repository.
    fugu-src = {
      url = "github:SakanaAI/fugu";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    fugu-src,
  }: let
    systems = [
      "x86_64-linux"
    ];

    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (
        system:
          f (import nixpkgs {inherit system;})
      );
  in {
    packages = forAllSystems (pkgs: rec {
      codex-fugu = pkgs.callPackage ./pkgs/codex-fugu {
        fuguSrc = fugu-src;
      };
      default = codex-fugu;
    });

    apps = forAllSystems (pkgs: {
      default = {
        type = "app";
        program = "${self.packages.${pkgs.system}.default}/bin/codex-fugu";
      };

      codex-fugu = {
        type = "app";
        program = "${self.packages.${pkgs.system}.codex-fugu}/bin/codex-fugu";
      };
    });

    overlays.default = final: _prev: {
      codex-fugu = final.callPackage ./pkgs/codex-fugu {
        fuguSrc = fugu-src;
      };
    };

    # Guards the fugu-src bump workflow: upstream verifies its configs
    # against a specific Codex version (BUNDLE_CODEX_VERSION in
    # configs/bundle.sh). If Sakana bumps that pin, updating fugu-src alone
    # would silently produce an unverified "new config x old Codex"
    # combination. This check makes `nix flake check` fail loudly instead,
    # signalling that codexVersion (and the hashes) need a matching bump.
    checks = forAllSystems (pkgs: {
      codex-version-match = pkgs.runCommand "codex-version-match" {} ''
        want="$(sed -n 's/^BUNDLE_CODEX_VERSION="\(.*\)"/\1/p' \
          ${fugu-src}/configs/bundle.sh)"
        have=${pkgs.lib.escapeShellArg self.packages.${pkgs.system}.codex-fugu.version}

        if [ -z "$want" ]; then
          echo "could not read BUNDLE_CODEX_VERSION from fugu-src; upstream layout changed?" >&2
          exit 1
        fi
        if [ "$want" != "$have" ]; then
          echo "fugu-src expects Codex $want but this flake pins $have" >&2
          echo "bump codexVersion (and codexHashes) in pkgs/codex-fugu/default.nix" >&2
          exit 1
        fi
        touch "$out"
      '';
      deadnix =
        pkgs.runCommand "deadnix-check" {
          nativeBuildInputs = [pkgs.deadnix];
        } ''
          deadnix --fail ${./.}
          touch "$out"
        '';
    });

    homeModules.default = import ./modules/home-manager.nix {inherit self;};

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
