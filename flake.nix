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
          rgCommand = "${pkgs.ripgrep}/bin/rg -L -l --no-messages --glob '!**/etc/nix/**' 'MIRAGE_PLACEHOLDER'";
          rgCommand2 = "${pkgs.ripgrep}/bin/rg -L -l --hidden --no-messages 'MIRAGE_PLACEHOLDER'";

          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          fileFinderScript = pkgs.writeShellScript "mirage-file-finder" ''
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

            files=()

            # Find NixOS files
            while read -r path; do
              resolved_path=$(readlink -f "$path")
              echo "found file: $resolved_path" >&2
              files+=("$resolved_path")

              # Find matching file in /etc
              gen_etc="$gen_root"etc/                          
              if [[ "$path" == "$gen_etc"* ]]; then
              
                etc_path="/etc/''${path#$gen_etc}"
                if [ -f "$etc_path" ]; then

                  # Ignore symlinks from /etc to /nix/store
                  resolved_etc_path=$(readlink -f "$etc_path")
                  if [[ "$resolved_etc_path" != /nix/store/* ]]; then
                    echo "found matching file in /etc: $resolved_etc_path" >&2
                    files+=("$resolved_etc_path")
                  fi
                fi
              fi

            done < <(${rgCommand} $gen_root)

            # Find Home Manager files
            nix_store="$gen_root"sw/bin/nix-store
            gen_paths=$($nix_store -qR $gen_root | grep home-manager-generation || true)

            for gen_path in $gen_paths; do
              echo "found Home Manager generation: $gen_path" >&2
              while read -r path; do
                  resolved_path=$(readlink -f "$path")
                  echo "found file: $resolved_path" >&2
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

          mirageReloadScript = pkgs.writeShellScript "mirage-reload" ''
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

            # Remove file on boot
            if [[ ! -e "/run/current-system" ]]; then
              rm -f "$file_list"
            fi

            # Ensure the file exists
            mkdir -p "$(dirname "$file_list")"
            touch "$file_list"

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

          '';

          mirageReplaceString = "${lib.concatMapStringsSep " " (r: "--replace-exec '" + r + "'") mirageArgs}";

          mirageBinary = "${mirage.defaultPackage.${pkgs.system}}/bin/mirage";

          mirageScript = pkgs.writeShellScript "mirage-dynamic-service" ''
            ${mirageBinary} --watch-file /var/lib/mirage/files --shell ${pkgs.bash}/bin/sh ${mirageReplaceString} --allow-other
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

            systemd.paths."mirage-reload" = {
              description = "Watch for NixOS system changes";
              wantedBy = [ "multi-user.target" ];
              pathConfig = {
                PathExistsGlob = "/run/current-system/*";
              };
            };

            systemd.services."mirage-reload" = {
              description = "Reload mirage, when /run/current-system changes";
              requires = [ "mirage-reload.path" ];
              after = [ "mirage-reload.path" ];
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
