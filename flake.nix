{
  outputs = _: {
    homeModules.default = import ./nix/homeModules.nix;
    nixosModules.default = import ./nix/osModules.nix;
    darwinModules.default = import ./nix/osModules.nix;
  };
}
