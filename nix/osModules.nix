{
  config,
  lib,
  pkgs,
  ...
}:

let
  shared = import ./shared.nix { inherit lib pkgs; };
  entries = shared.buildAllFileEntries cfg.install cfg.depth cfg.dir;

  cfg = config.skills;
in

{
  options = import ./options.nix { inherit lib; };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.hasPrefix "~" cfg.dir;
        message = ''
          skills.dir "${cfg.dir}" uses '~' which is not expanded here.
          Use an absolute path instead.
        '';
      }
      {
        assertion = lib.all (t: !lib.hasPrefix "~" t) cfg.symlink.targets;
        message = ''
          skills.symlink.targets contains '~' paths which are not expanded here.
          Use absolute paths instead.
        '';
      }
    ];

    system.activationScripts.skills.text =
      let
        resolvedDir = cfg.dir;
      in
      ''
        mkdir -p '${resolvedDir}'
      ''
      + lib.concatStringsSep "\n" (
        map (e: ''
          mkdir -p "$(dirname '${e.name}')"
          ln -sfn '${e.storePath}' '${e.name}'
        '') entries
      )
      + lib.optionalString (entries != [ ]) ''
        if [ -d '${resolvedDir}' ]; then
          for entry in '${resolvedDir}'/*; do
            [ -L "$entry" ] || continue
            case " ${lib.concatStringsSep " " (map (e: e.name) entries)} " in
              *" $entry "* ) ;;
              * ) rm -f "$entry" ;;
            esac
          done
        fi
      ''
      + lib.optionalString cfg.symlink.enable (
        lib.concatStringsSep "\n" (
          map (target: ''
            mkdir -p "$(dirname '${target}')"
            ln -sfn '${resolvedDir}' '${target}'
          '') cfg.symlink.targets
        )
      );
  };
}
