{
  description = "Declarative AI agent skills manager for NixOS/home-manager";

  outputs = { self, ... }: {
    homeModules.default = import ./module.nix;
  };
}
