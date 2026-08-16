module Hcb
  # Normalizes a raw HCB v4 transaction JSON hash into the field shape the
  # legacy frontend (app.js/ledger.js/details.js) already knows how to render.
  # Comments aren't included here -- HCB's comments endpoint is per-transaction,
  # so details.js fetches them on demand (via Api::CommentsController) only
  # when the detail modal for a transaction is opened, rather than paying for
  # one extra API call per row up front. `user_name` is only populated for
  # transaction types that
  # carry an internal HCB "sender"/"submitter" (ACH transfers, checks,
  # disbursements, Wise transfers, card charges, check deposits) -- see
  # app/views/api/v4/transactions/*.json.jbuilder in hackclub/hcb. Donations
  # and invoices are paid by external, non-HCB-account parties, so they have
  # no user to attribute.
  class TransactionPresenter
    # HCB's `code` is the numeric HcbCode type segment (e.g. "HCB-200-123" ->
    # "200"), not a human label. See TransactionGroupingEngine::Calculate::HcbCode
    # in hackclub/hcb for the authoritative list of codes.
    CATEGORY_NAMES = {
      "000" => "Uncategorized",
      "100" => "Invoice",
      "200" => "Donation",
      "201" => "Partner donation",
      "300" => "ACH transfer",
      "310" => "Wire",
      "350" => "PayPal transfer",
      "360" => "Wise transfer",
      "400" => "Check",
      "401" => "Increase check",
      "402" => "Check deposit",
      "500" => "Outgoing disbursement",
      "550" => "Incoming disbursement",
      "600" => "Stripe card",
      "601" => "Stripe force capture",
      "610" => "Stripe service fee",
      "700" => "Bank fee",
      "701" => "Incoming bank fee",
      "702" => "Fee revenue",
      "710" => "Expense payout",
      "712" => "Payout holding",
      "900" => "Outgoing fee reimbursement"
    }.freeze

    # Per HCB code type, the field that marks when it was actually sent --
    # i.e. when the sender initiated it, not when it settled/cleared. HCB's
    # own top-level `date` is the opposite (Hcb::Code#date in hackclub/hcb
    # prefers the *settled* CanonicalTransaction's date over the pending
    # one), so this app-specific choice has to be reconstructed from the
    # per-type sub-object HCB nests under each transaction. `check_deposit`
    # and `expense_payout` have no sent-side timestamp in the v4 API at all
    # (their partials don't call `object_shape`, which is what supplies the
    # default `created_at`) -- those fall through to the settled `date`.
    # Where each type files its answer to "what is this for?", first match wins.
    # Every type that moves money on someone's instruction collects one, under
    # its own name: transfers, checks and wires ask for it up front
    # (`payment_for`), a disbursement carries it as the transfer's own memo, an
    # invoice's is the line item it billed for, and a donation's is whatever the
    # donor typed alongside the money.
    #
    # Worth its own field rather than leaving it to #memo, because for an
    # *incoming* disbursement HCB rewrites the transaction memo to "Transfer
    # from <org>" -- the sender's stated purpose survives only on the nested
    # transfer object, which is exactly the copy the receiving org is reading.
    REASON_PATHS = [
      %w[ach_transfer payment_for],
      %w[check payment_for],
      %w[wire_transfer payment_for],
      %w[wise_transfer payment_for],
      %w[transfer memo],
      %w[invoice description],
      %w[donation message]
    ].freeze

    # Where a type tracks its own progress, separately from the
    # transaction-level pending/declined/reversed flags: a check still being
    # printed, a wire that was returned, a transfer not yet deposited. Named
    # `status` on some types and `state` on others.
    STATUS_PATHS = [
      %w[transfer status],
      %w[check status],
      %w[check_deposit status],
      %w[wire_transfer state],
      %w[wise_transfer state]
    ].freeze

    SENT_AT_PATHS = [
      %w[donation donated_at],
      %w[ach_transfer created_at],
      %w[check created_at],
      %w[wise_transfer sent_at],
      %w[wise_transfer created_at],
      %w[wire_transfer created_at],
      %w[transfer created_at],
      %w[invoice sent_at],
      %w[card_charge spent_at]
    ].freeze

    def initialize(raw)
      @raw = raw
    end

    def id = @raw["id"]
    def date = sent_at&.to_date&.iso8601 || @raw["date"]
    # HCB's own settled/cleared date, kept alongside #date (which now shows
    # when the transaction was sent) so callers that want both can have them.
    def settled_date = @raw["date"]
    def memo = @raw["memo"]
    def amount_cents = @raw["amount_cents"] || 0
    def amount = (amount_cents / 100.0).round(2)
    def direction = amount.negative? ? "out" : "in"
    def pending? = !!@raw["pending"]
    def declined? = !!@raw["declined"]
    def reversed? = !!@raw["reversed"]
    def missing_receipt? = !!@raw["missing_receipt"]
    def lost_receipt? = !!@raw["lost_receipt"]
    def tags = Array(@raw["tags"]).join(", ")
    def user_name
      @raw.dig("ach_transfer", "sender", "name") ||
        @raw.dig("check", "sender", "name") ||
        @raw.dig("transfer", "sender", "name") ||
        @raw.dig("wire_transfer", "sender", "name") ||
        @raw.dig("wise_transfer", "sender", "name") ||
        @raw.dig("card_charge", "card", "user", "name") ||
        @raw.dig("check_deposit", "submitter", "name") ||
        ""
    end
    # The bare HCB code ("500"), alongside the human #category_label built from
    # it. Callers that need to *branch* on the type -- rather than show it to
    # someone -- would otherwise have to parse the label's trailing "(500)".
    def code = @raw["code"].to_s

    def category_label
      return "" if code.blank?

      name = CATEGORY_NAMES.fetch(code) { code.tr("_-", "  ").squish.capitalize }
      "#{name} (#{code})"
    end

    # Counterparty on the other side of the money -- who's being paid, or who
    # sent it in, when that isn't already covered by #user_name (an internal
    # HCB user). Distinct from #user_name: e.g. an ACH transfer's #user_name
    # is the HCB user who requested it, while #recipient_name is the external
    # bank account it was sent to.
    def recipient_name
      @raw.dig("donation", "donor", "name") ||
        @raw.dig("ach_transfer", "recipient_name") ||
        @raw.dig("check", "recipient_name") ||
        @raw.dig("wire_transfer", "recipient_name") ||
        @raw.dig("wise_transfer", "recipient_name") ||
        @raw.dig("invoice", "sponsor", "name") ||
        @raw.dig("card_charge", "merchant", "smart_name") ||
        @raw.dig("card_charge", "merchant", "name") ||
        transfer_counterparty
    end

    # See REASON_PATHS. Blank rather than nil isn't hypothetical here -- HCB
    # returns "" for a `payment_for` nobody filled in -- so this can't be a
    # plain `||` chain, which would stop at the empty one.
    def reason = REASON_PATHS.filter_map { |path| @raw.dig(*path).presence }.first

    # See STATUS_PATHS. Underscored in the API ("in_transit"); read as words.
    def status_label = STATUS_PATHS.filter_map { |path| @raw.dig(*path).presence }.first&.tr("_", " ")&.capitalize

    def decline_reason = @raw.dig("card_charge", "decline_reason")

    # Wise is the one type whose failures come back with an explanation
    # attached -- nothing else in v4 has an equivalent, and #status_label alone
    # would only say "Returned".
    def return_reason = @raw.dig("wise_transfer", "return_reason")

    def as_json(*)
      {
        id: id, date: date, settled_date: settled_date, memo: memo, amount: amount,
        direction: direction, tags: tags, user_name: user_name, code: code, category_label: category_label,
        recipient_name: recipient_name, reason: reason, pending: pending?, declined: declined?,
        reversed: reversed?, missing_receipt: missing_receipt?, lost_receipt: lost_receipt?,
        status_label: status_label, decline_reason: decline_reason, return_reason: return_reason
      }
    end

    private

    # A disbursement's counterparty is the organization at the other end, which
    # side depending on which way the money went -- v4 puts both `from` and `to`
    # on both copies of the transfer. Without this a transfer is the one type
    # whose detail view names nobody at all: its `sender` is the HCB user who
    # requested it (already #user_name), and there's no recipient_name field.
    def transfer_counterparty
      transfer = @raw["transfer"]
      return nil if transfer.blank?

      direction == "out" ? transfer.dig("to", "name") : transfer.dig("from", "name")
    end

    def sent_at
      _key, raw_value = SENT_AT_PATHS.map { |type, field| [ type, @raw.dig(type, field) ] }.find { |_, v| v }
      raw_value && Time.iso8601(raw_value)
    rescue ArgumentError
      nil
    end
  end
end
