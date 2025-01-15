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
            #!/usr/bin/env bash

            ${rgCommand} | while read -r path; do
              ${mirage.defaultPackage.${pkgs.system}}/bin/mirage "$path" \
                --shell ${pkgs.bash}/bin/sh \
                ${lib.concatMapStringsSep " " (r: "--replace-exec '" + r + "'") mirageArgs} \
                --allow-other
            done
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
              serviceConfig = {
                ExecStart = "${mirageScript}";
                Restart = "always";
              };
            };

            environment.sessionVariables = {
              SOPS_MIRAGE_ARGS = mirageArgs;
            };

            sops.mirage.placeholder = mapAttrs (
              name: _: mkDefault "<MIRAGE:${builtins.hashString "sha256" name}:MIRAGE_PLACEHOLDER>"
            ) config.sops.secrets;
          };
        };
    };
}
