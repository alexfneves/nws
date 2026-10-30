# Home Manager module for nws (the Nix Workspace root manager).
#
# Exposed from flake.nix as `homeManagerModules.default`. Consumer usage:
#
#   imports = [ inputs.nws.homeManagerModules.default ];
#   services.nws.enable = true;
#
# Installs nws into the user's profile and runs `nws service` as a systemd user
# unit. The daemon writes its state under ~/.config/nws and serves its control
# socket at $XDG_RUNTIME_DIR/nws/control.sock.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nws;
in
{
  options.services.nws = {
    enable = lib.mkEnableOption "the nws workspace daemon (`nws service`)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "nws.packages.\${system}.default";
      description = "The nws package to install and run.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Puts bin/nws on PATH. The package also ships bash/zsh/fish completions
    # under share/, which the profile exposes to the shell.
    home.packages = [ cfg.package ];

    # ExecStart uses the store path directly, so the unit does not depend on
    # ~/.nix-profile existing (the upstream unit assumes it does).
    # RuntimeDirectory creates $XDG_RUNTIME_DIR/nws (mode 0700) for the
    # control socket and removes it when the service stops.
    systemd.user.services.nws = {
      Unit.Description = "Nix Workspace daemon";
      Service = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/nws service";
        Restart = "on-failure";
        RuntimeDirectory = "nws";
        RuntimeDirectoryMode = "0700";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
