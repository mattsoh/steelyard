# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # OAuth: an authorization code is a bearer credential until it's redeemed, and
  # :token above doesn't match it. code_verifier is the PKCE secret proving the
  # redemption is the same client that started the flow -- logging the pair
  # together is enough to complete somebody else's flow from the log.
  :code, :code_verifier
]
