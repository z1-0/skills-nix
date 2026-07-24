{ config, lib, pkgs, ... }:

let
  shared = import ./shared.nix { inherit lib pkgs; };
  opts = import ./options.nix { inherit lib; };
  cfg = config.skills;
  homeDir = config.home.homeDirectory;
  resolvedDir = shared.resolvePath cfg.dir homeDir;

  allFileEntries = lib.listToAttrs (
    map (
      e:
      lib.nameValuePair e.name {
        source = e.storePath;
        recursive = true;
      }
    ) (shared.buildAllFileEntries cfg resolvedDir)
  );

  symlinkTargets = map shared.resolvePath cfg.symlink.targets;
  symlinkEntries =
    if !cfg.symlink.enable then
      { }
    else
      lib.genAttrs symlinkTargets (target: {
        source = config.lib.file.mkOutOfStoreSymlink resolvedDir;
      });
in

{
  inherit (opts) options;

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      allFileEntries
      symlinkEntries
    ];
  };
}
