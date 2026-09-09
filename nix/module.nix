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

    # Match upstream's setgid entry points without granting the whole login
    # session access to the privileged helper. The GUI connects before dropping gid.
    security.wrappers = {
      Windscribe = {
        source = "${cfg.package}/bin/Windscribe";
        owner = "root";
        group = "windscribe";
        setgid = true;
      };
      windscribe-cli = {
        source = "${cfg.package}/bin/windscribe-cli";
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
