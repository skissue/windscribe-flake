// Test-only client: use the production command enum and Boost serialization.
#include "helper_commands.h"

#include <boost/asio.hpp>
#include <iostream>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        return 2;
    }
    try {
        const std::string action = argv[1];
        HelperCommand operation;
        std::string payload;
        if (action == "up" || action == "down") {
            operation = HelperCommand::setGaiIpv4PriorityEnabled;
            payload = serializeResult(action == "up");
        } else if (action == "split-on" || action == "split-off" || action == "split-defaults") {
            operation = HelperCommand::setSplitTunnelingSettings;
            const bool defaults = action == "split-defaults";
            payload = serializeResult(action != "split-off", true, true,
                std::vector<std::string>(),
                defaults
                    ? std::vector<std::string>{"0.0.0.0/0", "100.72.0.0/16", "::/0", "fd7a:115c:a1e0::/64"}
                    : std::vector<std::string>{"100.72.0.0/16", "100.100.100.100", "fd7a:115c:a1e0::/64"},
                std::vector<std::string>());
        } else if (action == "connected" || action == "disconnected") {
            operation = HelperCommand::sendConnectStatus;
            ADAPTER_GATEWAY_INFO physical, vpn;
            physical.adapterName = "wg-underlay";
            physical.adapterIp = types::IpAddress("192.0.2.1");
            physical.gatewayIp = types::IpAddress("192.0.2.2");
            vpn.adapterName = "utun420";
            vpn.adapterIp = types::IpAddress("10.77.0.2");
            vpn.adapterIpV6 = types::IpAddress("fd77::2");
            vpn.gatewayIp = vpn.adapterIp;
            vpn.gatewayIpV6 = vpn.adapterIpV6;
            vpn.dnsServers = {types::IpAddress("10.255.255.1")};
            payload = serializeResult(action == "connected", kCmdProtocolWireGuard, physical, vpn,
                types::IpAddress("198.18.0.2"), types::IpAddress("198.18.0.2"), std::vector<std::string>());
        } else if (action == "firewall-on") {
            operation = HelperCommand::setFirewallRules;
            FirewallConfig config;
            config.connectingIp = "198.18.0.2";
            config.vpnInterfaceName = "utun420";
            config.allowLanTraffic = true;
            payload = serializeResult(config);
        } else if (action == "firewall-off") {
            operation = HelperCommand::clearFirewallRules;
            payload = serializeResult(false);
        } else if (action == "wg-start" || action == "awg-start") {
            operation = HelperCommand::startWireGuard;
            payload = serializeResult(action == "awg-start", false);
        } else if (action == "wg-stop") {
            operation = HelperCommand::stopWireGuard;
        } else if (action == "wg-status") {
            operation = HelperCommand::getWireGuardStatus;
        } else if (action == "wg-configure" || action == "awg-configure") {
            // Hex keys arrive on stdin, never in command arguments or test output.
            std::string privateKey, publicKey, presharedKey;
            if (!(std::cin >> privateKey >> publicKey >> presharedKey))
                return 2;
            AmneziawgConfig obfuscation;
            if (action == "awg-configure") {
                obfuscation.jc = 3;
                obfuscation.jmin = 40;
                obfuscation.jmax = 80;
                obfuscation.s1 = 16;
                obfuscation.s2 = 24;
                obfuscation.h1 = "100001";
                obfuscation.h2 = "200002";
                obfuscation.h3 = "300003";
                obfuscation.h4 = "400004";
            }
            operation = HelperCommand::configureWireGuard;
            payload = serializeResult(privateKey, std::string(action == "awg-configure" ? "10.77.0.2/32" : "10.77.0.2/32,fd77::2/128"),
                std::string("10.255.255.1"), publicKey, presharedKey,
                std::string("198.18.0.2:51820"), std::string(action == "awg-configure" ? "0.0.0.0/0" : "0.0.0.0/0,::/0"),
                uint16_t(51821), kSystemdResolved, obfuscation);
        } else {
            return 2;
        }
        boost::asio::io_context io;
        boost::asio::local::stream_protocol::socket socket(io);
        socket.connect(boost::asio::local::stream_protocol::endpoint("/run/windscribe/helper.sock"));

        const int command = static_cast<int>(operation);
        const pid_t pid = getpid();
        const int length = payload.size();
        boost::asio::write(socket, boost::asio::buffer(&command, sizeof(command)));
        boost::asio::write(socket, boost::asio::buffer(&pid, sizeof(pid)));
        boost::asio::write(socket, boost::asio::buffer(&length, sizeof(length)));
        boost::asio::write(socket, boost::asio::buffer(payload));

        int responseLength;
        boost::asio::read(socket, boost::asio::buffer(&responseLength, sizeof(responseLength)));
        if (action == "up" || action == "down" || action == "split-on" || action == "split-off"
            || action == "split-defaults")
            return responseLength == 0 ? 0 : 1;
        if (responseLength <= 0 || responseLength > 4096)
            return 1;
        std::string response(responseLength, '\0');
        boost::asio::read(socket, boost::asio::buffer(response));
        if (action == "wg-status") {
            unsigned int error;
            WireGuardServiceState state;
            unsigned long long received, transmitted;
            deserializePars(response, error, state, received, transmitted);
            std::cout << state << ' ' << error << ' ' << received << ' ' << transmitted << '\n';
            return error == 0 && state == kWgStateActive && received > 0 && transmitted > 0 ? 0 : 1;
        }
        bool success = false;
        deserializePars(response, success);
        return success ? 0 : 1;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
