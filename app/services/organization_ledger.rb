class OrganizationLedger
  # Sentinel transaction_id for the synthetic "before anything happened"
  # cutoff option -- the balance is zero there too, it just isn't attached to
  # a real transaction. Distinguishable from real HCB ids (e.g. "txn_...").
  BEGINNING_ID = "__beginning__".freeze

  # #transaction_by_id's fallback (an id not in the org's drained list, e.g.
  # a hidden-but-matched transaction from before the current view) hits HCB
  # directly per id. Cached long-lived and per-id, unlike the whole-org list
  # cache: a single already-settled transaction doesn't change, and this path
  # gets hit repeatedly for the same handful of ids (matches referencing old
  # transactions) on every unrelated /api/transactions or /api/matches load.
  SINGLE_TRANSACTION_TTL = ENV.fetch("HCB_SINGLE_TRANSACTION_CACHE_TTL", 1.day).to_i.seconds

  ZeroOption = Struct.new(:date, :transaction_id, :index, keyword_init: true) do
    def beginning? = index == -1
  end

  # A leg as the write paths (Matches::Create/Update) see one: an id and an
  # amount, which is all either of them reads off it. Stands in for a full
  # TransactionPresenter there so #write_legs_by_id can answer from the small
  # derived index instead of the whole-org raw JSON -- see #leg_for.
  Leg = Struct.new(:id, :amount_cents, keyword_init: true) do
    def amount = (amount_cents / 100.0).round(2)
  end

  # Named rather than inlined into #transaction_by_id because it also has to be
  # *invalidated* elsewhere: Hcb::OrganizationTransactions#refresh_one! drops
  # this key so a day-old copy can't shadow a transaction the user just asked
  # to re-check.
  #
  # Keyed by organization as well as id, and both are required, so no caller
  # can leave one out. Without the organization, one entry was shared by every
  # request in the app that asked for that id -- and since the fetch behind it
  # is only ever reached for an id an organization's own history *doesn't*
  # contain, that shared entry was a way for one organization's request to be
  # answered with something fetched for another. Version bumped along with the
  # shape so the entries written under the old, unscoped key are never read.
  def self.single_transaction_cache_key(organization_id, id) = "hcb:transaction:#{organization_id}:#{id}:v2"

  def initialize(client, organization_id)
    @client = client
    @organization_id = organization_id
    @hcb_transactions = Hcb::OrganizationTransactions.new(client, organization_id)
  end

  # Oldest-first. Declined transactions are excluded entirely -- they never
  # moved money, so they'd corrupt the running balance and can't be matched.
  def transactions
    @transactions ||= @hcb_transactions.all
      .map { |t| Hcb::TransactionPresenter.new(t) }
      .reject(&:declined?)
      .reverse
  end

  # Balance in cents after each transaction, aligned with #transactions.
  def running_balance_cents
    @running_balance_cents ||= derived_order&.fetch(:balances_cents) || begin
      total = 0
      transactions.map { |t| total += t.amount_cents }
    end
  end

  # Newest-first. When the balance crossed zero more than once on the same
  # day, only the last crossing that day is offered. The very start of the
  # transaction history -- before anything happened, balance necessarily zero
  # -- is always offered too, as the oldest (last) option.
  #
  # Sourced from the drain-time derived index when it's warm, so this doesn't
  # have to Presenter-wrap and running-balance-walk the whole org history on
  # every request that needs the cutoff (e.g. every match creation) -- only
  # the first request after a (re)drain pays that cost.
  def zero_options
    @zero_options ||= (order = derived_order) ? zero_options_from(order) : zero_options_from_transactions
  end

  def effective_cutoff
    return @effective_cutoff if defined?(@effective_cutoff)

    setting = OrganizationSetting.find_by(hcb_organization_id: @organization_id)
    chosen = setting&.zero_balance_transaction_id.presence &&
      zero_options.find { |o| o.transaction_id == setting.zero_balance_transaction_id }
    @effective_cutoff = chosen || zero_options.first
  end

  def cutoff_index = effective_cutoff&.index

  # The matcher's working set: strictly after the zero-point transaction.
  def after_cutoff
    return transactions if cutoff_index.nil?

    transactions.drop(cutoff_index + 1)
  end

  # Ids of #after_cutoff, in the same order, without building a presenter for
  # every transaction in the org's history to get them -- the drain-time
  # derived index already lists ids in exactly #transactions' order. Callers
  # that only need to *name* the working set (Api::TransactionsController,
  # which renders it from pre-serialized fragments) take this instead.
  def after_cutoff_ids
    order = derived_order
    return after_cutoff.map(&:id) unless order
    return order[:ids] if cutoff_index.nil?

    order[:ids].drop(cutoff_index + 1)
  end

  # Response JSON for the given ids, one already-serialized fragment each, in
  # the order asked for. Answered from the drain-time presentation cache where
  # it can be -- an id that isn't part of the drain (a match leg from before
  # the current history) still falls back to fetching and presenting it.
  # Skips ids nothing can resolve, as #transaction_by_id does.
  def transaction_fragments(ids)
    presented = @hcb_transactions.presented
    ids.filter_map { |id| presented&.[](id) || transaction_by_id(id)&.as_json&.to_json }
  end

  # `remote: false` restricts the lookup to what this organization's drain
  # already knows, for callers that run on every request and would rather
  # answer "don't know" than pay a live HCB round trip per unknown id (see
  # Matches::Resync, which skips a match it can't fully resolve anyway).
  def transaction_by_id(id, remote: true)
    raw = @hcb_transactions.find(id)
    return Hcb::TransactionPresenter.new(raw) if raw

    index = index_of(id)
    return transactions[index] if index
    return nil unless remote

    raw = Rails.cache.fetch(self.class.single_transaction_cache_key(@organization_id, id), expires_in: SINGLE_TRANSACTION_TTL) { @client.transaction(id) }
    raw && Hcb::TransactionPresenter.new(raw)
  rescue OAuth2::Error => e
    raise unless e.response.status == 404
    nil
  end
  # Resolves the legs a match is about to be saved with, to the extent needed to
  # validate their direction and sum them: #Leg, not a full presenter.
  #
  # Answered from the drain-time derived index where it can be (one small cache
  # entry, already needed by #classify on the same request) rather than through
  # #transaction_by_id, whose by-id lookup deserializes the organization's
  # entire raw transaction history -- megabytes, for the two or three amounts a
  # match creation actually reads.
  def write_legs_by_id(ids, existing: [])
    existing = existing.to_set
    ids.uniq.index_with { |id| leg_for(id, remote: existing.include?(id)) }
  end

  # How a match relates to a cutoff, given its transaction ids:
  #   :hidden      -- every leg is at or before the cutoff (settled history)
  #   :overlapping -- legs on both sides of the cutoff
  #   :visible     -- everything else
  def classify(transaction_ids, cutoff: cutoff_index)
    return :visible if cutoff.nil?

    positions = transaction_ids.filter_map { |id| index_of(id) }
    return :visible if positions.empty?

    before = positions.any? { |p| p <= cutoff }
    after = positions.any? { |p| p > cutoff }
    if before && after
      :overlapping
    elsif before
      :hidden
    else
      :visible
    end
  end

  private

  # Falls back to the full lookup when the derived index can't answer: it's
  # missing entirely (first request after a drain), it predates amounts_cents
  # (a cache entry written by an older deploy), or the id simply isn't part of
  # this organization's drain -- the last of which is the case #write_legs_by_id
  # exists to reject, and the fallback rejects it too unless the caller said the
  # match already holds it.
  def leg_for(id, remote:)
    amounts = derived_order&.dig(:amounts_cents)
    amount = amounts && amounts[id]
    return Leg.new(id: id, amount_cents: amount) if amount

    transaction_by_id(id, remote: remote)
  end

  def index_of(id)
    fast = derived_order&.dig(:position_by_id, id)
    return fast if fast

    @index_by_id ||= transactions.each_with_index.to_h { |t, i| [ t.id, i ] }
    @index_by_id[id]
  end

  # Memoized nil-or-hash: the derived index Hcb::OrganizationTransactions
  # computes once per drain (see #write_side_caches there). nil means it
  # hasn't been computed yet for the current drain (e.g. first-ever request
  # for this org) -- callers fall back to walking #transactions themselves.
  def derived_order
    return @derived_order if defined?(@derived_order)
    @derived_order = @hcb_transactions.derived
  end

  def zero_options_from(order)
    by_date = {}
    order[:balances_cents].each_with_index do |balance, i|
      by_date[order[:dates][i]] = i if balance.zero?
    end
    crossings = by_date.map { |date, i| ZeroOption.new(date: date, transaction_id: order[:ids][i], index: i) }
    beginning = ZeroOption.new(date: order[:dates].first, transaction_id: BEGINNING_ID, index: -1)
    (crossings + [ beginning ]).sort_by(&:index).reverse
  end

  def zero_options_from_transactions
    by_date = {}
    running_balance_cents.each_with_index do |balance, i|
      by_date[transactions[i].date] = i if balance.zero?
    end
    crossings = by_date.map { |date, i| ZeroOption.new(date: date, transaction_id: transactions[i].id, index: i) }
    beginning = ZeroOption.new(date: transactions.first&.date, transaction_id: BEGINNING_ID, index: -1)
    (crossings + [ beginning ]).sort_by(&:index).reverse
  end
end
