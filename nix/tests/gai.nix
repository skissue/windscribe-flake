{
  pkgs,
  windscribe,
}: let
  client = pkgs.stdenv.mkDerivation {
    name = "windscribe-gai-test-client";
    dontUnpack = true;
    buildInputs = [pkgs.boost188 pkgs.spdlog];
    buildPhase = ''
      $CXX -std=c++17 -pthread ${./gai-client.cpp} \
        -I${../../src/helper/common} -I${../../src/client/client-common} \
        -lboost_serialization -lspdlog -lfmt -o gai-client
    '';
    installPhase = "install -Dm755 gai-client $out/bin/gai-client";
  };
in
  pkgs.testers.runNixOSTest {
    name = "windscribe-gai";
    nodes.machine = {
      imports = ["${pkgs.path}/nixos/tests/common/x11.nix"];
      test-support.displayManager.auto.user = "alice";
      users.groups.windscribe = {};
      users.users.windscribe = {
        isSystemUser = true;
        group = "windscribe";
      };
      # VM-only access policy; not a decision about production GUI privileges.
      users.users.alice = {
        isNormalUser = true;
        extraGroups = ["windscribe"];
      };
      environment.systemPackages = [windscribe client];
      environment.etc."gai.conf".text = "# Nix-managed baseline\n";
      systemd.services.windscribe-helper = {
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils gnugrep gnused iproute2 kmod procps systemd];
        serviceConfig = {
          ExecStart = "${windscribe}/libexec/windscribe/helper";
          LogsDirectory = "windscribe";
          StateDirectory = "windscribe";
          RuntimeDirectory = "windscribe";
        };
      };
      virtualisation.memorySize = 2048;
    };
    testScript = ''
      import datetime

      start_all()
      machine.wait_for_unit("windscribe-helper.service")
      machine.wait_until_succeeds("test -S /run/windscribe/helper.sock")
      client = "runuser -u alice -- ${client}/bin/gai-client"
      script = "${windscribe}/libexec/windscribe/scripts/gai-ipv4-priority"

      with subtest("packaging and socket permissions"):
          machine.succeed(f"test -x {script} && ${pkgs.bash}/bin/bash -n {script}")
          assert machine.succeed(f"head -1 {script}").startswith("#!/nix/store/")
          machine.succeed("test ! -e /opt/windscribe")
          denied = machine.fail("runuser -u nobody -- ${client}/bin/gai-client up 2>&1")
          assert "Permission denied" in denied

      with subtest("writable gai.conf round trip through helper IPC"):
          machine.succeed("cp /etc/gai.conf /tmp/gai-original && rm /etc/gai.conf && cp /tmp/gai-original /etc/gai.conf")
          machine.succeed(f"{client} up")
          machine.succeed("grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf")
          machine.succeed(f"{client} up")
          assert machine.succeed("grep -c '^precedence ' /etc/gai.conf").strip() == "1"
          machine.succeed(f"{client} down")
          machine.succeed("cmp /etc/gai.conf /tmp/gai-original")
          machine.succeed(f"{client} down")
          machine.succeed("cmp /etc/gai.conf /tmp/gai-original")

      with subtest("missing gai.conf round trip"):
          machine.succeed("rm /etc/gai.conf")
          machine.succeed(f"{client} up")
          machine.succeed("test -f /etc/gai.conf")
          machine.succeed(f"{client} down")
          machine.succeed("test ! -e /etc/gai.conf")

      with subtest("Nix-managed gai.conf is an explicitly unsupported case"):
          machine.succeed("ln -s /etc/static/gai.conf /etc/gai.conf")
          machine.succeed(f"{client} up")
          # The IPC response does not report script failure: inspect the actual file.
          machine.succeed("test -L /etc/gai.conf && cmp /etc/gai.conf /tmp/gai-original")
          machine.succeed(f"{client} down")
          machine.succeed("test -L /etc/gai.conf && cmp /etc/gai.conf /tmp/gai-original")

      with subtest("GUI connects to this VM's helper"):
          machine.wait_for_x()
          machine.wait_for_file("/home/alice/.Xauthority")
          machine.succeed("xauth merge /home/alice/.Xauthority")
          machine.succeed("su - alice -c 'DISPLAY=:0 QT_FORCE_STDERR_LOGGING=1 ${windscribe}/bin/Windscribe > /tmp/windscribe-gui.log 2>&1 &'")
          machine.wait_until_succeeds("grep -q 'connected to helper socket' /tmp/windscribe-gui.log", timeout=datetime.timedelta(seconds=60))
          machine.wait_for_window("Windscribe", timeout=datetime.timedelta(seconds=60))
          machine.screenshot("windscribe-startup")
          machine.succeed("systemctl is-active windscribe-helper.service")
          machine.succeed("pgrep -u alice -f '^${windscribe}/bin/Windscribe$'")
          machine.copy_from_machine("/tmp/windscribe-gui.log")
          machine.copy_from_machine("/var/log/windscribe/helper.log")
    '';
  }
