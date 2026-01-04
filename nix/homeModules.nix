{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.skills;
  shared = import ./shared.nix { inherit lib pkgs; };

  resolvePath =
    path:
    if lib.hasPrefix "~" path then "${config.home.homeDirectory}${lib.removePrefix "~" path}" else path;

  allFileEntries = lib.listToAttrs (
    map (
      e:
      lib.nameValuePair e.name {
        source = e.storePath;
        recursive = true;
      }
    ) (shared.buildAllFileEntries cfg.install cfg.depth (resolvePath cfg.dir))
  );

  symlinkTargets = map resolvePath cfg.symlink.targets;
  symlinkEntries =
    if !cfg.symlink.enable then
      { }
    else
      lib.genAttrs symlinkTargets (target: {
        source = config.lib.file.mkOutOfStoreSymlink (resolvePath cfg.dir);
      });
in

{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge [
      allFileEntries
      symlinkEntries
    ];
  };
}
