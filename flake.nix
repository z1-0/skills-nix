{
  description = "Declarative AI agent skills manager for NixOS/home-manager/nix-darwin";

  outputs = { self, ... }: {
    homeModules.default = import ./modules/home.nix;
    nixosModules.default = import ./modules/nixos.nix;
    darwinModules.default = import ./modules/darwin.nix;
  };
}
