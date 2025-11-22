{ config, lib, pkgs, ... }:

let
  shared = import ./shared.nix { inherit lib pkgs; };
  opts = import ./options.nix { inherit lib; };
  cfg = config.skills;
  resolvedDir = cfg.dir;
  entries = shared.buildAllFileEntries cfg resolvedDir;
in
  
{
  inherit (opts) options;

  config = lib.mkIf cfg.enable {
    system.activationScripts.skills.text = shared.mkActivationScript cfg entries resolvedDir;
  };
}
