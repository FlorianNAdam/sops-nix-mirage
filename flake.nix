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
          rgCommand = "${pkgs.ripgrep}/bin/rg -L -l --no-messages --glob '!**/etc/nix/**' 'MIRAGE_PLACEHOLDER' /run/current-system";

          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          mirageScript = pkgs.writeShellScript "mirage-dynamic-service" ''

            echo "Searching for files containing a mirage placeholder..."

            files=()
            while read -r path; do
              resolved_path=$(readlink -f "$path")
              echo "Found file: $resolved_path"
              files+=("$resolved_path")
            done < <(${rgCommand})

            if [ ''${#files[@]} -eq 0 ]; then
              echo "No files found. Sleeping forever..."
              sleep infinity
            fi

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
            systemd.services.mirage = {
              description = "Mirage Service with dynamic file detection";
              wantedBy = [ "multi-user.target" ];

              bindsTo = [ "sysinit-reactivation.target" ];
              partOf = [ "sysinit-reactivation.target" ];

              serviceConfig = {
                ExecStart = "${mirageScript}";
                Restart = "always";
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
          pkgs,
          lib,
          ...
        }:
        with lib;
        let
          rgCommand = "${pkgs.ripgrep}/bin/rg -L -l --hidden --no-messages 'MIRAGE_PLACEHOLDER' ~/.local/state/nix/profiles/";

          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          mirageScript = pkgs.writeShellScript "mirage-dynamic-service" ''

            echo "Searching for files containing a mirage placeholder..."

            files=()
            while read -r path; do
              resolved_path=$(readlink -f "$path")
              echo "Found file: $resolved_path"
              files+=("$resolved_path")
            done < <(${rgCommand})

            if [ ''${#files[@]} -eq 0 ]; then
              echo "No files found. Sleeping forever..."
              sleep infinity
            fi

            declare -A seen
            unique_files=()

            for file in "''${files[@]}"; do
              if [[ -z "''${seen[$file]}" ]]; then
                unique_files+=("$file")
                seen["$file"]=1
              fi
            done

            files=("''${unique_files[@]}")

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
            systemd.user.services.mirage = {
              Unit = {
                Description = "Mirage Service with dynamic file detection";
              };

              Install = {
                WantedBy = [ "default.target" ];
              };

              Service = {
                ExecStart = "${mirageScript}";
                Restart = "always";
              };
            };

            sops.mirage.placeholder = mapAttrs (
              name: _: mkDefault "<MIRAGE:${builtins.hashString "sha256" name}:MIRAGE_PLACEHOLDER>"
            ) config.sops.secrets;
          };
        };
    };
}
