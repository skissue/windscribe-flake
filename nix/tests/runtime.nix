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
    name = "windscribe-runtime";
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
      services.resolved = {
        enable = true;
        settings.Resolve = {
          DNS = "192.0.2.53";
          Domains = "baseline.invalid";
          FallbackDNS = "192.0.2.54";
        };
      };
      systemd.services.windscribe-helper = {
        wantedBy = ["multi-user.target"];
        path = with pkgs; [coreutils gnugrep gnused iproute2 kmod procps systemd util-linux e2fsprogs openresolv];
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
      import json
      import shlex

      start_all()
      machine.wait_for_unit("windscribe-helper.service")
      machine.wait_until_succeeds("test -S /run/windscribe/helper.sock")
      client = "runuser -u alice -- ${client}/bin/gai-client"
      scripts = "${windscribe}/libexec/windscribe/scripts"

      with subtest("packaging and socket permissions"):
          expected = ["cgroups-down", "cgroups-up", "gai-ipv4-priority", "update-network-manager", "update-resolv-conf", "update-systemd-resolved"]
          assert machine.succeed(f"ls -1 {scripts}").splitlines() == expected
          for name in expected:
              for filename in [name, f".{name}-wrapped"]:
                  script = f"{scripts}/{filename}"
                  machine.succeed(f"test -x {script} && ${pkgs.bash}/bin/bash -n {script}")
                  shebang = machine.succeed(f"head -1 {script}")
                  assert shebang.startswith("#!") and shebang[2:].lstrip().startswith("/nix/store/")
          machine.succeed("test ! -e /opt/windscribe")
          denied = machine.fail("runuser -u nobody -- ${client}/bin/gai-client up 2>&1")
          assert "Permission denied" in denied

      with subtest("packaged OpenVPN starts without privileges or a tunnel"):
          openvpn = "${windscribe}/libexec/windscribe/windscribeopenvpn"
          machine.succeed(f"test -L {openvpn} && test -x {openvpn}")
          version = machine.succeed(f"runuser -u alice -- {openvpn} --version")
          assert version.startswith("OpenVPN ${(pkgs.lib.importJSON ../sources/registry/ports/openvpn/vcpkg.json).version} "), version
          assert "OpenSSL 4.0.1" in version, version

      with subtest("script commands are available on the helper service PATH"):
          environment = shlex.split(machine.succeed("systemctl show windscribe-helper.service -p Environment --value"))
          path = next(entry.removeprefix("PATH=") for entry in environment if entry.startswith("PATH="))
          # restorecon is optional; resolvectl satisfies the systemd-resolve fallback.
          for tool in "ip mount grep cut head cat rmdir modprobe readlink umount rm mkdir touch cp mv chattr resolvconf logger busctl systemctl whoami resolvectl sed".split():
              machine.succeed(f"PATH={shlex.quote(path)} ${pkgs.bash}/bin/bash -c 'command -v {tool}'")

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

      # Query resolved itself rather than relying on script exit codes or config files.
      manager = "/org/freedesktop/resolve1"
      def resolved_property(obj, interface, name):
          output = machine.succeed(f"busctl --json=short get-property org.freedesktop.resolve1 {obj} org.freedesktop.resolve1.{interface} {name}")
          print(f"{obj} {name}: {output.strip()}")
          return json.loads(output)["data"]

      def dns_script(action, *options, caller_path=None):
          environment = [f"script_type={action}", "dev=ws-test"]
          if caller_path is not None:
              environment.append(f"PATH={caller_path}")
          environment += [f"foreign_option_{i}=dhcp-option {option}" for i, option in enumerate(options)]
          machine.succeed(shlex.join(["${pkgs.coreutils}/bin/env", "-i", *environment, f"{scripts}/update-systemd-resolved", "ws-test"]))

      machine.wait_for_unit("systemd-resolved.service")
      machine.succeed("ip link add ws-test type dummy && ip link set ws-test up")
      machine.succeed("ip link add ws-other type dummy && ip link set ws-other up")
      index = machine.succeed("cat /sys/class/net/ws-test/ifindex").strip()
      other_index = machine.succeed("cat /sys/class/net/ws-other/ifindex").strip()
      link = json.loads(machine.succeed(f"busctl --json=short call org.freedesktop.resolve1 {manager} org.freedesktop.resolve1.Manager GetLink i {index}"))["data"][0]
      other_link = json.loads(machine.succeed(f"busctl --json=short call org.freedesktop.resolve1 {manager} org.freedesktop.resolve1.Manager GetLink i {other_index}"))["data"][0]
      baseline = {name: resolved_property(manager, "Manager", name) for name in ["DNS", "Domains", "FallbackDNS"]}
      machine.succeed("cp /etc/systemd/resolved.conf /tmp/resolved-original")

      with subtest("per-link resolved DNS and domain round trip with an empty environment"):
          machine.succeed("resolvectl dns ws-other 198.51.100.53 && resolvectl domain ws-other other.invalid")
          other = {name: resolved_property(other_link, "Link", name) for name in ["DNS", "Domains"]}
          dns_script("up", "DNS 192.0.2.1", "DNS 192.0.2.2", "DOMAIN vpn.invalid", "DOMAIN-SEARCH search.invalid", "DOMAIN-ROUTE .")
          assert resolved_property(link, "Link", "DNS") == [[2, [192, 0, 2, 1]], [2, [192, 0, 2, 2]]]
          assert resolved_property(link, "Link", "Domains") == [["vpn.invalid", False], ["search.invalid", False], [".", True]]
          for name, value in other.items():
              assert resolved_property(other_link, "Link", name) == value
          dns_script("down")
          assert resolved_property(link, "Link", "DNS") == []
          assert resolved_property(link, "Link", "Domains") == []
          for name, value in other.items():
              assert resolved_property(other_link, "Link", name) == value
          # Manager DNS/Domains aggregate per-link entries; remove the unrelated fixture first.
          machine.succeed("resolvectl revert ws-other")
          for name, value in baseline.items():
              assert resolved_property(manager, "Manager", name) == value

      with subtest("DNS hooks ignore an untrusted caller PATH"):
          machine.succeed("mkdir -p /tmp/untrusted-bin")
          fake = "#!${pkgs.bash}/bin/bash\n${pkgs.coreutils}/bin/touch /tmp/untrusted-tool-ran\nexit 99\n"
          for tool in ["ip", "busctl", "logger", "resolvectl", "systemctl", "rm"]:
              machine.succeed(f"printf %s {shlex.quote(fake)} > /tmp/untrusted-bin/{tool}; chmod +x /tmp/untrusted-bin/{tool}")
          dns_script("up", "DNS 192.0.2.1", caller_path="/tmp/untrusted-bin")
          assert resolved_property(link, "Link", "DNS") == [[2, [192, 0, 2, 1]]]
          dns_script("down", caller_path="/tmp/untrusted-bin")
          assert resolved_property(link, "Link", "DNS") == []
          machine.succeed("test ! -e /tmp/untrusted-tool-ran")

      with subtest("loopback resolved override and restoration"):
          dns_script("up", "DNS 127.0.0.1", "DOMAIN-ROUTE .")
          assert [entry[-1] for entry in resolved_property(manager, "Manager", "DNS")] == [[127, 0, 0, 1]]
          assert any(entry[-2:] == [".", True] for entry in resolved_property(manager, "Manager", "Domains"))
          assert resolved_property(manager, "Manager", "FallbackDNS") == baseline["FallbackDNS"]
          dns_script("down")
          for name, value in baseline.items():
              assert resolved_property(manager, "Manager", name) == value
          machine.succeed("test ! -e /usr/local/lib/systemd/resolved.conf.d/windscribe.conf")
          machine.succeed("cmp /etc/systemd/resolved.conf /tmp/resolved-original")
          machine.succeed("systemctl is-active systemd-resolved.service")

      with subtest("loopback teardown after the tunnel interface disappears"):
          dns_script("up", "DNS 127.0.0.1", "DOMAIN-ROUTE .")
          machine.succeed("ip link del ws-test")
          dns_script("down")
          for name, value in baseline.items():
              assert resolved_property(manager, "Manager", name) == value
          machine.succeed("test ! -e /usr/local/lib/systemd/resolved.conf.d/windscribe.conf")

      with subtest("GUI connects to this VM's helper"):
          machine.wait_for_x()
          machine.wait_for_file("/home/alice/.Xauthority")
          machine.succeed("xauth merge /home/alice/.Xauthority")
          machine.succeed("su - alice -c 'DISPLAY=:0 QT_FORCE_STDERR_LOGGING=1 ${windscribe}/bin/Windscribe > /tmp/windscribe-gui.log 2>&1 &'")
          machine.wait_until_succeeds("grep -q 'connected to helper socket' /tmp/windscribe-gui.log", timeout=datetime.timedelta(seconds=60))
          machine.wait_until_succeeds("grep -q 'IPC server for CLI started' /tmp/windscribe-gui.log", timeout=datetime.timedelta(seconds=60))
          machine.succeed("grep -q 'cgroups disable' /var/log/windscribe/helper.log")
          machine.fail("grep -E 'cgroups-down script failed|command not found' /var/log/windscribe/helper.log")
          machine.wait_for_window("Windscribe", timeout=datetime.timedelta(seconds=60))
          machine.screenshot("windscribe-startup")
          machine.succeed("systemctl is-active windscribe-helper.service")
          machine.succeed("pgrep -u alice -f '^${windscribe}/bin/Windscribe$'")
          machine.copy_from_machine("/tmp/windscribe-gui.log")
          machine.copy_from_machine("/var/log/windscribe/helper.log")
    '';
  }
