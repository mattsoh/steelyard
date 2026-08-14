module Oauth
  # Serves both discovery documents. Clients look for them under
  # /.well-known/..., and some probe a path-suffixed variant matching the MCP
  # endpoint's own path, so the routes point several paths here (see routes.rb).
  class MetadataController < PublicController
    def protected_resource
      render json: metadata.protected_resource
    end

    def authorization_server
      render json: metadata.authorization_server
    end
  end
end
