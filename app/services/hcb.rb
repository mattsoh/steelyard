module Hcb
  class TokenExpiredError < StandardError; end

  # Every HCB request this app makes goes through one shared OAuth2::Client,
  # and therefore one shared keep-alive connection pool.
  #
  # The reason is the handshake. Faraday's default net_http adapter opens a
  # fresh TCP+TLS connection for every request and closes it again, and
  # against hcb.hackclub.com that costs ~270ms before HCB has done any work
  # at all -- measured ~400ms for a request on a cold connection against
  # ~140ms for the same request on a warm one. A #drain pays that per page,
  # so a full-history walk of a few thousand transactions spends tens of
  # seconds on handshakes alone. Nothing about the requests themselves
  # changes here; we just stop throwing the socket away between them.
  #
  # It has to be *one* client for that to work: OAuth2::Client memoizes its
  # Faraday connection, and the connection is what owns the pool, so a client
  # built per request (which is what Hcb::Client used to do) reuses nothing --
  # sharing the client is the whole mechanism, not an allocation micro-tune.
  #
  # Thread safety is net-http-persistent's: it keys its pool by thread, so
  # concurrent Puma threads -- and the fan-out in
  # OrganizationTransactions#parallel_pages -- get their own sockets rather
  # than sharing one, which is also why POOL_SIZE has to cover both.
  POOL_SIZE = ENV.fetch("HCB_HTTP_POOL_SIZE") { ENV.fetch("RAILS_MAX_THREADS", 8).to_i + 8 }.to_i

  # A drain page against a large organization is genuinely slow on HCB's side
  # (see OrganizationTransactions::MAX_CONCURRENT_PAGES for why), so the read
  # timeout is generous. The point of having one at all is that a hung request
  # shouldn't pin a Puma thread indefinitely.
  OPEN_TIMEOUT = ENV.fetch("HCB_HTTP_OPEN_TIMEOUT", 5).to_i
  READ_TIMEOUT = ENV.fetch("HCB_HTTP_READ_TIMEOUT", 30).to_i

  MUTEX = Mutex.new

  def self.oauth_client
    # Double-checked so the steady state is a bare read rather than a lock on
    # every HCB request.
    @oauth_client || MUTEX.synchronize { @oauth_client ||= build_oauth_client }
  end

  def self.build_oauth_client
    OAuth2::Client.new(
      ENV.fetch("HCB_OAUTH_CLIENT_ID"),
      ENV.fetch("HCB_OAUTH_CLIENT_SECRET"),
      site: ENV.fetch("HCB_API_BASE_URL", "https://hcb.hackclub.com"),
      authorize_url: "/api/v4/oauth/authorize",
      token_url: "/api/v4/oauth/token",
      connection_opts: {
        request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }
      },
      connection_build: lambda { |builder|
        # Supplying connection_build replaces oauth2's default stack, so the
        # form encoder it relies on for token POSTs has to be re-declared here.
        builder.request(:url_encoded)
        builder.adapter(:net_http_persistent, pool_size: POOL_SIZE)
      }
    )
  end
  private_class_method :build_oauth_client
end
