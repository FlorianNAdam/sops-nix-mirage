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
      inputs,
      nixpkgs,
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
          package = inputs.mirage.defaultPackage.${pkgs.system};

          rgCommand = "${pkgs.ripgrep}/bin/rg -L -l --no-messages --glob '!**/etc/nix/**' 'MIRAGE_PLACEHOLDER' /run/current-system";

          mirageArgs = mapAttrsToList (
            name: value: "${config.sops.mirage.placeholder.${name}}=cat ${value.path}"
          ) config.sops.secrets;

          mirageReplaceArgs = lib.concatMapStringsSep " " (r: "--replace-regex \"" + r + "\"") mirageArgs;

          mirageExec = lib.concatStringsSep " " [
            "${pkgs.bash}/bin/bash"
            "-c"
            "${rgCommand} | while read -r path; do ${package}/bin/mirage \"$path\" --shell ${pkgs.bash}/bin/sh ${mirageReplaceArgs} --allow-other; done"
          ];
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
                ExecStart = mirageExec;
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
