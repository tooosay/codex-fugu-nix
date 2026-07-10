{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.codex-fugu;

  codexHomeAbs = "${config.home.homeDirectory}/${cfg.codexHome}";
  codexConfigFile = "${codexHomeAbs}/config.toml";

  tomlFormat = pkgs.formats.toml {};

  # Upstream install.sh renders {{CODEX_HOME}} to the absolute Codex home at
  # deploy time (see render_template in SakanaAI/fugu scripts/install.sh).
  # We do the same, then parse the result as TOML and let the user's
  # profileSettings win via recursiveUpdate. Reading from the fugu-src flake
  # input keeps this at eval time (no IFD). Note the profile therefore tracks
  # this flake's fugu-src pin even if `package` is overridden with one built
  # from a different fuguSrc.
  upstreamProfile = builtins.fromTOML (
    builtins.replaceStrings ["{{CODEX_HOME}}"] [codexHomeAbs] (
      builtins.readFile "${self.inputs.fugu-src}/configs/formats/modern/files/fugu.config.toml"
    )
  );

  fuguProfileConfig =
    tomlFormat.generate "fugu.config.toml"
    (lib.recursiveUpdate upstreamProfile cfg.profileSettings);

  mergePython = pkgs.python3.withPackages (ps: [ps.tomli-w]);

  # Three-way merge: RUNTIME := generated + (runtime - baseline).
  # The baseline is the previous generation's generated profile; whatever the
  # runtime file changed relative to it (e.g. Codex persisting a /model
  # choice) is user intent and wins over the new generated profile. Keys the
  # user never touched keep following upstream + profileSettings.
  profileMergeScript = pkgs.writeText "fugu-profile-merge.py" ''
    import os
    import sys
    import tomllib

    import tomli_w


    def diff(runtime, base):
        out = {}
        for k, v in runtime.items():
            if k not in base:
                out[k] = v
            elif isinstance(v, dict) and isinstance(base[k], dict):
                sub = diff(v, base[k])
                if sub:
                    out[k] = sub
            elif v != base[k]:
                out[k] = v
        return out


    def recursive_update(a, b):
        out = dict(a)
        for k, v in b.items():
            if k in out and isinstance(out[k], dict) and isinstance(v, dict):
                out[k] = recursive_update(out[k], v)
            else:
                out[k] = v
        return out


    def load(path):
        with open(path, "rb") as f:
            return tomllib.load(f)


    generated_path, runtime_path, baseline_path = sys.argv[1:4]
    generated = load(generated_path)
    runtime = load(runtime_path)
    base = load(baseline_path) if os.path.exists(baseline_path) else generated

    merged = recursive_update(generated, diff(runtime, base))

    tmp = runtime_path + ".tmp"
    with open(tmp, "wb") as f:
        tomli_w.dump(merged, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, runtime_path)
  '';

  launcher = pkgs.writeShellApplication {
    name = cfg.wrapperName;
    text = ''
      ${lib.optionalString (cfg.apiKeyFile != null) (
        let
          apiKeyFile = cfg.apiKeyFile;
          apiKeyFileArg = lib.escapeShellArg apiKeyFile;
          errorMessageArg = lib.escapeShellArg "${cfg.wrapperName}: apiKeyFile is not readable: ${apiKeyFile}";
        in ''
          if [ ! -r ${apiKeyFileArg} ]; then
            printf '%s\n' ${errorMessageArg} >&2
            exit 1
          fi
          SAKANA_API_KEY="$(tr -d '\r\n' < ${apiKeyFileArg})"
          export SAKANA_API_KEY
        ''
      )}

      exec ${cfg.package}/bin/codex-fugu "$@"
    '';
  };
in {
  options.programs.codex-fugu = {
    enable = lib.mkEnableOption "SakanaAI Fugu profile for OpenAI Codex";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      defaultText = lib.literalExpression "inputs.codex-fugu.packages.${pkgs.system}.default";
      description = "codex-fugu package to install.";
    };

    wrapperName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9._+-]+";
      default = "codex-fugu";
      description = "Name of the launcher installed into the user profile.";
    };

    codexHome = lib.mkOption {
      type = lib.types.str;
      default = ".codex";
      description = "Codex home directory relative to home.homeDirectory.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression "config.sops.secrets.sakana-api-key.path";
      description = ''
        Runtime path to a file containing SAKANA_API_KEY.

        This option intentionally accepts only strings, not Nix paths. Do not
        pass a path literal such as `./sakana-api-key`, because Nix path
        literals are copied to the Nix store. Use a runtime secret path such as
        `config.sops.secrets.sakana-api-key.path` instead.
      '';
    };

    manageFuguJson = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install fugu.json into the Codex home directory.";
    };

    manageConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to add the Sakana provider block to Codex config.toml.";
    };

    manageProfileConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install fugu.config.toml into the Codex home directory.
        This is the modern (Codex >= 0.134.0) profile format that makes
        `codex -p fugu` resolve; without it the profile does not exist.
        Set to false to own the file manually.
      '';
    };

    profileSettings = lib.mkOption {
      type = tomlFormat.type;
      default = {};
      example = lib.literalExpression ''
        {
          model_reasoning_effort = "medium";
          features.image_generation = true;
        }
      '';
      description = ''
        Settings merged (TOML-structure-aware, via recursiveUpdate) over the
        upstream fugu profile. Keys set here win over upstream values. Text
        appending is deliberately not offered: upstream now contains tables
        (e.g. [features]), so appended top-level keys would silently nest
        into the wrong table.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.codexHome != "" && !(lib.hasPrefix "/" cfg.codexHome) && !(builtins.elem ".." (lib.splitString "/" cfg.codexHome));
        message = "programs.codex-fugu.codexHome must be a non-empty relative path without '..' components.";
      }
      {
        assertion = cfg.apiKeyFile == null || !(lib.hasPrefix "${builtins.storeDir}/" cfg.apiKeyFile);
        message = ''
          programs.codex-fugu.apiKeyFile must not point into ${builtins.storeDir}.
          Do not pass Nix path literals like ./sakana-api-key or interpolated
          store paths like "''${./sakana-api-key}". Use a runtime secret path,
          for example config.sops.secrets.sakana-api-key.path.
        '';
      }
    ];

    home.packages = [launcher];

    home.file."${cfg.codexHome}/fugu.json" = lib.mkIf cfg.manageFuguJson {
      source = "${cfg.package}/share/codex-fugu/fugu.json";
    };

    # fugu.config.toml must be a writable regular file, not a store symlink:
    # Codex itself writes to the active profile file (e.g. persisting /model).
    # Deployment is therefore an activation-time merge instead of home.file.
    home.activation.codexFuguProfile = lib.mkIf cfg.manageProfileConfig (
      lib.hm.dag.entryAfter ["writeBoundary" "linkGeneration"] ''
        (
        set -euo pipefail

        profile=${lib.escapeShellArg "${codexHomeAbs}/fugu.config.toml"}
        baseline=${lib.escapeShellArg "${codexHomeAbs}/.fugu.config.toml.baseline"}
        generated=${lib.escapeShellArg "${fuguProfileConfig}"}

        mkdir -p "$(dirname "$profile")"

        if [ ! -e "$profile" ] || [ -L "$profile" ]; then
          # First deployment, or migration from the old read-only symlink.
          rm -f "$profile"
          install -m 0644 "$generated" "$profile"
        else
          ${mergePython}/bin/python3 ${profileMergeScript} \
            "$generated" "$profile" "$baseline"
        fi

        # Remember this generation's declarative profile as the next baseline.
        # A copy, not a symlink: old generations may be GC'd and a dangling
        # baseline would silently degrade the merge to the adoption path.
        install -m 0444 "$generated" "$baseline"
        )
      ''
    );

    home.activation.fuguCodexConfig = lib.mkIf cfg.manageConfig (
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        (
        set -euo pipefail

        config_file=${lib.escapeShellArg codexConfigFile}
        provider_file=${lib.escapeShellArg "${cfg.package}/share/codex-fugu/model_providers.sakana.toml"}
        start_marker="# >>> codex-fugu >>>"
        end_marker="# <<< codex-fugu <<<"

        mkdir -p "$(dirname "$config_file")"

        tmp="$(mktemp "''${TMPDIR:-/tmp}/codex-fugu-config.XXXXXXXXXX")"
        trap 'rm -f "$tmp"' EXIT

        if [ -f "$config_file" ]; then
          ${pkgs.gawk}/bin/awk -v start="$start_marker" -v end="$end_marker" '
            $0 == start { skip = 1; next }
            $0 == end { skip = 0; next }
            skip { next }
            { lines[++n] = $0 }
            END {
              while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
              for (i = 1; i <= n; i++) print lines[i]
            }
          ' "$config_file" > "$tmp"
        else
          : > "$tmp"
        fi

        printf '\n%s\n' "$start_marker" >> "$tmp"
        cat "$provider_file" >> "$tmp"
        printf '%s\n' "$end_marker" >> "$tmp"
        install -m 0600 "$tmp" "$config_file"
        )
      ''
    );
  };
}
