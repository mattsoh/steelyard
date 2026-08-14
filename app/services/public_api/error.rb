module PublicApi
  # A failure with an answer the caller is meant to read: a missing
  # organization, a role that can't match, a transaction id that isn't real.
  # Carries the HTTP status the REST surface should use; the MCP surface turns
  # the same object into a tool result flagged `isError` (see Mcp::Server).
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: :unprocessable_entity)
      super(message)
      @status = status
    end
  end
end
