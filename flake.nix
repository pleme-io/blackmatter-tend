{
  description = "blackmatter-tend — home-manager module for tend daemon service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    substrate,
    devenv,
  }:
  let
    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"
    ];
  in {
    homeManagerModules.default = import ./module {
      hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" {lib = nixpkgs.lib;};
    };

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = devenv.lib.mkShell {
        inputs = { inherit nixpkgs devenv; };
        inherit pkgs;
        modules = [{
          languages.nix.enable = true;
          packages = with pkgs; [ nixpkgs-fmt nil ];
          git-hooks.hooks.nixpkgs-fmt.enable = true;
        }];
      };
    });
  };
}
