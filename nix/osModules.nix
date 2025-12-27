{
  config,
  lib,
  pkgs,
  ...
}:

let
  shared = import ./shared.nix { inherit lib pkgs; };
  cfg = config.skills;

  entries = shared.buildAllFileEntries cfg.install cfg.depth cfg.dir;
in

{
  options = import ./options.nix { inherit lib; };

  config = lib.mkIf cfg.enable {
    assertions = shared.mkTildeAssertions cfg;

    system.activationScripts.skills.text =
      shared.mkActivationScript cfg.symlink.enable cfg.symlink.targets entries
        cfg.dir;
  };
}
