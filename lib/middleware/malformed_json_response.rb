module Middleware
  # Answers a request whose body claims to be JSON and isn't.
  #
  # Rails parses that body lazily, inside the controller, and the ParseError it
  # raises comes out of the instrumentation wrapped around every action --
  # outside the chain `rescue_from` can reach, so no controller can catch it.
  # Left alone it escapes into the error-page renderer, which re-reads the same
  # unparseable body and fails again, and a client that sent one broken byte
  # gets a bare 500 instead of "your JSON is broken". The bottom of the
  # middleware stack is the only place that sees the exception with no
  # controller left to render it.
  class MalformedJsonResponse
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue ActionDispatch::Http::Parameters::ParseError
      [ 400, { "content-type" => "application/json; charset=utf-8" }, [ body_for(env) ] ]
    end

    private

    # MCP clients speak JSON-RPC and nothing else -- an error envelope they
    # can't parse reads to them as a dead server rather than as a bad request.
    def body_for(env)
      return Mcp::Server.parse_error.to_json if env["PATH_INFO"] == "/mcp"

      { error: "Request body is not valid JSON." }.to_json
    end
  end
end
