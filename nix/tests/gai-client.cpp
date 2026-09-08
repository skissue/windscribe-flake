// Test-only client: use the production command enum and Boost serialization.
#include "helper_commands.h"

#include <boost/asio.hpp>
#include <iostream>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2 || (std::string(argv[1]) != "up" && std::string(argv[1]) != "down")) {
        return 2;
    }
    try {
        boost::asio::io_context io;
        boost::asio::local::stream_protocol::socket socket(io);
        socket.connect(boost::asio::local::stream_protocol::endpoint("/run/windscribe/helper.sock"));

        const int command = static_cast<int>(HelperCommand::setGaiIpv4PriorityEnabled);
        const pid_t pid = getpid();
        const std::string payload = serializeResult(std::string(argv[1]) == "up");
        const int length = payload.size();
        boost::asio::write(socket, boost::asio::buffer(&command, sizeof(command)));
        boost::asio::write(socket, boost::asio::buffer(&pid, sizeof(pid)));
        boost::asio::write(socket, boost::asio::buffer(&length, sizeof(length)));
        boost::asio::write(socket, boost::asio::buffer(payload));

        // This handler acknowledges completion with an empty response, not a status.
        int responseLength;
        boost::asio::read(socket, boost::asio::buffer(&responseLength, sizeof(responseLength)));
        return responseLength == 0 ? 0 : 1;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
