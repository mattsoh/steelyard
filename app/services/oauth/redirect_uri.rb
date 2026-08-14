module Oauth
  # Which redirect targets a client may register, and which one a given
  # authorization request may be sent to.
  module RedirectUri
    LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

    def self.registerable?(uri)
      parsed = parse(uri)
      return false if parsed.nil? || parsed.fragment.present?

      parsed.scheme == "https" || (parsed.scheme == "http" && loopback?(parsed))
    end

    # Exact match, with one carve-out: a native client (Claude Code is one)
    # listens on whatever loopback port it could get and can't know it at
    # registration time, so RFC 8252 section 7.3 has the authorization server
    # ignore the port for loopback redirects. Everything else -- scheme, host,
    # path -- still has to match exactly.
    def self.permitted?(registered, candidate)
      return false if candidate.blank?

      Array(registered).any? do |uri|
        uri == candidate || loopback_match?(parse(uri), parse(candidate))
      end
    end

    def self.loopback?(parsed) = LOOPBACK_HOSTS.include?(parsed.host)

    def self.loopback_match?(registered, candidate)
      return false if registered.nil? || candidate.nil?
      return false unless loopback?(registered) && loopback?(candidate)

      registered.scheme == candidate.scheme &&
        registered.host == candidate.host &&
        registered.path.to_s == candidate.path.to_s &&
        registered.query.to_s == candidate.query.to_s
    end

    def self.parse(uri)
      URI.parse(uri.to_s)
    rescue URI::InvalidURIError
      nil
    end
  end
end
