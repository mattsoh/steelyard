# Stands in for Hcb::Client in tests so nothing hits the real HCB API.
# Construct with canned responses for whichever methods a given test exercises.
class FakeHcbClient
  attr_reader :transactions_calls

  def initialize(transactions: [], members: [], user: {}, organizations: [])
    @transactions = transactions
    @members = members
    @user = user
    @organizations = organizations
    @transactions_calls = 0
  end

  def user = @user
  def organizations = { "data" => @organizations }

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
