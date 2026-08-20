# Stands in for Hcb::Client in tests so nothing hits the real HCB API.
# Construct with canned responses for whichever methods a given test exercises.
class FakeHcbClient
  attr_reader :transactions_calls, :user_id

  # `comments` is keyed by transaction id, matching HCB's per-transaction
  # comments endpoint; anything not listed simply has none.
  # `foreign_transactions` are fetchable by id but never appear in this
  # organization's paged list -- HCB answers a single-transaction request for
  # anything the asking user can see, including another organization they
  # belong to. That gap between "fetchable" and "ours" is what
  # OrganizationLedger#write_legs_by_id exists to close.
  def initialize(transactions: [], members: [], user: {}, organizations: [], user_id: nil, comments: {}, foreign_transactions: [])
    @transactions = transactions
    @foreign_transactions = foreign_transactions
    @members = members
    @user = user
    @organizations = organizations
    @transactions_calls = 0
    @user_id = user_id
    @comments = comments
    # A redrain fetches the pages of its safety-overlap window concurrently
    # (Hcb::OrganizationTransactions#parallel_pages), so the call counter these
    # tests assert on is incremented from several threads at once.
    @mutex = Mutex.new
  end

  def user = @user
  def organizations = { "data" => @organizations }

  # Prepends newly-"arrived" transactions (newest-first, matching HCB's own
  # ordering) so tests can simulate activity happening between two drains.
  def add_transactions(new_transactions)
    @transactions = new_transactions + @transactions
  end

  # Drops a transaction HCB no longer returns, so tests can simulate the
  # baseline diverging from HCB's list in a way that shifts every position
  # after it -- which is what an incremental redrain's tiling check has to
  # notice rather than splice around.
  def remove_transaction(id)
    @transactions = @transactions.reject { |t| t["id"] == id }
  end

  # Changes an already-"seen" transaction in place (same id, new attributes) so
  # tests can simulate HCB declining one, or correcting its amount, after a
  # drain has already cached it.
  def update_transaction(id, attributes)
    @transactions = @transactions.map { |t| t["id"] == id ? t.merge(attributes) : t }
  end

  def organization(_id, expand: [])
    { "id" => "org_1", "name" => "Test Org", "users" => @members }
  end

  def transactions(_organization_id, after: nil, limit: 100, filters: {})
    @mutex.synchronize { @transactions_calls += 1 }

    results = @transactions
    search = filters[:search] || filters["search"]
    if search.present?
      needle = search.to_s.downcase
      results = results.select do |transaction|
        [ transaction["memo"], transaction["code"], transaction["category_label"] ]
          .compact
          .any? { |value| value.to_s.downcase.include?(needle) }
      end
    end

    page = after ? results.drop_while { |t| t["id"] != after }.drop(1) : results
    { "data" => page.first(limit), "has_more" => page.size > limit, "total_count" => results.size }
  end

  def transaction(id)
    (@transactions + @foreign_transactions).find { |t| t["id"] == id }
  end

  def comments(transaction_id)
    @comments.fetch(transaction_id, [])
  end
end
