# Stands in for Hcb::Client in tests so nothing hits the real HCB API.
# Construct with canned responses for whichever methods a given test exercises.
class FakeHcbClient
  attr_reader :transactions_calls, :user_id

  def initialize(transactions: [], members: [], user: {}, organizations: [], user_id: nil)
    @transactions = transactions
    @members = members
    @user = user
    @organizations = organizations
    @transactions_calls = 0
    @user_id = user_id
  end

  def user = @user
  def organizations = { "data" => @organizations }

  # Prepends newly-"arrived" transactions (newest-first, matching HCB's own
  # ordering) so tests can simulate activity happening between two drains.
  def add_transactions(new_transactions)
    @transactions = new_transactions + @transactions
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
    @transactions_calls += 1

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
    @transactions.find { |t| t["id"] == id }
  end
end
