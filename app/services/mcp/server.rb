module Mcp
  # The Model Context Protocol, spoken over one POST endpoint (see
  # McpController). MCP is JSON-RPC 2.0 with a fixed handshake and a small set
  # of methods; this handles one message and returns the reply, or nil when the
  # message was a notification and the protocol says there is no reply.
  #
  # Deliberately stateless: no session ids, nothing held between requests. The
  # only state a Steelyard MCP session could hold is the token's identity,
  # which arrives on every request anyway -- so a client can reconnect, retry,
  # or run several conversations against the same token with nothing to resume.
  class Server
    # What this server implements. A client that asks for one of these gets it
    # back verbatim; a client asking for anything else is answered with our
    # newest, which is what the spec calls for.
    PROTOCOL_VERSION = "2025-06-18".freeze
    SUPPORTED_PROTOCOL_VERSIONS = [ PROTOCOL_VERSION, "2025-03-26", "2024-11-05" ].freeze

    SERVER_INFO = { name: "steelyard", title: "Steelyard", version: "1" }.freeze

    # Read by the model before it calls anything, so it's worth saying what the
    # domain *is* -- without this, "match" and "discrepancy" are guesses.
    INSTRUCTIONS = <<~TEXT.freeze
      Steelyard reconciles an HCB organization's incoming transactions against its
      outgoing ones: money arrives (a donation, a transfer in) and later leaves for
      the thing it was meant for, and a "match" records which outgoing transactions
      account for which incoming ones. A match whose sides sum to zero is balanced;
      anything else is a discrepancy somebody needs to explain.

      Only transactions after the organization's zero-balance cutoff are in play --
      everything before it is settled history. Start with get_reconciliation_summary
      to see what's outstanding, then list_transactions with status="unmatched" to
      find the work. Matching is collaborative and immediately visible to everyone
      else working on the organization, so confirm a match when the evidence is
      there, not to tidy up the list.
    TEXT

    # JSON-RPC 2.0 error codes.
    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602

    def self.parse_error
      { jsonrpc: "2.0", id: nil, error: { code: PARSE_ERROR, message: "Request body is not valid JSON." } }
    end

    def initialize(user)
      @user = user
    end

    def handle(message)
      return error(nil, INVALID_REQUEST, "A JSON-RPC message must be an object.") unless message.is_a?(Hash)

      id = message["id"]
      method = message["method"].to_s
      params = message["params"].is_a?(Hash) ? message["params"] : {}

      # No id means a notification: the client isn't listening for an answer,
      # and JSON-RPC forbids sending one even when the method is unknown.
      return nil if id.nil?

      case method
      when "initialize" then result(id, initialize_result(params))
      when "ping" then result(id, {})
      when "tools/list" then result(id, { tools: Tools.definitions })
      when "tools/call" then call_tool(id, params)
      else error(id, METHOD_NOT_FOUND, "Unknown method #{method.presence || "(missing)"}.")
      end
    end

    private

    def initialize_result(params)
      requested = params["protocolVersion"].to_s
      {
        protocolVersion: SUPPORTED_PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSION,
        # No listChanged: the tool list is compiled into the app, so it can't
        # change under a connected client.
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS
      }
    end

    def call_tool(id, params)
      tool = Tools.find(params["name"])
      return error(id, INVALID_PARAMS, "Unknown tool #{params["name"].inspect}.") unless tool

      arguments = params["arguments"].is_a?(Hash) ? params["arguments"] : {}
      result(id, tool_result(tool.handler.call(operations, arguments)))
    rescue PublicApi::Error => e
      # An error the caller is meant to read and act on (wrong organization, a
      # role that can't match, a leg that isn't a real transaction) is a tool
      # *result* flagged as an error, not a protocol error -- that way the model
      # sees the message and can correct itself, instead of the client
      # swallowing it as a transport failure.
      result(id, tool_result({ error: e.message }, is_error: true))
    end

    # Content is JSON as text rather than a `structuredContent` payload: every
    # MCP client renders text content, and the tools have no output schema to
    # validate a structured one against.
    def tool_result(payload, is_error: false)
      { content: [ { type: "text", text: JSON.pretty_generate(payload) } ], isError: is_error }
    end

    def operations = @operations ||= PublicApi::Operations.new(@user)

    def result(id, value) = { jsonrpc: "2.0", id: id, result: value }

    def error(id, code, message) = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end
end
