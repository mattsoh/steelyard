# MCP's streamable-HTTP transport, on a single endpoint: the client POSTs one
# JSON-RPC message (or, on the older protocol revision, a batch of them) and
# reads the reply out of the response body. The optional server-to-client SSE
# stream isn't offered -- nothing here pushes -- so GET and DELETE answer 405,
# which is what the transport spec says a server without a stream should do.
#
# Authenticated by the same bearer tokens as the v1 REST API (see
# TokenAuthenticated), and bounded by the same HCB membership and roles: an MCP
# client can do exactly what its token's owner could do in the web app.
class McpController < ApplicationController
  include TokenAuthenticated

  # Answered without a token, so a client probing the endpoint gets the honest
  # "this verb isn't supported here" rather than a misleading 401.
  skip_before_action :authenticate_token!, only: :unsupported

  def handle
    payload = parse_payload
    return render json: Mcp::Server.parse_error, status: :bad_request if payload == :unparseable

    server = Mcp::Server.new(current_user)
    batch = payload.is_a?(Array)
    replies = (batch ? payload : [ payload ]).filter_map { |message| server.handle(message) }

    # Nothing to reply to (a batch of notifications, or the lone
    # `notifications/initialized` that follows every handshake). 202 with no
    # body is the transport's way of saying "received, nothing to say back".
    return head :accepted if replies.empty?

    render json: batch ? replies : replies.first
  end

  def unsupported
    response.set_header("Allow", "POST")
    render json: {
      jsonrpc: "2.0",
      id: nil,
      error: { code: -32600, message: "This MCP endpoint only accepts POST; it does not offer a server-to-client stream." }
    }, status: :method_not_allowed
  end

  private

  # Read from the raw body rather than `params`: a JSON-RPC message has its own
  # `params` member, and Rails' parameter wrapping would bury it under the
  # request's. Batches arrive as a top-level array, which `params` can't
  # represent at all.
  def parse_payload
    parsed = JSON.parse(request.raw_post.to_s)
    parsed.is_a?(Array) || parsed.is_a?(Hash) ? parsed : :unparseable
  rescue JSON::ParserError
    :unparseable
  end

  # The 401 is the start of the OAuth handshake, not just a rejection: the
  # header tells a client where to read this server's metadata, which is how a
  # Claude connector discovers it can log the user in rather than giving up.
  # Claude also refreshes an expired token reactively off this same response, so
  # the pointer has to be here every time, not only on the first request.
  def render_token_error(message, status)
    response.set_header("WWW-Authenticate", Oauth::Metadata.challenge_header(request.base_url)) if status == :unauthorized
    render json: { jsonrpc: "2.0", id: nil, error: { code: -32001, message: message } }, status: status
  end
end
