# Add skills-nix to your flake.
{
  description = "Example home-manager configuration with skills-nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    skills-nix.url = "github:z1-0/skills-nix";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      skills-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations."user" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        modules = [
          skills-nix.homeModules.default

          # Your configuration
          {
            skills = {
              enable = true;

              install = [
                "vercel-labs/agent-skills"
                "mattpocock/skills@grill-me"
                "mattpocock/skills/some-subtree"
              ];

              dir = "~/.agents/skills";
              depth = 2;
              symlink = {
                enable = true;
                targets = [
                  "~/.claude/skills"
                  "~/.cursor/skills"
                ];
              };
            };

            # Your other home-manager config...
            home.username = "user";
            home.homeDirectory = "/home/user";
          }
        ];
      };
    };
}
