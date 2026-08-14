module Oauth
  # The two discovery documents an MCP client reads before it can start an
  # OAuth flow: RFC 9728 protected-resource metadata, which says "this resource
  # is guarded by that authorization server", and RFC 8414 authorization-server
  # metadata, which says where its endpoints are and what it supports.
  #
  # Built from the request's own base URL rather than a configured hostname, so
  # the documents are correct on whatever host the app is actually reached at
  # (production, a preview deploy, a tunnel) without a setting to keep in sync.
  class Metadata
    # `mcp` is the access itself; `offline_access` is the client asking for a
    # refresh token, which Claude appends when it sees it advertised here.
    SCOPES = %w[mcp offline_access].freeze
    DEFAULT_SCOPE = SCOPES.join(" ").freeze

    def initialize(base_url)
      @base_url = base_url.to_s.chomp("/")
    end

    def protected_resource
      {
        # Must match the MCP URL the user typed into the client, path included.
        resource: "#{@base_url}/mcp",
        authorization_servers: [ @base_url ],
        scopes_supported: SCOPES,
        bearer_methods_supported: [ "header" ],
        resource_name: "Steelyard",
        resource_documentation: "#{@base_url}/api_tokens"
      }
    end

    def authorization_server
      {
        issuer: @base_url,
        authorization_endpoint: "#{@base_url}/oauth/authorize",
        token_endpoint: "#{@base_url}/oauth/token",
        registration_endpoint: "#{@base_url}/oauth/register",
        scopes_supported: SCOPES,
        response_types_supported: [ "code" ],
        response_modes_supported: [ "query" ],
        grant_types_supported: [ "authorization_code", "refresh_token" ],
        # "none" is what a public client authenticates as, and Claude registers
        # as one; the secret methods are here for an operator who pre-registers
        # a confidential client by hand instead.
        token_endpoint_auth_methods_supported: [ "none", "client_secret_post", "client_secret_basic" ],
        # PKCE is mandatory, not optional -- and has to be advertised so a
        # spec-compliant client can check before it starts.
        code_challenge_methods_supported: [ "S256" ]
      }
    end

    # The challenge that sends an unauthenticated MCP client into the flow: a
    # 401 whose header says where to read the metadata. Without the pointer a
    # client has to guess at well-known paths, and if it guesses wrong the
    # connection just fails.
    def self.challenge_header(base_url)
      resource_metadata = "#{base_url.to_s.chomp("/")}/.well-known/oauth-protected-resource"
      %(Bearer resource_metadata="#{resource_metadata}", scope="#{DEFAULT_SCOPE}")
    end
  end
end
