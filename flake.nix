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
          mirage-args = concatStringsSep " " (
            mapAttrs (name: _: "--replace-exec ${name}") config.sops.secrets
          );
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

          config = lib.mkIf config.sops.mirage.enable {

            nvironment.sessionVariables = {
              SOPS_MIRAGE_ARGS = mirage-args;
            };

            sops.mirage.placeholder = mapAttrs (
              name: _: mkDefault "<MIRAGE:${builtins.hashString "sha256" name}:MIRAGE_PLACEHOLDER>"
            ) config.sops.secrets;
          };
        };
    };
}
