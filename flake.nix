{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = { self, nixpkgs, devenv, ... } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = rec {
        main = pkgs.stdenv.mkDerivation {
          name = "main";
          src = ./.;
          buildInputs = [ pkgs.odin ];
          installPhase = ''
            mkdir -p $out/bin
            mkdir -p build
            odin build src/nix_workspace.odin -file -collection:nwscore=src -out:build/nws
            cp build/nws $out/bin/
          '';
        };

        default = main;
      };

      devShells.${system}.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [
          ({ pkgs, config, ... }: {
            languages.odin.enable = true;

            git-hooks.hooks.odin-fmt = {
              enable = true;
              name = "Odin Formatter";
              entry = "bash -c 'for file in \"$@\"; do tmp=$(mktemp) && ${pkgs.ols}/bin/odinfmt -stdin < \"$file\" > \"$tmp\" && [ -s \"$tmp\" ] && mv \"$tmp\" \"$file\" || rm -f \"$tmp\"; done' --";
              files = "\\.odin$";
            };

            enterTest = ''
              odin test tests -collection:nwscore=src
            '';

            enterShell = ''
              echo "Development shell for nix-workspace (nws)"
            '';  
          })
        ];
      };
    };
}
