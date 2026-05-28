{
  description = "Blackmatter Tend — home-manager module for tend daemon (workspace repo sync + version watch)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, substrate, ... }:
    (import "${substrate}/lib/blackmatter-component-flake.nix") {
      inherit self nixpkgs;
      name = "blackmatter-tend";
      description = "home-manager service for tend daemon (workspace repo sync, version watch)";
      modules.homeManager = import ./module {
        hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
      };
      modules.nixos = ./nixos;
    };
}
