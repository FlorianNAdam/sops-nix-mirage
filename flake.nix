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
          imageNameRefs = lib.concatStringsSep "\n" (
            lib.attrsets.mapAttrsToList (name: ref: "${name}=${ref}") config.nirion.images
          );
          lockFileOutputStr =
            if config.nirion.lockFileOutput != null then toString config.nirion.lockFileOutput else "";
          nirionScript = pkgs.writeScriptBin "nirion" ''
            #!/usr/bin/env bash
            set -e

            # Project to YAML mapping
            declare -A PROJECTS
            while IFS='=' read -r name yaml; do
              PROJECTS["$name"]="$yaml"
            done <<< "${projectMapping}"

            # Handle 'update' command
            if [[ "$1" == "update" ]]; then
              shift  # Remove 'update' from arguments

              # Check if lockfile is enabled
              if [[ -z "${lockFileOutputStr}" ]]; then
                echo "Error: Lockfile functionality is not enabled (nirion.lockFileOutput is not set)"
                exit 1
              fi

              # Read image name->ref mapping
              declare -A IMAGE_MAP
              while IFS='=' read -r name ref; do
                IMAGE_MAP["$name"]="$ref"
              done <<< "${imageNameRefs}"

              # Determine images to update
              if [[ $# -gt 0 ]]; then
                # Validate provided image names
                IMAGES_TO_UPDATE=()
                for name in "$@"; do
                  if [[ -z "''${IMAGE_MAP[$name]}" ]]; then
                    echo "Error: Unknown image name '$name'. Available images:"
                    printf "  - %s\n" "''${!IMAGE_MAP[@]}"
                    exit 1
                  fi
                  IMAGES_TO_UPDATE+=("$name")
                done
              else
                # Update all images
                IMAGES_TO_UPDATE=("''${!IMAGE_MAP[@]}")
              fi

              LOCKFILE="${lockFileOutputStr}"

              # Read existing lockfile
              declare -A LOCKED
              if [[ -f "$LOCKFILE" ]]; then
                while IFS="=" read -r key digest; do
                  LOCKED["$key"]="$digest"
                done < <(${pkgs.jq}/bin/jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' "$LOCKFILE")
              fi

              # Update each selected image
              for NAME in "''${IMAGES_TO_UPDATE[@]}"; do
                IMAGE="''${IMAGE_MAP[$NAME]}"
                echo "Resolving digest for $NAME ($IMAGE)"
                DIGEST=$(${pkgs.skopeo}/bin/skopeo inspect --format "{{.Digest}}" "docker://$IMAGE" || echo "failed")
                if [[ "$DIGEST" == "failed" ]]; then
                  echo "Error resolving digest for $IMAGE. Skipping."
                  continue
                fi
                OLD_DIGEST="''${LOCKED[$NAME]-}"
                if [[ -n "$OLD_DIGEST" ]]; then
                  if [[ "$OLD_DIGEST" != "$DIGEST" ]]; then
                    echo "Digest changed for $NAME: $OLD_DIGEST -> $DIGEST"
                  fi
                else
                  echo "Added digest for $NAME: $DIGEST"
                fi
                LOCKED["$NAME"]="$DIGEST"
              done

              # Write new lockfile
              echo "Updating lockfile $LOCKFILE"
              rm -f "$LOCKFILE.tmp"
              for key in "''${!LOCKED[@]}"; do
                echo "$key ''${LOCKED[$key]}" >> "$LOCKFILE.tmp"
              done
              ${pkgs.jq}/bin/jq -Rn 'reduce inputs as $line ({}; ($line | split(" ") ) as $parts | . + { ($parts[0]): $parts[1] })' "$LOCKFILE.tmp" > "$LOCKFILE"
              rm -f "$LOCKFILE.tmp"

              exit 0
            fi

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
              echo "       nirion list          # Show available projects"
              echo "       nirion update [image...]  # Update lockfile for specified/all images"
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
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Optional path to image digest lock file";
              };
              lockFileOutput = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional writable output path for lockfile updates";
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
                lockFile = if config.nirion.lockFile != null then lib.importJSON config.nirion.lockFile else { };
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
                    digest = lockFile.${name} or null;
                  in
                  if digest != null then
                    "${imageRef}@${digest}"
                  else
                    lib.warn "nirion: Image '${name}' (${imageRef}) not locked - using mutable tag" imageRef
              ) config.nirion.images;

            environment.systemPackages = [ nirionScript ];
          };
        };
    };
}
