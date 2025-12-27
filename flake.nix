{
  outputs = _: {
    homeModules.default = import ./modules/home.nix;
    nixosModules.default = import ./modules/osModules.nix;
    darwinModules.default = import ./modules/osModules.nix;
  };
}
