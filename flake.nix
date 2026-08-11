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
        systemdUnit = pkgs.runCommand "nws-systemd-unit" { } ''
          mkdir -p $out/share/systemd/user
          cat > $out/share/systemd/user/nws.service <<'EOF'
          [Unit]
          Description=Nix Workspace daemon
          [Service]
          Type=simple
          ExecStart=%h/.nix-profile/bin/nws service
          Restart=on-failure
          [Install]
          WantedBy=default.target
          EOF
        '';

        main = pkgs.stdenv.mkDerivation {
          name = "main";
          src = ./.;
          buildInputs = [ pkgs.odin ];
          installPhase = ''
            mkdir -p $out/bin
            mkdir -p $out/share/systemd/user
            mkdir -p build
            odin build src/nix_workspace.odin -file -collection:nwscore=src -out:build/nws
            cp build/nws $out/bin/
            cp ${systemdUnit}/share/systemd/user/nws.service $out/share/systemd/user/nws.service
          '';
        };

        default = main;
      };

      devShells.${system}.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [
          ({ pkgs, config, ... }: {
            packages = [ self.packages.${system}.main ];

            processes.nws.exec = "exec ${self.packages.${system}.main}/bin/nws service";

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
