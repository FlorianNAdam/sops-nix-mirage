{
  description = "Mirage FUSE filesystem with configurable file content";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    mirage = {
      url = "github:FlorianNAdam/mirage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      mirage,
      ...
    }:
    {
      nixosModules.mirage =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        with lib;
        let
          rgCommand = "${pkgs.ripgrep}/bin/rg -L -l --no-messages --glob '!**/etc/nix/**' 'MIRAGE_PLACEHOLDER' /nix/var/nix/profiles/system/";
          rgCommand2 = "${pkgs.ripgrep}/bin/rg -L -l --hidden --no-messages 'MIRAGE_PLACEHOLDER'";
          nixStore = "/nix/var/nix/profiles/system/sw/bin/nix-store";

          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          fileFinderScript = pkgs.writeShellScript "mirage-file-finder" ''
             
            echo "Searching for files containing a mirage placeholder..." >&2

            files=()

            # Find NixOS files
            while read -r path; do
              resolved_path=$(readlink -f "$path")
              echo "Found file: $resolved_path" >&2
              files+=("$resolved_path")

              # Find matching file in /etc
              if [[ "$path" == /nix/var/nix/profiles/system/etc/* ]]; then
                etc_path="/etc/''${path#/nix/var/nix/profiles/system/etc/}"
                
                if [ -f "$etc_path" ]; then

                  # Ignore symlinks from /etc to /nix/store
                  resolved_etc_path=$(readlink -f "$etc_path")
                  if [[ "$resolved_etc_path" != /nix/store/* ]]; then
                    echo "Found matching file in /etc: $resolved_etc_path" >&2
                    files+=("$resolved_etc_path")
                  fi
                fi
              fi

            done < <(${rgCommand})

            # Find Home Manager files
            gen_paths=$(${nixStore} -qR /nix/var/nix/profiles/system | grep home-manager-generation || true)

            for gen_path in $gen_paths; do
              echo "Found Home Manager generation: $gen_path" >&2
              while read -r path; do
                  resolved_path=$(readlink -f "$path")
                  echo "Found file: $resolved_path" >&2
                  files+=("$resolved_path")
              done < <(${rgCommand2} $gen_path)
            done

            # Deduplicate files
            declare -A seen
            unique_files=()

            for file in "''${files[@]}"; do
              if [[ -z "''${seen[$file]}" ]]; then
                unique_files+=("$file")
                seen["$file"]=1
              fi
            done

            printf "%s\n" "''${unique_files[@]}"
          '';

          mirageScript = pkgs.writeShellScript "mirage-dynamic-service" ''

            # Find files
            files=()
            while IFS= read -r line; do
              files+=("$line")
            done < <(${fileFinderScript})

            # Add manually specified files
            ${concatStringsSep "\n" (map (file: "files+=(\"${file}\")") config.sops.mirage.files)}

            # Early stop
            if [ ''${#files[@]} -eq 0 ]; then
              echo "No files found. Exiting..."
              exit 0
            fi

            # Deduplicate
            declare -A seen
            unique_files=()

            for file in "''${files[@]}"; do
              if [[ -z "''${seen[$file]}" ]]; then
                unique_files+=("$file")
                seen["$file"]=1
              fi
            done

            files=("''${unique_files[@]}")

            # Mirage
            echo "Starting Mirage for files: ''${files[@]}"
            ${mirage.defaultPackage.${pkgs.system}}/bin/mirage "''${files[@]}" \
              --shell ${pkgs.bash}/bin/sh \
              ${lib.concatMapStringsSep " " (r: "--replace-exec '" + r + "'") mirageArgs} \
              --allow-other
          '';
        in
        {
          options.sops.mirage = {
            enable = mkEnableOption "Enable the sops mirage service";

            files = mkOption {
              type = with types; listOf str;
              default = [ ];
              description = "List of files to overlay";
            };

            placeholder = mkOption {
              type = types.attrsOf (
                types.mkOptionType {
                  name = "coercibleToString";
                  description = "value that can be coerced to string";
                  check = lib.strings.isConvertibleWithToString;
                  merge = lib.mergeEqualOption;
                }
              );
              default = { };
              visible = false;
            };
          };

          config = mkIf config.sops.mirage.enable {
            systemd.services.mirage = {
              description = "Mirage Service with dynamic file detection";
              wantedBy = [ "sysinit.target" ];

              after = [
                "local-fs.target"
                "systemd-modules-load.service"
              ];
              before = [
                "multi-user.target"
                "basic.target"
              ];
              requires = [ "systemd-modules-load.service" ];

              serviceConfig = {
                ExecStart = "${mirageScript}";
                Restart = "on-failure";
                TimeoutStopSec = "10s";
              };
            };

            sops.mirage.placeholder = mapAttrs (
              name: _: mkDefault "<MIRAGE:${builtins.hashString "sha256" name}:MIRAGE_PLACEHOLDER>"
            ) config.sops.secrets;
          };
        };

      homeManagerModules.mirage =
        {
          config,
          lib,
          ...
        }:
        with lib;
        {
          options.sops.mirage = {
            placeholder = mkOption {
              type = types.attrsOf (
                types.mkOptionType {
                  name = "coercibleToString";
                  description = "value that can be coerced to string";
                  check = lib.strings.isConvertibleWithToString;
                  merge = lib.mergeEqualOption;
                }
              );
              default = { };
              visible = false;
            };
          };

          config = {
            sops.mirage.placeholder = mapAttrs (
              name: _: mkDefault "<MIRAGE:${builtins.hashString "sha256" name}:MIRAGE_PLACEHOLDER>"
            ) config.sops.secrets;
          };
        };
    };
}
