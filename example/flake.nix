# Example flake.nix for end users
#
# This shows how to use skills-nix in your home-manager configuration.

{
  description = "Example home-manager configuration with skills-nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Add skills-nix as a flake input
    skills-nix.url = "github:z1-0/skills-nix";
  };

  outputs = { nixpkgs, home-manager, skills-nix, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeConfigurations."user" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;

        modules = [
          # Import the skills-nix module
          skills-nix.homeModules.default

          # Your configuration
          {
            # Enable and configure skills
            skills = {
              enable = true;

              install = [
                # Install all skills from a repo
                "vercel-labs/agent-skills"

                # Install a specific skill
                "mattpocock/skills/grill-me"
              ];

              # Installation directory
              dir = "~/.agents/skills";

              # Search depth for discovery
              depth = 2;

              # Symlink to agent directories
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
