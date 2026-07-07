class OrganizationLedger
  # Sentinel transaction_id for the synthetic "before anything happened"
  # cutoff option -- the balance is zero there too, it just isn't attached to
  # a real transaction. Distinguishable from real HCB ids (e.g. "txn_...").
  BEGINNING_ID = "__beginning__".freeze

  ZeroOption = Struct.new(:date, :transaction_id, :index, keyword_init: true) do
    def beginning? = index == -1
  end

  def initialize(client, organization_id)
    @client = client
    @organization_id = organization_id
  end

  # Oldest-first. Declined transactions are excluded entirely -- they never
  # moved money, so they'd corrupt the running balance and can't be matched.
  def transactions
    @transactions ||= Hcb::OrganizationTransactions.new(@client, @organization_id).all
      .map { |t| Hcb::TransactionPresenter.new(t) }
      .reject(&:declined?)
      .reverse
  end

  # Balance in cents after each transaction, aligned with #transactions.
  def running_balance_cents
    @running_balance_cents ||= begin
      total = 0
      transactions.map { |t| total += t.amount_cents }
    end
  end

  # Newest-first. When the balance crossed zero more than once on the same
  # day, only the last crossing that day is offered. The very start of the
  # transaction history -- before anything happened, balance necessarily zero
  # -- is always offered too, as the oldest (last) option.
  def zero_options
    @zero_options ||= begin
      by_date = {}
      running_balance_cents.each_with_index do |balance, i|
        by_date[transactions[i].date] = i if balance.zero?
      end
      crossings = by_date.map { |date, i| ZeroOption.new(date: date, transaction_id: transactions[i].id, index: i) }
      beginning = ZeroOption.new(date: transactions.first&.date, transaction_id: BEGINNING_ID, index: -1)
      (crossings + [ beginning ]).sort_by(&:index).reverse
    end
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

  def transaction_by_id(id)
    index = index_of(id)
    return transactions[index] if index

    raw = @client.transaction(id)
    raw && Hcb::TransactionPresenter.new(raw)
  rescue OAuth2::Error => e
    raise unless e.response.status == 404
    nil
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

  def index_of(id)
    @index_by_id ||= transactions.each_with_index.to_h { |t, i| [ t.id, i ] }
    @index_by_id[id]
  end
end
