{
  outputs = _: { homeModules.default = import ./nix/homeModules.nix; };
}
