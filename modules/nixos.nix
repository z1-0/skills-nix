{ config, lib, pkgs, ... }:

let
  shared = import ./shared.nix { inherit lib pkgs; };
  opts = import ./options.nix { inherit lib; };
  cfg = config.skills;
  resolvedDir = cfg.dir;
  entries = shared.buildAllFileEntries cfg resolvedDir;

  hasTilde = lib.hasPrefix "~";
in

{
  inherit (opts) options;

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !hasTilde cfg.dir;
        message = ''
          skills.dir "${cfg.dir}" uses '~' which is not expanded on NixOS.
          Use an absolute path instead, e.g.: skills.dir = "/home/alice/.agents/skills"
        '';
      }
      {
        assertion = lib.all (t: !hasTilde t) cfg.symlink.targets;
        message = ''
          skills.symlink.targets contains '~' paths which are not expanded on NixOS.
          Use absolute paths instead, e.g.: skills.symlink.targets = [ "/home/alice/.cursor/skills" ];
        '';
      }
    ];

    system.activationScripts.skills.text = shared.mkActivationScript cfg entries resolvedDir;
  };
}
