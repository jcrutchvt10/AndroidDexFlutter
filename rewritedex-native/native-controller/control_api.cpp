#include "control_api.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <atomic>
#include <algorithm>
#include <cctype>
#include <sstream>
#include <vector>

#include "json.h"

namespace control {
namespace {

constexpr int kMaxRequestBytes = 64 * 1024;

// Guard for the callbacks, which are installed once at startup and read by the
// accept loop. CRITICAL_SECTION is used instead of std::mutex because the
// toolchain's win32-threads model does not ship std::mutex/std::thread.
CRITICAL_SECTION g_callbacksLock;
bool g_lockInitialized = false;
std::atomic_bool g_running{false};
std::atomic<SOCKET> g_listenSocket{INVALID_SOCKET};
std::atomic<HANDLE> g_serverThread{nullptr};
Callbacks g_callbacks;

Callbacks snapshotCallbacks() {
    Callbacks callbacks;
    EnterCriticalSection(&g_callbacksLock);
    callbacks = g_callbacks;
    LeaveCriticalSection(&g_callbacksLock);
    return callbacks;
}

std::string readRequest(SOCKET connection, std::string* pathOut, std::string* methodOut, std::string* bodyOut) {
    // Read until the end of headers, then honour Content-Length for the body.
    std::string request;
    char chunk[2048];
    size_t headerEnd = std::string::npos;
    while (request.size() < kMaxRequestBytes && headerEnd == std::string::npos) {
        const int received = recv(connection, chunk, sizeof(chunk), 0);
        if (received <= 0) return "read failed";
        request.append(chunk, static_cast<size_t>(received));
        headerEnd = request.find("\r\n\r\n");
    }
    if (headerEnd == std::string::npos) return "headers too large";
    const std::string headers = request.substr(0, headerEnd);
    size_t contentLength = 0;
    {
        // Walk the header lines (skipping the request line) looking for
        // Content-Length. Unknown or malformed values default to zero.
        std::string::size_type start = headers.find("\r\n");
        while (start != std::string::npos) {
            const std::string::size_type end = headers.find("\r\n", start + 2);
            if (end == std::string::npos) break;
            const std::string line = headers.substr(start + 2, end - (start + 2));
            const size_t colon = line.find(':');
            if (colon != std::string::npos) {
                std::string name = line.substr(0, colon);
                std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) {
                    return static_cast<char>(std::tolower(c));
                });
                if (name == "content-length") {
                    try {
                        contentLength = static_cast<size_t>(std::max(0, std::stoi(line.substr(colon + 1))));
                    } catch (...) {
                        contentLength = 0;
                    }
                }
            }
            start = end;
        }
    }

    const size_t firstSpace = request.find(' ');
    const size_t secondSpace = firstSpace == std::string::npos ? std::string::npos : request.find(' ', firstSpace + 1);
    if (firstSpace == std::string::npos || secondSpace == std::string::npos) return "malformed request line";
    *methodOut = request.substr(0, firstSpace);
    *pathOut = request.substr(firstSpace + 1, secondSpace - firstSpace - 1);

    while (request.size() < headerEnd + 4 + contentLength) {
        const int received = recv(connection, chunk, sizeof(chunk), 0);
        if (received <= 0) break;
        request.append(chunk, static_cast<size_t>(received));
    }
    *bodyOut = request.substr(headerEnd + 4, contentLength);
    return {};
}

void writeResponse(SOCKET connection, int statusCode, const std::string& body) {
    std::ostringstream response;
    response << "HTTP/1.1 " << statusCode
             << (statusCode == 200 ? " OK" : statusCode == 404 ? " Not Found" : " Bad Request")
             << "\r\nContent-Type: application/json\r\n"
             << "Content-Length: " << body.size() << "\r\n"
             << "Cache-Control: no-store\r\n"
             << "Connection: close\r\n\r\n"
             << body;
    const std::string outbound = response.str();
    size_t sent = 0;
    while (sent < outbound.size()) {
        const int count = send(
            connection, outbound.data() + sent,
            static_cast<int>(std::min<size_t>(outbound.size() - sent, INT_MAX)), 0);
        if (count <= 0) break;
        sent += static_cast<size_t>(count);
    }
}

void handleConnection(SOCKET connection) {
    std::string method;
    std::string path;
    std::string body;
    const std::string error = readRequest(connection, &path, &method, &body);
    if (!error.empty()) {
        writeResponse(connection, 400, "{\"ok\":false,\"error\":" + json::quote(error) + "}");
        return;
    }

    Callbacks callbacks = snapshotCallbacks();

    std::string responseBody;
    if (method == "GET" && path == "/control/status") {
        responseBody = callbacks.statusJson ? callbacks.statusJson() : "{\"ok\":false}";
        writeResponse(connection, 200, responseBody);
        return;
    }
    if (method == "POST" && path == "/control/command") {
        int commandId = 0;
        try {
            commandId = json::parse(body).at("command").integer(0);
        } catch (...) {
            writeResponse(connection, 400, "{\"ok\":false,\"error\":\"invalid command body\"}");
            return;
        }
        const bool executed = callbacks.command && callbacks.command(commandId);
        writeResponse(
            connection, 200,
            std::string("{\"ok\":") + (executed ? "true" : "false") + "}");
        return;
    }
    if (callbacks.agentRequest) {
        responseBody = callbacks.agentRequest(method, path, body);
        writeResponse(connection, 200, responseBody);
        return;
    }
    writeResponse(connection, 404, "{\"ok\":false,\"error\":\"not found\"}");
}

DWORD WINAPI serverThreadProc(LPVOID) {
    while (g_running) {
        SOCKET connection = accept(g_listenSocket.load(), nullptr, nullptr);
        if (connection == INVALID_SOCKET) {
            const int error = WSAGetLastError();
            if (!g_running || error == WSAEINTR || error == WSAECONNRESET || error == WSAEINVAL) {
                // Normal shutdown or a spurious wakeup; keep polling g_running.
                continue;
            }
            break;
        }
        DWORD receiveTimeout = 8000;
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&receiveTimeout), sizeof(receiveTimeout));
        handleConnection(connection);
        closesocket(connection);
    }
    return 0;
}

} // namespace

bool startServer(int port, Callbacks callbacks) {
    if (!g_lockInitialized) {
        InitializeCriticalSection(&g_callbacksLock);
        g_lockInitialized = true;
    }
    EnterCriticalSection(&g_callbacksLock);
    g_callbacks = std::move(callbacks);
    LeaveCriticalSection(&g_callbacksLock);
    if (g_running) return true;

    SOCKET listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSocket == INVALID_SOCKET) return false;
    BOOL reuse = TRUE;
    setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<unsigned short>(port));
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (bind(listenSocket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        closesocket(listenSocket);
        return false;
    }
    if (listen(listenSocket, 8) != 0) {
        closesocket(listenSocket);
        return false;
    }
    g_listenSocket.store(listenSocket);
    g_running.store(true);
    g_serverThread.store(CreateThread(nullptr, 0, serverThreadProc, nullptr, 0, nullptr));
    if (!g_serverThread.load()) {
        g_running.store(false);
        closesocket(listenSocket);
        return false;
    }
    return true;
}

void stopServer() {
    g_running.store(false);
    const SOCKET listenSocket = g_listenSocket.exchange(INVALID_SOCKET);
    if (listenSocket != INVALID_SOCKET) closesocket(listenSocket);
    const HANDLE thread = g_serverThread.exchange(nullptr);
    if (thread && WaitForSingleObject(thread, 2000) == WAIT_TIMEOUT) {
        CloseHandle(thread);
    } else if (thread) {
        CloseHandle(thread);
    }
}

} // namespace control
