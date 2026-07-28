#pragma once

#include <string>

namespace opik {

// Sends metadata-only traces for host-to-Android agent requests. The API key
// and workspace are read from the process environment and never included in
// trace payloads or the APK.
void trackAgentRequest(
    const std::string& method,
    const std::string& path,
    int statusCode,
    long long latencyMs);

} // namespace opik
