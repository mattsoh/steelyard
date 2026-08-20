require "test_helper"

class OrganizationLedgerTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_ledger", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)

    # Raw HCB feed arrives newest-first; OrganizationLedger reverses it to
    # oldest-first before computing a running balance.
    raw = [
      { "id" => "txn_5", "date" => "2026-01-05", "memo" => "Extra", "amount_cents" => 2_000 },
      { "id" => "txn_4", "date" => "2026-01-04", "memo" => "Grant 2", "amount_cents" => -5_000 },
      { "id" => "txn_3", "date" => "2026-01-03", "memo" => "Donation 2", "amount_cents" => 5_000 },
      { "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant 1", "amount_cents" => -10_000 },
      { "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation 1", "amount_cents" => 10_000 }
    ]
    @client = FakeHcbClient.new(transactions: raw)
    @ledger = OrganizationLedger.new(@client, "org_1")
  end

  test "transactions are oldest-first with a running balance" do
    assert_equal %w[txn_1 txn_2 txn_3 txn_4 txn_5], @ledger.transactions.map(&:id)
    assert_equal [ 10_000, 0, 5_000, 0, 2_000 ], @ledger.running_balance_cents
  end

  test "zero_options includes every zero-crossing plus the beginning of history" do
    ids = @ledger.zero_options.map(&:transaction_id)
    assert_equal [ "txn_4", "txn_2", OrganizationLedger::BEGINNING_ID ], ids

    beginning = @ledger.zero_options.last
    assert beginning.beginning?
    assert_equal "2026-01-01", beginning.date
  end

  test "defaults to the most recent zero crossing when nothing is chosen" do
    assert_equal "txn_4", @ledger.effective_cutoff.transaction_id
    assert_equal %w[txn_5], @ledger.after_cutoff.map(&:id)
  end

  test "classify reflects the effective cutoff" do
    hidden_ids = %w[txn_1 txn_2]
    visible_ids = %w[txn_5]
    overlapping_ids = %w[txn_3 txn_5]

    assert_equal :hidden, @ledger.classify(hidden_ids)
    assert_equal :visible, @ledger.classify(visible_ids)
    assert_equal :overlapping, @ledger.classify(overlapping_ids)
  end

  test "choosing the beginning of history reveals everything and clears conflicts" do
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: OrganizationLedger::BEGINNING_ID, updated_by: @user)
    ledger = OrganizationLedger.new(@client, "org_1")

    assert_equal(-1, ledger.cutoff_index)
    assert_equal %w[txn_1 txn_2 txn_3 txn_4 txn_5], ledger.after_cutoff.map(&:id)
    assert_equal :visible, ledger.classify(%w[txn_1 txn_2])
    assert_equal :visible, ledger.classify(%w[txn_3 txn_5])
  end

  test "choosing an earlier cutoff changes which matches would overlap" do
    OrganizationSetting.create!(hcb_organization_id: "org_1", zero_balance_transaction_id: "txn_2", updated_by: @user)
    ledger = OrganizationLedger.new(@client, "org_1")

    assert_equal %w[txn_3 txn_4 txn_5], ledger.after_cutoff.map(&:id)
    assert_equal :hidden, ledger.classify(%w[txn_1 txn_2])
    assert_equal :visible, ledger.classify(%w[txn_3 txn_5])
  end

  test "transaction_by_id falls back to a live fetch for an id outside the drain" do
    assert_equal "txn_far", foreign_ledger.transaction_by_id("txn_far")&.id
  end

  test "write_legs_by_id refuses an id this organization's drain doesn't contain" do
    by_id = foreign_ledger.write_legs_by_id(%w[txn_1 txn_far])

    assert_equal "txn_1", by_id["txn_1"]&.id
    assert_nil by_id["txn_far"], "a transaction outside the org's drain must not resolve for a write"
  end

  test "write_legs_by_id still resolves legs a match already holds" do
    # An old match can name a transaction that has since aged out of the drain.
    # It was checked when it was added, so re-resolving it must keep working --
    # otherwise editing that match becomes impossible rather than safer.
    by_id = foreign_ledger.write_legs_by_id(%w[txn_far], existing: %w[txn_far])

    assert_equal "txn_far", by_id["txn_far"]&.id
  end

  # The warm-cache path: once a drain has written its derived side cache, legs
  # are resolved from that (small) entry rather than from the by-id index of
  # whole raw transactions, which is megabytes for a real organization. Same
  # answers either way -- that's what makes it safe to skip the big read.
  test "write_legs_by_id resolves legs from the derived index without the by-id one" do
    with_memory_cache do
      Hcb::OrganizationTransactions.new(@client, "org_1").all
      # Leaves only the derived entry behind, so anything still resolving proves
      # it didn't need the raw by-id index to do it.
      Rails.cache.delete_matched(/:by_id\z/)

      by_id = OrganizationLedger.new(@client, "org_1").write_legs_by_id(%w[txn_1 txn_2 txn_far])

      assert_equal 100.0, by_id["txn_1"].amount
      assert_equal(-100.0, by_id["txn_2"].amount)
      assert_nil by_id["txn_far"], "an id outside the org's drain must not resolve for a write"
    end
  end

  # A declined transaction is in the drain but out of the ledger's own
  # (declined-excluded) ordering, so it's the case where a leg lookup keyed on
  # that ordering would have answered differently from the by-id index. Both
  # side caches have to agree, or whether a leg resolves would come down to
  # which entry happened to still be warm.
  test "write_legs_by_id resolves a declined leg from either side cache" do
    declined = { "id" => "txn_declined", "date" => "2026-01-06", "memo" => "Declined", "amount_cents" => -300, "declined" => true }
    client = FakeHcbClient.new(transactions: [ declined ] + @client.transactions("org_1")["data"])

    with_memory_cache do
      Hcb::OrganizationTransactions.new(client, "org_1").all

      from_by_id = OrganizationLedger.new(client, "org_1").write_legs_by_id(%w[txn_declined])
      Rails.cache.delete_matched(/:by_id\z/)
      from_derived = OrganizationLedger.new(client, "org_1").write_legs_by_id(%w[txn_declined])

      assert_equal(-3.0, from_derived["txn_declined"]&.amount)
      assert_equal from_by_id["txn_declined"].amount, from_derived["txn_declined"].amount
    end
  end

  test "a pending incoming transaction is left out of the balance until it settles" do
    with_memory_cache do
      client = FakeHcbClient.new(transactions: [
        { "id" => "txn_pending_in", "date" => "2026-03-01", "amount_cents" => 50_000, "pending" => true },
        { "id" => "txn_pending_out", "date" => "2026-02-01", "amount_cents" => -2_500, "pending" => true },
        { "id" => "txn_settled_out", "date" => "2026-01-02", "amount_cents" => -1_000 },
        { "id" => "txn_settled_in", "date" => "2026-01-01", "amount_cents" => 10_000 }
      ])
      ledger = OrganizationLedger.new(client, "org_bal")

      # HCB's own figure (Event#balance_v2_cents): settled both ways, plus
      # pending outgoing, and not the pending deposit -- that money isn't there
      # yet. 10_000 - 1_000 - 2_500.
      assert_equal 6_500, ledger.balance_cents
      assert_not_includes ledger.transactions.map(&:id), "txn_pending_in"
      assert_includes ledger.transactions.map(&:id), "txn_pending_out"
    end
  end

  test "a declined transaction still doesn't count toward the balance" do
    with_memory_cache do
      client = FakeHcbClient.new(transactions: [
        { "id" => "txn_declined", "date" => "2026-01-03", "amount_cents" => -9_900, "declined" => true },
        { "id" => "txn_settled_in", "date" => "2026-01-01", "amount_cents" => 10_000 }
      ])

      assert_equal 10_000, OrganizationLedger.new(client, "org_bal2").balance_cents
    end
  end

  test "a pending incoming transaction is still resolvable by id, so a match on one keeps its leg" do
    with_memory_cache do
      client = FakeHcbClient.new(transactions: [
        { "id" => "txn_pending_in", "date" => "2026-03-01", "amount_cents" => 50_000, "pending" => true },
        { "id" => "txn_settled_out", "date" => "2026-01-02", "amount_cents" => -1_000 }
      ])
      ledger = OrganizationLedger.new(client, "org_bal3")
      ledger.balance_cents # warms the drain and its side caches

      # Filtering it out of the balance and the lists must not make it look gone:
      # Matches::Resync drops legs it can't resolve, and a display rule is no
      # reason to edit somebody's match.
      found = ledger.transaction_by_id("txn_pending_in", remote: false)
      assert found
      assert_equal 50_000, found.amount_cents
    end
  end

  test "bumping the generation orphans the long-lived per-id transaction cache" do
    with_memory_cache do
      ledger = foreign_ledger

      assert_equal(-7_500, ledger.transaction_by_id("txn_far").amount_cents)
      key = OrganizationLedger.single_transaction_cache_key("org_1", "txn_far")
      assert Rails.cache.read(key), "the fallback lookup should have been cached"

      # These entries outlive a drain by a day, so a full reload that only
      # cleared the drain caches would leave this one shadowing the fresh copy
      # of a transaction it just re-fetched.
      OrganizationLedger.bump_single_transaction_generation!("org_1")

      assert_not_equal key, OrganizationLedger.single_transaction_cache_key("org_1", "txn_far")
      assert_nil Rails.cache.read(OrganizationLedger.single_transaction_cache_key("org_1", "txn_far"))
    end
  end

  test "a full reload's purge orphans them too" do
    with_memory_cache do
      client = FakeHcbClient.new(
        transactions: @client.transactions("org_1")["data"],
        foreign_transactions: [ { "id" => "txn_far", "date" => "2026-02-01", "memo" => "Another org", "amount_cents" => -7_500 } ]
      )
      OrganizationLedger.new(client, "org_1").transaction_by_id("txn_far")
      assert Rails.cache.read(OrganizationLedger.single_transaction_cache_key("org_1", "txn_far"))

      Hcb::OrganizationTransactions.new(client, "org_1").purge!

      assert_nil Rails.cache.read(OrganizationLedger.single_transaction_cache_key("org_1", "txn_far"))
    end
  end

  private

  # The test environment runs on a null store, so every side cache a drain
  # writes is a miss and only the fall-back paths are ever exercised. Tests
  # about the warm paths need a store that actually keeps what it's given.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # A ledger for org_1 whose client can also answer for txn_far -- a
  # transaction the asking user can see elsewhere, but that is not part of
  # org_1's history.
  def foreign_ledger
    client = FakeHcbClient.new(
      transactions: @client.transactions("org_1")["data"],
      foreign_transactions: [ { "id" => "txn_far", "date" => "2026-02-01", "memo" => "Another org", "amount_cents" => -7_500 } ]
    )
    OrganizationLedger.new(client, "org_1")
  end
end
