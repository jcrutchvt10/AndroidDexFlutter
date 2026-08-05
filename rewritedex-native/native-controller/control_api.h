#pragma once

#include <functional>
#include <string>

// Local control API for the separate visual shell process (recommendation 3.1).
// The controller keeps owning the transport, input hooks and agent IPC, and
// exposes a loopback HTTP surface here so the shell is a pure client that can
// never crash the desktop stream.
//
// Endpoints:
//   GET  /control/status            -> device/stream status JSON
//   POST /control/command           -> {"command":<WM_COMMAND id>} posts to the
//                                      controller window; returns {"ok":bool}
//   <any other method+path>         -> proxied verbatim to the Android agent
//
// The server is intentionally dependency-free: all behaviour is injected via
// [Callbacks] so this translation unit stays a thin HTTP transport.
namespace control {

struct Callbacks {
    // Builds the JSON payload for GET /control/status.
    std::function<std::string()> statusJson;
    // Executes a controller WM_COMMAND. Must be safe to call from any thread
    // (main.cpp implements it with PostMessageW).
    std::function<bool(int commandId)> command;
    // Forwards an agent request (method/path/body), returning the response body.
    std::function<std::string(const std::string& method, const std::string& path, const std::string& body)>
        agentRequest;
};

// Starts the loopback HTTP server on 127.0.0.1:port. Returns false if the
// port cannot be bound (e.g. a second controller instance is running).
bool startServer(int port, Callbacks callbacks);

// Closes the listen socket so the accept loop exits.
void stopServer();

} // namespace control
