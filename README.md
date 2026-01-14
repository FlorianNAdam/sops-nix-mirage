# sops-nix-mirage

**sops-nix-mirage** is a NixOS and Home Manager module that extends [sops-nix](https://github.com/Mic92/sops-nix) by enabling **Mirage placeholders** in **any file in the Nix store**. It allows you to inject secrets from `sops-nix` into arbitrary files, dynamically replacing placeholders at runtime using a FUSE filesystem.  

This provides more flexibility than standard `sops-nix`, which only overlays configuration files: you can now inject secrets into **any build artifact or system file** managed by Nix.

---

## Features

- Extend `sops-nix` secrets to **any file in the Nix store**.
- Supports **system-wide and per-user secrets**.
- Optional caching for faster system startup.
- Integrated with **systemd** for automatic service management.

---

## Requirements

- NixOS (flake-enabled, unstable recommended)
- [sops-nix](https://github.com/Mic92/sops-nix)

---

## Installation

Add `sops-nix-mirage` to your NixOS configuration via flakes.

### NixOS System

1. Add the flake as an input in your `flake.nix`:

```nix
{
  inputs.sops-nix-mirage.url = "github:FlorianNAdam/sops-nix-mirage";
  inputs.sops-nix-mirage.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, sops-nix }: {
    # change `yourhostname` to your actual hostname
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      # customize to your system
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        inputs.sops-nix-mirage.nixosModules.mirage
      ];
    };
  };
}
```

## Usage

Suppose you have some secrets managed by `sops-nix`:

```nix
sops.secrets = {
  my_secret = {};
  some_ssh_key = {};
};
```

These values can now be injected into almost every nix configuration option:

```nix
environment.etc."my-app.conf".text = ''
  api_key = ${config.sops.mirage.placeholder.my_secret}
'';

pkgs.writeText "secret-file" ''
  password = ${config.sops.mirage.placeholder.db_password}
'';

environment.sessionVariables = {
  MIRAGE_SECRET = "This is secret: ${config.sops.mirage.placeholder.my_secret}";
};

systemd.services.my-app = with config.sops.mirage.placeholder; {
  description = "My ${my_secret} Service";
  wantedBy = [ "${my_secret}.target" ];
  serviceConfig = {
    Environment = "API_KEY=${my_secret}";
    ExecStart = "${pkgs.myApp}/${my_secret}/my-app";
  };
};

# Before authorizedKeysFiles was introduced:
users.users.florian = {
  openssh.authorizedKeys.keys = [
    "${config.sops.mirage.placeholder.some_ssh_key}"
  ];
};
```
