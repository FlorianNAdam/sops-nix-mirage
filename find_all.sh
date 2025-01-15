 #!/usr/bin/env bash

echo "nixos:"
sudo rg -L -l --no-messages --glob '!**/etc/nix/**' 'MIRAGE_PLACEHOLDER' /run/current-system

echo "home-manager:"
sudo rg -L -l --no-messages --hidden 'MIRAGE_PLACEHOLDER' ~/.local/state/nix/profiles/
