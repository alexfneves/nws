# NixOS module for nws (the Nix Workspace root manager).
#
# Exposed from flake.nix as `nixosModules.default`. Consumer usage:
#
#   imports = [ inputs.nws.nixosModules.default ];
#   services.nws.enable = true;
#
# nws is a per-user daemon: it watches the workspaces of the user who runs it,
# keeps its state under ~/.config/nws and serves its control socket at
# $XDG_RUNTIME_DIR/nws/control.sock. So this runs it as a systemd *user* unit
# for every user session, not as a system service.
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
    environment.systemPackages = [ cfg.package ];

    # ExecStart uses the store path directly, so the unit does not depend on
    # the user's profile layout (the upstream unit assumes ~/.nix-profile).
    # RuntimeDirectory creates $XDG_RUNTIME_DIR/nws (mode 0700) for the
    # control socket and removes it when the service stops.
    systemd.user.services.nws = {
      description = "Nix Workspace daemon";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/nws service";
        Restart = "on-failure";
        RuntimeDirectory = "nws";
        RuntimeDirectoryMode = "0700";
      };
    };
  };
}
