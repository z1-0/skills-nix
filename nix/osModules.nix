{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.skills;

  inherit (import ./shared.nix { inherit lib pkgs; }) buildAllFileEntries;
  entries = buildAllFileEntries cfg.install cfg.depth cfg.dir;

  entryNames = lib.concatMapStringsSep " " (e: e.name) entries;
in

{
  imports = [ ./options.nix ];

  config =
    lib.mkIf cfg.enable {

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

      system.activationScripts.skills.text = ''
        mkdir -p '${cfg.dir}'
      ''
      + lib.concatStringsSep "\n" (
        map (e: ''
          mkdir -p "$(dirname '${e.name}')"
          ln -sfn '${e.storePath}' '${e.name}'
        '') entries
      )
      + lib.optionalString (entries != [ ]) ''
        if [ -d '${cfg.dir}' ]; then
          for entry in '${cfg.dir}'/*; do
            [ -L "$entry" ] || continue
            case " ${entryNames} " in
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
            ln -sfn '${cfg.dir}' '${target}'
          '') cfg.symlink.targets
        )
      );
    }
    // lib.mkIf (!cfg.enable) {
      system.activationScripts.skills-cleanup.text =
        lib.concatStringsSep "\n" (map (e: "rm -f '${e.name}'") entries)
        + ''
          rm -rf '${cfg.dir}'
        ''
        + lib.optionalString cfg.symlink.enable (
          lib.concatStringsSep "\n" (map (target: "rm -f '${target}'") cfg.symlink.targets)
        );
    };
}
