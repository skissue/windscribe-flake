{
  pkgs,
  windscribe,
  module,
}: let
  client = pkgs.stdenv.mkDerivation {
    name = "windscribe-helper-test-client";
    dontUnpack = true;
    buildInputs = [pkgs.boost188 pkgs.spdlog];
    buildPhase = ''
      $CXX -std=c++17 -pthread ${./helper-client.cpp} \
        ${../../src/client/client-common/types/ipaddress.cpp} \
        -I${../../src/helper/common} -I${../../src/client/client-common} \
        -I${../../src/client/client-common/types} \
        -lboost_serialization -lspdlog -lfmt -o helper-client
    '';
    installPhase = "install -Dm755 helper-client $out/bin/helper-client";
  };
  # Only the helper sees this shim; the isolated vanilla peer keeps kernel WG.
  modprobe = pkgs.writeShellScriptBin "modprobe" ''
    if [ "$1" = wireguard ] && [ -e /run/force-wg-fallback ]; then
      touch /run/wg-fallback-observed
      exit 1
    fi
    exec ${pkgs.kmod}/bin/modprobe "$@"
  '';
in
  pkgs.testers.runNixOSTest {
    name = "windscribe-runtime";
    enableOCR = true;
    nodes.machine = {
      imports = [module "${pkgs.path}/nixos/tests/common/x11.nix"];
      services.windscribe = {
        enable = true;
        package = windscribe;
      };
      test-support.displayManager.auto.user = "alice";
      # Only the synthetic IPC fixture gets account-wide helper access.
      users.users.fixture = {
        isSystemUser = true;
        group = "windscribe";
      };
      users.users.alice = {
        isNormalUser = true;
      };
      # Keep DHCP from racing DNS snapshots or configuring synthetic tunnel links.
      networking.useDHCP = false;
      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = "10.0.2.15";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = "10.0.2.2";
      networking.firewall.allowedUDPPorts = [51821];
      environment.systemPackages = [client pkgs.wireguard-tools pkgs.dnsmasq pkgs.dig pkgs.python3 pkgs.nftables];
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
        path = pkgs.lib.mkBefore [modprobe];
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
      client = "runuser -u fixture -- ${client}/bin/helper-client"
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
          assert "windscribe" not in machine.succeed("id -nG alice").split()
          assert machine.succeed("stat -c '%U:%G %a' /run/windscribe/helper.sock").strip() == "root:windscribe 770"
          for user in ["alice", "nobody"]:
              denied = machine.fail(f"runuser -u {user} -- ${client}/bin/helper-client up 2>&1")
              assert "Permission denied" in denied
          for name in ["Windscribe", "windscribe-cli"]:
              assert machine.succeed(f"su - alice -c 'command -v {name}'").strip() == f"/run/wrappers/bin/{name}"
              owner, mode = machine.succeed(f"stat -Lc '%U:%G %a' /run/wrappers/bin/{name}").split()
              assert owner == "root:windscribe", owner
              assert int(mode, 8) & 0o7111 == 0o2111, mode

      with subtest("packaged OpenVPN starts without privileges or a tunnel"):
          openvpn = "${windscribe}/libexec/windscribe/windscribeopenvpn"
          machine.succeed(f"test -L {openvpn} && test -x {openvpn}")
          version = machine.succeed(f"runuser -u alice -- {openvpn} --version")
          assert version.startswith("OpenVPN ${(pkgs.lib.importJSON ../sources/registry/ports/openvpn/vcpkg.json).version} "), version
          assert "OpenSSL 4.0.1" in version, version

      with subtest("packaged AmneziaWG userspace daemon starts without credentials"):
          amneziawg = "${windscribe}/libexec/windscribe/windscribeamneziawg"
          machine.succeed(f"test -L {amneziawg} && test -x {amneziawg}")
          version = machine.succeed(f"{amneziawg} --version")
          assert version.startswith("amneziawg-go v0.2.16\n"), version
          machine.succeed(f"systemd-run --unit=amneziawg-smoke --property=Type=simple --setenv=LOG_LEVEL=debug {amneziawg} -f awg-smoke0")
          machine.wait_until_succeeds("test -S /run/amneziawg/awg-smoke0.sock")
          machine.succeed("ip link show awg-smoke0")
          machine.succeed("${pkgs.python3}/bin/python -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect(\"/run/amneziawg/awg-smoke0.sock\")'")
          machine.succeed("systemctl stop amneziawg-smoke.service")
          machine.wait_until_succeeds("test ! -e /run/amneziawg/awg-smoke0.sock && ! ip link show awg-smoke0")

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

      for mode in ["kernel", "fallback", "amnezia"]:
        with subtest(f"{mode} WireGuard through real helper IPC, isolated synthetic peer"):
          # All keys and network changes exist only inside this disposable VM.
          if mode == "fallback":
              machine.succeed("touch /run/force-wg-fallback")
          else:
              machine.succeed("test ! -e /run/force-wg-fallback")
          uapi = "python3 ${./uapi.py}"
          machine.succeed("ip -4 route save default > /run/wg-default-routes; ip -4 route flush default")
          machine.succeed("ip netns add wg-peer; ip link add wg-underlay type veth peer name eth0 netns wg-peer")
          machine.succeed("ip addr add 192.0.2.1/30 dev wg-underlay; ip link set wg-underlay up")
          peer = "ip netns exec wg-peer"
          machine.succeed(f"{peer} ip addr add 192.0.2.2/30 dev eth0; {peer} ip link set eth0 up; {peer} ip link set lo up")
          machine.succeed(f"ip addr add 10.20.30.1/24 dev wg-underlay; {peer} ip addr add 10.20.30.2/24 dev eth0")
          machine.succeed(f"{peer} ip addr add 198.18.0.2/32 dev lo; ip route add default via 192.0.2.2")
          machine.succeed("install -d -m700 /run/wg-keys; umask 077; wg genkey > /run/wg-keys/client; wg genkey > /run/wg-keys/peer; wg genpsk > /run/wg-keys/psk; wg pubkey < /run/wg-keys/client > /run/wg-keys/client.pub; wg pubkey < /run/wg-keys/peer > /run/wg-keys/peer.pub")
          if mode == "amnezia":
              # Resolve the symlink so helper forceStop's pkill -f windscribeamneziawg
              # cannot match the namespace peer's command line.
              daemon = machine.succeed(f"readlink -f {amneziawg}").strip()
              assert "windscribeamneziawg" not in daemon
              machine.succeed(f"systemd-run --unit=awg-test-peer {peer} {daemon} -f wg0")
              machine.wait_until_succeeds("test -S /run/amneziawg/wg0.sock")
              machine.succeed(f"{uapi} configure-peer")
          else:
              machine.succeed(f"{peer} ip link add wg0 type wireguard; {peer} wg set wg0 private-key /run/wg-keys/peer listen-port 51820 peer $(cat /run/wg-keys/client.pub) preshared-key /run/wg-keys/psk allowed-ips 10.77.0.2/32,fd77::2/128")
          machine.succeed(f"{peer} ip addr add 10.77.0.1/24 dev wg0; {peer} ip link set wg0 up")
          # Model Windscribe's allowed on-node DNS range and a public tunneled destination.
          machine.succeed(f"{peer} ip addr add 10.255.255.1/32 dev lo; {peer} ip addr add 203.0.113.99/32 dev lo")
          if mode != "amnezia":
              machine.succeed(f"{peer} ip -6 addr add fd77::1/64 dev wg0 nodad")
          # Existing foreign rules must survive WG teardown. Tailscale's real priorities
          # also make automatic WG priorities visibly wrong, even without credentials.
          routing_table = 51821 if mode == "fallback" else 51820
          if mode == "fallback":
              machine.succeed("ip route add unreachable 203.0.113.7/32 table 51820")
          for family in ["-4", "-6"]:
              machine.succeed(f"ip {family} rule add pref 6000 lookup main suppress_prefixlength 0")
              machine.succeed(f"ip {family} rule add pref 6001 fwmark 0x1234 lookup {routing_table}")
              machine.succeed(f"ip {family} rule add pref 5210 fwmark 0x80000/0xff0000 lookup main")
              machine.succeed(f"ip {family} rule add pref 5230 fwmark 0x80000/0xff0000 lookup default")
              machine.succeed(f"ip {family} rule add pref 5250 fwmark 0x80000/0xff0000 unreachable")
              machine.succeed(f"ip {family} rule add pref 5270 lookup 52")
          if mode == "kernel":
              # A synthetic tailnet, not a Tailscale daemon: exercises table 52, real
              # packets and MagicDNS while requiring no account or external network.
              tail = "ip netns exec tail-peer"
              machine.succeed("ip netns add tail-peer; ip link add tailscale0 type veth peer name eth0 netns tail-peer")
              machine.succeed("ip addr add 100.72.0.1/32 dev tailscale0; ip link set tailscale0 up")
              machine.succeed(f"{tail} ip link set lo up; {tail} ip link set eth0 up; {tail} ip addr add 100.72.0.2/32 dev eth0; {tail} ip route add 100.72.0.1/32 dev eth0")
              machine.succeed(f"{tail} ip addr add 100.100.100.100/32 dev lo; {tail} ip addr add 100.72.0.53/32 dev lo")
              machine.succeed("ip route add 100.72.0.0/16 dev tailscale0 table 52; ip route add 100.100.100.100/32 dev tailscale0 table 52")
              def scoped_rules(op):
                  machine.succeed(f"ip rule {op} pref 5100 to 100.72.0.0/16 lookup 52; ip rule {op} pref 5101 to 100.100.100.100/32 lookup 52")
              scoped_rules("add")
              machine.succeed("resolvectl dns tailscale0 100.100.100.100 100.72.0.53; resolvectl domain tailscale0 '~tail.test'")
              machine.succeed(f"systemd-run --unit=tail-test-dns {tail} ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces --listen-address=100.100.100.100,100.72.0.53 --address=/tail.test/100.72.0.2")
              machine.wait_for_unit("tail-test-dns.service")
              machine.succeed("nft 'add table inet tailnet_guard; add chain inet tailnet_guard output { type filter hook output priority 10; policy accept; }; add rule inet tailnet_guard output ip daddr { 100.72.0.0/16, 100.100.100.100 } oifname != { \"tailscale0\", \"lo\" } counter drop'")
          machine.succeed(f"systemd-run --unit=wg-test-dns {peer} ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces --listen-address=10.255.255.1 --address=/isolated.test/203.0.113.99")
          machine.wait_for_unit("wg-test-dns.service")
          routes = machine.succeed("ip -4 route show table all")
          rules = machine.succeed("ip -4 rule show")
          rules6 = machine.succeed("ip -6 rule show")
          # Packet counters change with traffic; compare rules, not counters.
          firewall = machine.succeed("nft --stateless list ruleset")
          dns_before = {name: resolved_property(manager, "Manager", name) for name in baseline}
          try:
              action = "awg" if mode == "amnezia" else "wg"
              machine.succeed(f"{client} {action}-start")
              if mode == "kernel":
                  machine.succeed("grep -q 'Using wireguard kernel module' /var/log/windscribe/helper.log")
                  machine.succeed("test ! -e /run/amneziawg/utun420.sock")
              else:
                  machine.wait_until_succeeds("test -S /run/amneziawg/utun420.sock")
                  machine.succeed("grep -q 'Using amneziawg-go' /var/log/windscribe/helper.log")
                  machine.succeed(f"pgrep -f '^{amneziawg} -f utun420$'")
                  if mode == "fallback":
                      machine.succeed("test -e /run/wg-fallback-observed")
              # Convert the generated base64 keys to the engine's hex IPC format without printing them.
              encode = "import base64; from pathlib import Path; print(' '.join(base64.b64decode(Path('/run/wg-keys/' + n).read_text()).hex() for n in ['client', 'peer.pub', 'psk']))"
              machine.succeed(f"python3 -c {shlex.quote(encode)} | {client} {action}-configure")
              kind = json.loads(machine.succeed("ip -d -j link show utun420"))[0]["linkinfo"]["info_kind"]
              assert kind == ("wireguard" if mode == "kernel" else "tun"), kind
              if mode == "amnezia":
                  expected = dict(jc="3", jmin="40", jmax="80", s1="16", s2="24", h1="100001", h2="200002", h3="300003", h4="400004")
                  for device in ["utun420", "wg0"]:
                      actual = json.loads(machine.succeed(f"{uapi} {device}"))
                      assert {key: actual[key] for key in expected} == expected, actual
              machine.succeed("ip -4 addr show utun420 | grep -q '10.77.0.2/32'")
              machine.succeed(f"ip -4 route show table {routing_table} | grep -q 'default dev utun420'")
              for family in (["-4"] if mode == "amnezia" else ["-4", "-6"]):
                  installed = machine.succeed(f"ip {family} rule show")
                  assert "5208:\tfrom all lookup main suppress_prefixlength 0" in installed, installed
                  assert f"5209:\tnot from all fwmark 0xca6c lookup {routing_table}" in installed, installed
              machine.succeed("ip -4 route get 198.18.0.2 | grep -q 'via 192.0.2.2 dev wg-underlay'")
              machine.succeed(f"ip -4 route get 203.0.113.99 | grep -q 'dev utun420 table {routing_table}'")
              machine.succeed("nft list ruleset | grep -q 'chain wg_mangle_pre'")
              machine.wait_until_succeeds("ping -c 3 -W 2 10.77.0.1", timeout=datetime.timedelta(seconds=30))
              if mode != "amnezia":
                  machine.succeed(f"ip -6 route get 2001:db8::99 | grep -q 'dev utun420 table {routing_table}'")
                  machine.succeed("ping -6 -c 3 -W 2 fd77::1")
              machine.succeed(f"{peer} ping -c 3 -W 2 10.77.0.2")
              machine.wait_until_succeeds(f"{client} wg-status", timeout=datetime.timedelta(seconds=30))
              # Independent evidence, never raw UAPI or wg showconf/dump (keys).
              if mode == "kernel":
                  assert int(machine.succeed("wg show utun420 latest-handshakes").split()[1]) > 0
              else:
                  status = json.loads(machine.succeed(f"{uapi} utun420"))
                  assert all(int(status[key]) > 0 for key in ["last_handshake_time_sec", "rx_bytes", "tx_bytes"]), status
              if mode == "amnezia":
                  status = json.loads(machine.succeed(f"{uapi} wg0"))
                  assert all(int(status[key]) > 0 for key in ["last_handshake_time_sec", "rx_bytes", "tx_bytes"]), status
              else:
                  assert int(machine.succeed(f"{peer} wg show wg0 latest-handshakes").split()[1]) > 0
                  transfer = machine.succeed(f"{peer} wg show wg0 transfer").split()
                  assert int(transfer[1]) > 0 and int(transfer[2]) > 0
              wg_index = machine.succeed("cat /sys/class/net/utun420/ifindex").strip()
              wg_link = json.loads(machine.succeed(f"busctl --json=short call org.freedesktop.resolve1 {manager} org.freedesktop.resolve1.Manager GetLink i {wg_index}"))["data"][0]
              assert resolved_property(wg_link, "Link", "DNS") == [[2, [10, 255, 255, 1]]]
              assert resolved_property(wg_link, "Link", "Domains") == [[".", True]]
              machine.succeed("resolvectl flush-caches")
              answer = machine.succeed("resolvectl query isolated.test")
              assert "203.0.113.99" in answer and "utun420" in answer, answer
              if mode == "kernel":
                  # Exercise the packaged cgroup script without moving any processes.
                  # It must not duplicate WG's priority-5208 rule in either family.
                  machine.succeed(shlex.join([f"{scripts}/cgroups-up", "0xdecafbad", "192.0.2.2", "wg-underlay", "10.77.0.1", "utun420", "198.18.0.2", "0xcafecafe", "allow", "exclusive", "", "fd77::1", "wg-underlay", "", "0xca6c"]))
                  for family in ["-4", "-6"]:
                      assert machine.succeed(f"ip {family} rule show").count("5208:") == 1
                  machine.succeed(f"{scripts}/cgroups-down")
                  machine.succeed(f"{client} split-on && {client} connected && {client} firewall-on")
                  # The real exclusion path still pins physical routes. Scoped rules
                  # must win regardless of whether they were added before or after WG.
                  machine.succeed("ip route show 100.72.0.0/16 | grep -q 'via 192.0.2.2 dev wg-underlay'")
                  for readd in [False, True]:
                      if readd:
                          scoped_rules("del")
                          scoped_rules("add")
                      machine.succeed("ip route get 100.72.0.2 | grep -q 'dev tailscale0 table 52'")
                      machine.succeed("ip route get 100.100.100.100 | grep -q 'dev tailscale0 table 52'")
                      machine.succeed("ip route get 10.20.30.2 mark 0x80000 | grep -q 'dev wg-underlay'")
                      machine.succeed("ip route get 203.0.113.99 | grep -q 'dev utun420 table 51820'")
                      for destination in ["100.72.0.2", "10.20.30.2", "203.0.113.99"]:
                          machine.succeed(f"ping -c 2 -W 2 {destination}")
                  def query(server, tcp=False):
                      transport = "+tcp" if tcp else "+notcp"
                      return f"dig +time=1 +tries=1 +short {transport} @{server} peer.tail.test A"
                  for tcp in [False, True]:
                      assert machine.succeed(query("100.100.100.100", tcp)).strip() == "100.72.0.2"
                      machine.fail(query("100.72.0.53", tcp))
                  machine.succeed("resolvectl flush-caches")
                  assert "100.72.0.2" in machine.succeed("resolvectl query peer.tail.test")
                  assert machine.succeed("dig +time=1 +tries=1 +short @10.255.255.1 isolated.test").strip() == "203.0.113.99"
                  # A lost table-52 route must not turn an exclusion into an underlay leak.
                  machine.succeed("ip route del 100.72.0.0/16 table 52")
                  machine.fail("ping -c 1 -W 1 100.72.0.2")
                  guard = json.loads(machine.succeed("nft -j list chain inet tailnet_guard output"))
                  assert any(expr.get("counter", {}).get("packets", 0) > 0 for item in guard["nftables"] for expr in item.get("rule", {}).get("expr", [])), guard
                  machine.succeed("ip route add 100.72.0.0/16 dev tailscale0 table 52")
                  # Remove the external guard to isolate DNS's own wrong-interface
                  # protection. The peer also serves MagicDNS over the VPN path.
                  machine.succeed(f"{peer} ip addr add 100.100.100.100/32 dev lo")
                  machine.succeed(f"systemd-run --unit=wg-magic-dns {peer} ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces --listen-address=100.100.100.100 --address=/tail.test/100.72.0.2")
                  machine.wait_for_unit("wg-magic-dns.service")
                  machine.succeed("nft flush chain inet tailnet_guard output; ip route del 100.100.100.100/32 table 52; ip route replace 100.100.100.100/32 dev utun420")
                  for tcp in [False, True]:
                      machine.fail(query("100.100.100.100", tcp))
                  # Positive controls: both servers respond when DNS protection is
                  # removed, so the failures above cannot be a missing listener.
                  machine.succeed("nft flush chain inet windscribe dnsleaks")
                  for tcp in [False, True]:
                      assert machine.succeed(query("100.100.100.100", tcp)).strip() == "100.72.0.2"
                      assert machine.succeed(query("100.72.0.53", tcp)).strip() == "100.72.0.2"
                  machine.succeed("systemctl stop wg-magic-dns.service")
                  machine.succeed("ip route replace 100.100.100.100/32 via 192.0.2.2 dev wg-underlay; ip route add 100.100.100.100/32 dev tailscale0 table 52")
                  machine.succeed("nft 'add rule inet tailnet_guard output ip daddr { 100.72.0.0/16, 100.100.100.100 } oifname != { \"tailscale0\", \"lo\" } counter drop'")
                  # Reapply via the production connect lifecycle, not handcrafted DNS rules.
                  machine.succeed(f"{client} connected && {client} firewall-on")
                  assert machine.succeed(query("100.100.100.100")).strip() == "100.72.0.2"
                  machine.fail(query("100.72.0.53"))
                  # Ordinary traffic must still fail closed if forced onto the underlay.
                  machine.succeed(f"{peer} ip addr add 198.18.0.3/32 dev lo; ip route add 198.18.0.3/32 via 192.0.2.2")
                  machine.fail("ping -c 1 -W 1 198.18.0.3")
                  machine.succeed(f"{client} firewall-off")
                  machine.succeed("ping -c 1 -W 1 198.18.0.3 && ip route del 198.18.0.3/32")
                  machine.succeed(f"{client} disconnected && {client} split-off && {client} firewall-off")
                  # The legacy bound-route teardown removes the existing default too.
                  machine.succeed("ip route replace default via 192.0.2.2 dev wg-underlay")
          finally:
              machine.succeed(f"{client} wg-stop")
              machine.succeed("rm -rf /run/wg-keys")
              machine.succeed("systemctl stop wg-test-dns.service")
          machine.wait_until_succeeds("test ! -e /run/amneziawg/utun420.sock && ! ip link show utun420")
          machine.fail(f"pgrep -f '^{amneziawg} -f utun420$'")
          assert machine.succeed("ip -4 route show table all") == routes
          assert machine.succeed("ip -4 rule show") == rules
          assert machine.succeed("ip -6 rule show") == rules6
          machine.fail("nft list ruleset | grep -E 'chain wg_(raw|mangle)_'")
          firewall_after = machine.succeed("nft --stateless list ruleset")
          # The helper retains its empty shared table after the first connection.
          empty_table = "table inet windscribe {\n}\n"
          assert firewall_after.replace(empty_table, "") == firewall.replace(empty_table, ""), f"Before:\n{firewall}\nAfter:\n{firewall_after}"
          for name, value in dns_before.items():
              assert resolved_property(manager, "Manager", name) == value
          machine.succeed(f"{client} wg-stop")
          machine.succeed("test ! -e /run/amneziawg/utun420.sock && ! ip link show utun420")
          machine.fail(f"pgrep -f '^{amneziawg} -f utun420$'")
          for family in ["-4", "-6"]:
              for priority in [5210, 5230, 5250, 5270, 6000, 6001]:
                  machine.succeed(f"ip {family} rule del pref {priority}")
          if mode == "fallback":
              machine.succeed("ip route del unreachable 203.0.113.7/32 table 51820")
          if mode == "kernel":
              scoped_rules("del")
              machine.succeed("systemctl stop tail-test-dns.service; nft delete table inet tailnet_guard; ip link del tailscale0; ip netns del tail-peer")
          if mode == "amnezia":
              machine.succeed("systemctl is-active awg-test-peer.service")
              machine.succeed("systemctl stop awg-test-peer.service")
              machine.wait_until_succeeds(f"test ! -e /run/amneziawg/wg0.sock && ! {peer} ip link show wg0")
          # src_valid_mark intentionally retains wg-quick semantics; no sysctl reset.
          machine.succeed("rm -f /run/force-wg-fallback /run/wg-fallback-observed")
          machine.succeed("ip route del default; ip link del wg-underlay; ip netns del wg-peer; ip -4 route restore < /run/wg-default-routes; rm /run/wg-default-routes")
          machine.succeed("test ! -e /run/wg-keys; test -z \"$(ip netns list)\"")

      with subtest("GUI connects to this VM's helper"):
          machine.wait_for_x()
          machine.wait_for_file("/home/alice/.Xauthority")
          machine.succeed("xauth merge /home/alice/.Xauthority")
          uid = machine.succeed("id -u alice").strip()
          gid = machine.succeed("id -g alice").strip()
          session = f"DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/{uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"
          def alice(command):
              return "su - alice -c " + shlex.quote(f"{session} {command}")
          machine.succeed(alice("QT_FORCE_STDERR_LOGGING=1 Windscribe > /tmp/windscribe-gui.log 2>&1 &"))
          try:
              machine.wait_until_succeeds("grep -q 'connected to helper socket' /tmp/windscribe-gui.log", timeout=datetime.timedelta(seconds=60))
          finally:
              print(machine.succeed("cat /tmp/windscribe-gui.log"))
          machine.wait_until_succeeds("grep -q 'IPC server for CLI started' /tmp/windscribe-gui.log", timeout=datetime.timedelta(seconds=60))
          machine.succeed("grep -q 'cgroups disable' /var/log/windscribe/helper.log")
          machine.fail("grep -E 'cgroups-down script failed|command not found' /var/log/windscribe/helper.log")
          machine.wait_for_window("Windscribe", timeout=datetime.timedelta(seconds=60))
          machine.wait_for_text("Get Started")
          machine.screenshot("windscribe-welcome")
          machine.succeed("systemctl is-active windscribe-helper.service")
          def gui_pid():
              return machine.succeed("for p in /proc/[0-9]*; do [ \"$(readlink $p/exe)\" = '${windscribe}/bin/.Windscribe-wrapped' ] && basename $p; done; true").strip()
          def check_gui():
              pid = gui_pid()
              assert pid.isdigit(), pid
              status = machine.succeed(f"cat /proc/{pid}/status")
              print(status)
              fields = dict(line.split(":", 1) for line in status.splitlines())
              assert fields["Uid"].split() == [uid] * 4
              assert fields["Gid"].split() == [gid] * 4
              assert machine.succeed("getent group windscribe").split(":")[2] not in fields["Groups"].split()
              # Inspect threads separately: the helper connection thread intentionally
              # retains its group; main-thread credentials cannot establish otherwise.
              print(machine.succeed(f"grep -E '^(Name|Pid|Gid):' /proc/{pid}/task/*/status"))
              maps = machine.succeed(f"cat /proc/{pid}/maps")
              for library in ["libwsnet.so", "libQt6DBus.so", "libqxcb.so"]:
                  assert any("/nix/store/" in line and library in line for line in maps.splitlines()), library
              print(machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -E '^(QT_|LD_LIBRARY_PATH=)'"))
              bus = machine.succeed(alice("busctl --user --no-pager list"))
              assert any(line.split()[1:2] == [pid] for line in bus.splitlines()), bus
              return pid
          pid = check_gui()
          output = machine.succeed(alice("windscribe-cli status"))
          assert "Login state: Logged out" in output, output
          output = machine.fail(alice("windscribe-cli connect"))
          assert "Not logged in" in output, output
          machine.copy_from_machine("/tmp/windscribe-gui.log")
          machine.copy_from_machine("/var/log/windscribe/helper.log")

      with subtest("CLI auto-starts a fresh GUI through the packaged launcher"):
          machine.succeed(f"kill -TERM {pid}")
          machine.wait_until_succeeds(f"test ! -e /proc/{pid}")
          assert gui_pid() == ""
          gui_log = "/home/alice/.local/share/Windscribe/Windscribe2/client.log"
          machine.succeed(f"test -f {gui_log}; rm {gui_log}")
          output = machine.succeed(alice("windscribe-cli status"))
          assert "Login state: Logged out" in output, output
          assert check_gui() != pid
          machine.wait_until_succeeds(f"grep -q 'connected to helper socket' {gui_log}")
          machine.succeed(f"grep -q 'IPC server for CLI started' {gui_log}")
          machine.wait_for_text("Get Started")
          output = machine.fail(alice("windscribe-cli connect"))
          assert "Not logged in" in output, output
          machine.copy_from_machine(gui_log)
          machine.copy_from_machine("/var/log/windscribe/helper.log")
          machine.succeed(f"kill -TERM {gui_pid()}")
    '';
  }
