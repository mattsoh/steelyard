# Stands in for Hcb.oauth_client so a test can log a user in through the app's
# own callback -- session, return_to and all -- instead of reaching past it.
class FakeHcbOauth
  Response = Struct.new(:body)

  class Token
    attr_reader :token, :refresh_token, :expires_at

    def initialize(identity)
      @identity = identity
      @token = "hcb-access-token"
      @refresh_token = "hcb-refresh-token"
      @expires_at = 1.hour.from_now.to_i
    end

    # The callback reads the logged-in user's identity straight off the token.
    def get(_path) = Response.new(@identity.to_json)
  end

  class AuthCode
    def initialize(identity)
      @identity = identity
    end

    def authorize_url(**) = "https://hcb.test/api/v4/oauth/authorize"

    def get_token(_code, **) = Token.new(@identity)
  end

  def initialize(identity)
    @identity = identity
  end

  def auth_code = AuthCode.new(@identity)
end
