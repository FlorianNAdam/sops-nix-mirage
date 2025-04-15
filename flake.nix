{
  description = "Convenience wrapper for arion";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      arion,
      ...
    }:
    {
      nixosModules.nirion =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          arionProjects = config.virtualisation.arion.projects;
          projectMapping = lib.concatStringsSep "\n" (
            builtins.attrValues (
              lib.attrsets.mapAttrs' (name: project: {
                inherit name;
                value = "${name}=${project.settings.out.dockerComposeYaml}";
              }) arionProjects
            )
          );
          nirionScript = pkgs.writeScriptBin "nirion" ''
            #!/usr/bin/env bash
            set -e

            # Project to YAML mapping
            declare -A PROJECTS
            while IFS='=' read -r name yaml; do
              PROJECTS["$name"]="$yaml"
            done <<< "${projectMapping}"

            # Handle 'list' command
            if [[ "$1" == "list" ]]; then
              echo "Available Arion projects:"
              for proj in "''${!PROJECTS[@]}"; do
                echo "  - $proj"
              done
              exit 0
            fi

            # Ensure at least one argument is provided
            if [[ $# -lt 1 ]]; then
              echo "Usage: nirion <command> [options] [project]"
              echo "       nirion list  # Show available projects"
              exit 1
            fi

            # Extract the last argument as project name (if provided)
            LAST_ARG="''${!#}"

            # Check if the last argument is a valid project name
            if [[ -n "''${PROJECTS[$LAST_ARG]}" ]]; then
              PROJECTS_TO_RUN=("$LAST_ARG")  # Single project mode
              ARION_COMMAND="''${@:1:$#-1}"  # All args except the last one
            else
              PROJECTS_TO_RUN=("''${!PROJECTS[@]}")  # Run for all projects
              ARION_COMMAND="$@"  # Full command
            fi

            # Execute Arion for all selected projects
            for PROJECT in "''${PROJECTS_TO_RUN[@]}"; do
              echo "Arion project: $PROJECT"
              ${pkgs.expect}/bin/unbuffer arion --prebuilt-file "''${PROJECTS[$PROJECT]}" $ARION_COMMAND | grep -v "the attribute \`version\` is obsolete"
              echo
            done
          '';
        in
        {
          options = {
            nirion = {
              lockFile = lib.mkOption {
                type = lib.types.path;
                description = "Path to image digest lock file";
              };

              images = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                description = "Image references to be resolved with digests";
              };

              locked-images = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                readOnly = true;
                internal = true;
                description = "Resolved image references with digests";
              };
            };
          };

          config = {
            nirion.locked-images =
              let
                lockFile = lib.importJSON (config.nirion.lockFile);
              in
              lib.mapAttrs (
                name: imageRef:
                let
                  hasDigest = builtins.match ".*@sha256:.*" imageRef != null;
                in
                if hasDigest then
                  imageRef
                else
                  let
                    digest = lockFile.${imageRef} or null;
                  in
                  if digest != null then
                    "${imageRef}@${digest}"
                  else
                    lib.warn "nirion: Image '${imageRef}' not locked - using mutable tag" imageRef
              ) config.nirion.images;

            environment.systemPackages = [
              nirionScript
            ];
          };
        };
    };
}
