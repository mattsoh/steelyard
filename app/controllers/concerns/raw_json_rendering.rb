# Response assembly for the two endpoints whose rows come out of the drain
# caches already serialized (see Hcb::OrganizationTransactions#presented).
#
# Those fragments only need to be *nested* in a response, and parsing them
# back into Ruby objects so that #to_json can generate the identical bytes
# again is the single most expensive thing a warm /api/transactions or
# /api/ledger would otherwise do. So the object around them is built as a
# string instead. Everything passed through here is either a fragment that
# came from the cache or a value run through #to_json, so the result is
# well-formed JSON by construction rather than by escaping.
module RawJsonRendering
  extend ActiveSupport::Concern

  private

  # Builds a JSON object out of values that are already JSON.
  def json_object(fields)
    "{#{fields.map { |key, raw_json| "#{key.to_s.to_json}:#{raw_json}" }.join(',')}}"
  end

  # Adds fields to an already-serialized JSON object, again without parsing
  # it. Every fragment is a non-empty `{...}` (TransactionPresenter#as_json
  # always has keys), so the extras go in just inside the closing brace.
  def json_object_with(fragment, **extra)
    "#{fragment.chomp('}')},#{extra.map { |key, value| "#{key.to_s.to_json}:#{value.to_json}" }.join(',')}}"
  end
end
