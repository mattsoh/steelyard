# Be sure to restart your server when you modify this file.
#
# The backstop under the escaping, not a replacement for it. Every list in this
# app is built by writing HTML strings into `innerHTML` (see
# app/assets/javascripts/legacy/), from data that came out of HCB -- memos,
# comment bodies, member names -- none of which this app controls the contents
# of. Those writes go through `escapeHtml`, and that is what actually keeps them
# safe; this is what limits the damage on the day one of them doesn't.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self
    policy.img_src     :self, :data
    # Only ever this app: the frontend talks to its own /api routes and nothing
    # else, so an injected script has nowhere to send what it reads.
    policy.connect_src :self
    policy.object_src  :none
    policy.base_uri    :self
    # Nothing here is meant to be embedded, and the OAuth consent screen
    # especially so -- an "Approve" button someone else can frame and dress up
    # is the clickjacking version of the phishing this app already guards
    # against by naming the client and its redirect target.
    policy.frame_ancestors :none

    # Scripts are served from this app and carry a per-response nonce (see
    # below), so an injected `<script>` -- which by definition can't know the
    # nonce -- doesn't run.
    policy.script_src :self

    # 'unsafe_inline' deliberately, and only for styles: a nonce can't cover a
    # `style` attribute in markup, and there are several in play that aren't
    # this app's to change -- Turbo's injected progress bar, the static
    # public/*.html error pages that serve when the app can't boot. Inline CSS
    # is a far weaker vector than inline script, and the directives above are
    # what this policy is for.
    policy.style_src :self, :unsafe_inline
  end

  # A fresh nonce per response rather than one derived from the session id: the
  # value is only useful to an attacker who can read it out of a response they
  # can already read, but it costs nothing to make it unguessable and there is
  # no page caching here that would need it to be stable.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
