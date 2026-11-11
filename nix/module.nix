{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.windscribe;
in {
  options.services.windscribe = {
    enable = lib.mkEnableOption "Windscribe VPN";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Windscribe desktop package. Defaults to this flake's package when using its NixOS module.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    users.groups.windscribe = {};
    users.users.windscribe = {
      isSystemUser = true;
      group = "windscribe";
    };

    # Only the GUI needs helper access; the CLI launches it through systemd --user.
    # Keep the CLI unprivileged so it can use the session bus. The GUI connects
    # before dropping gid, without granting the whole login session helper access.
    security.wrappers = {
      Windscribe = {
        source = "${cfg.package}/bin/Windscribe";
        owner = "root";
        group = "windscribe";
        setgid = true;
      };
    };

    systemd.services.windscribe-helper = {
      description = "Windscribe helper service";
      before = ["network-pre.target"];
      wants = ["network-pre.target"];
      wantedBy = ["multi-user.target"];
      path = with pkgs; [
        coreutils
        gnugrep
        gnused
        gawk
        iproute2
        kmod
        procps
        systemd
        util-linux
        e2fsprogs
        openresolv
        ethtool
        networkmanager
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/libexec/windscribe/helper";
        RuntimeDirectory = "windscribe";
        StateDirectory = "windscribe";
        LogsDirectory = "windscribe";
      };
    };
  };
}
