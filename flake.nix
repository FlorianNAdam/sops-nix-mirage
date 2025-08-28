{
  description = "Mirage FUSE filesystem with configurable file content";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    mirage = {
      url = "github:FlorianNAdam/mirage";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
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
          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          fileFinderScript = pkgs.writeShellScript "mirage-file-finder" ''
            src="${./.}"
            cut_src="/nix/store/$(echo $src | cut -c45-)"

            gen_root="$1"

            if [ -z "$gen_root" ]; then
                echo "usage: $0 gen_root"
                exit 1
            fi

            if [ ! -d "$gen_root" ]; then
                echo "error: '$gen_root' is not a valid directory."
                exit 1
            fi

            gen_root="''${gen_root%/}/"
             
            echo "searching for files containing a mirage placeholder..." >&2

            nix_store="$gen_root"sw/bin/nix-store

            # Find all requisites of gen_root
            store_paths=$($nix_store --query --requisites "$gen_root" | xargs readlink -f | grep -vE '^/nix/store/.*-source' | sort -u)

            # Find files
            resolved_files=$(
              printf '%s\0' $store_paths \
              | xargs -0 -n 200 /nix/store/1ijacjhy42pqx7vfi5mnsqrps2k3b8xf-ripgrep-14.1.1/bin/rg \
                  "MIRAGE_PLACEHOLDER" -l --hidden --no-messages -g '!*.nix' -g '!*-source/**/*' \
              | xargs readlink -f | sort -u
            )

            # Filter out mirage source files and mirage scripts
            filtered_files=$(echo "$resolved_files" | grep -vE '(^/nix/store/.*-mirage-reload$|^/nix/store/.*-mirage-file-finder$|\.nix$|^'"$0"'$|^'"$src"'|^'"$cut_src"')')

            echo "$filtered_files"
          '';

          mirageReloadScript = pkgs.writeShellScript "mirage-reload" ''
            ensure_file() {
                local file="$1"
                if [ ! -e "$file" ] || [ "$(stat -c %U "$file")" != "root" ] || [ "$(stat -c %a "$file")" != "600" ]; then
                    mkdir -p "$(dirname "$file")"
                    : > "$file"
                    chmod 600 "$file"
                fi
            }

            gen_root="$1"

            if [ -z "$gen_root" ]; then
                echo "usage: $0 gen_root"
                exit 1
            fi

            if [ ! -d "$gen_root" ]; then
                echo "error: '$gen_root' is not a valid directory."
                exit 1
            fi

            gen_root="''${gen_root%/}/"


            file_list="/var/lib/mirage/files"
            replace_list="/var/lib/mirage/secrets"

            # Remove file on boot
            if [[ ! -e "/run/current-system" ]]; then
              rm -f "$file_list"
              rm -f "$replace_list"
            fi

            # Ensure the file exists
            ensure_file "$file_list"
            ensure_file "$replace_list"

            # Step 1: Read existing files from /var/lib/mirage/files
            files=()
            while IFS= read -r line; do
              files+=("$line")
            done < "$file_list"

            # Step 2: Read new files from the fileFinderScript
            while IFS= read -r line; do
              files+=("$line")
            done < <(${fileFinderScript} $gen_root)

            # Step 3: Add manually specified files
            ${concatStringsSep "\n" (map (file: "files+=(\"${file}\")") config.sops.mirage.files)}

            # Step 4: Sort and remove duplicates
            sorted_unique_files=($(printf "%s\n" "''${files[@]}" | ${pkgs.util-linux}/bin/rev | sort -u | ${pkgs.util-linux}/bin/rev))

            # Step 5: Write back the sorted, unique list
            printf "%s\n" "''${sorted_unique_files[@]}" > "$file_list"

            # Step 6: Write the replace strings
            printf "${lib.concatStringsSep "\n" mirageArgs}" > "$replace_list"
          '';

          mirageBinary = "${mirage.defaultPackage.${pkgs.system}}/bin/mirage";

          mirageScript = pkgs.writeShellScript "mirage-dynamic-service" ''
            ${mirageBinary} --shell ${pkgs.bash}/bin/sh --watch-file /var/lib/mirage/files --replace-exec-file /var/lib/mirage/secrets --allow-other
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
            environment.systemPackages = [
              (pkgs.writeShellScriptBin "mirage-file-finder" ''"${fileFinderScript}" "$@"'')
              (pkgs.writeShellScriptBin "mirage-reload" ''"${mirageReloadScript}" "$@"'')
            ];

            system.activationScripts.myScript = ''
              echo "setting up /var/lib/mirage/files..."
              ${mirageReloadScript} /nix/var/nix/profiles/system
            '';

            systemd.services.mirage = {
              description = "Mirage Service with dynamic file detection";
              wantedBy = [
                "sysinit.target"
              ];

              after = [
                "local-fs.target"
                "systemd-modules-load.service"
              ];
              before = [
                "multi-user.target"
              ];
              requires = [ "systemd-modules-load.service" ];

              serviceConfig = {
                ExecStart = "${mirageScript}";
                Restart = "on-failure";
                TimeoutStopSec = "10s";
              };
            };

            systemd.services."mirage-reload" = {
              description = "Reload mirage upon rebuild";
              after = [
                "local-fs.target"
                "systemd-modules-load.service"
              ];
              wantedBy = [
                "sysinit-reactivation.target"
              ];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${mirageReloadScript} /run/current-system";
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
