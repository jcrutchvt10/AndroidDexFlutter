package com.rewritedex.nativeagent

import org.json.JSONObject

/**
 * Uniform HTTP response used by the agent HTTP server. Carries a content type
 * so binary payloads (app-icon PNGs) and JSON can share the same write path.
 */
data class AgentResponse(
    val status: Int,
    val contentType: String,
    val body: ByteArray,
) {
    companion object {
        fun json(status: Int, body: JSONObject): AgentResponse =
            AgentResponse(status, "application/json", body.toString().toByteArray(Charsets.UTF_8))

        fun ok(body: JSONObject): AgentResponse = json(200, body)

        fun png(bytes: ByteArray): AgentResponse =
            AgentResponse(200, "image/png", bytes)

        fun error(status: Int, message: String, code: Int = status): AgentResponse {
            val body = JSONObject()
                .put("ok", false)
                .put("error", message)
                .put("code", code)
            return json(status, body)
        }

        fun notFound(): AgentResponse =
            error(404, "not found")
    }
}
