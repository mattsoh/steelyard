module Hcb
  # Normalizes a raw HCB v4 transaction JSON hash into the field shape the
  # legacy frontend (app.js/ledger.js/details.js) already knows how to render.
  # A few legacy fields (comments, user_name) have no confirmed HCB
  # equivalent under the organizations:read/ledgers:read scopes this app is
  # limited to, so they're left blank rather than guessed.
  class TransactionPresenter
    def initialize(raw)
      @raw = raw
    end

    def id = @raw["id"]
    def date = @raw["date"]
    def memo = @raw["memo"]
    def amount_cents = @raw["amount_cents"] || 0
    def amount = (amount_cents / 100.0).round(2)
    def direction = amount.negative? ? "out" : "in"
    def declined? = !!@raw["declined"]
    def tags = Array(@raw["tags"]).join(", ")
    def comments = ""
    def user_name = ""
    def category_label
      @raw["code"].to_s.tr("_-", "  ").squish.capitalize
    end

    def as_json(*)
      {
        id: id, date: date, memo: memo, amount: amount, direction: direction,
        tags: tags, comments: comments, user_name: user_name, category_label: category_label
      }
    end
  end
end
