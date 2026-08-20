require "test_helper"

class Api::MatchesControllerTest < ActionController::TestCase
  def setup
    @user = User.create!(hcb_user_id: "usr_1", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    incoming = { "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 }
    outgoing = { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 }
    @fake_client = FakeHcbClient.new(transactions: [ incoming, outgoing ])
    session[:user_id] = @user.id
  end

  test "unauthenticated requests are redirected to login" do
    session[:user_id] = nil
    get :index, params: { organization_id: "org_1" }
    assert_redirected_to root_path
  end

  test "a non-member gets the same not-found response as a nonexistent org" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership(nil) do
        get :index, params: { organization_id: "org_1" }
      end
    end
    assert_response :not_found
  end

  test "a reader can list matches but cannot create one" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
        assert_response :success

        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :forbidden
      end
    end
  end

  test "a member can create and then undo a match" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created
        match_id = JSON.parse(response.body)["id"]

        delete :destroy, params: { organization_id: "org_1", id: match_id }
        assert_response :success
        assert Match.find(match_id).undone?
      end
    end
  end

  test "create returns the fully serialized match, not just id/discrepancy" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created

        match = JSON.parse(response.body)
        assert_equal [ "txn_in" ], match["incoming_ids"]
        assert_equal [ "txn_out" ], match["outgoing_ids"]
        assert_equal 0, match["discrepancy"]
        assert_equal false, match["conflict"]
        assert match.key?("created_by_name")
        assert match["created_at"].present?
      end
    end
  end

  test "index does not flag an ordinary match as a conflict" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created

        get :index, params: { organization_id: "org_1" }
        assert_response :success
        match = JSON.parse(response.body)["matches"].sole
        assert_equal false, match["conflict"]
      end
    end
  end

  test "index flags a match whose legs span the effective cutoff as a conflict" do
    raw = [
      { "id" => "txn_C", "date" => "2026-01-03", "memo" => "Extra", "amount_cents" => 5_000 },
      { "id" => "txn_B", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 },
      { "id" => "txn_A", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 }
    ]
    fake_client = FakeHcbClient.new(transactions: raw)

    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_A", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_C", direction: :outgoing)

    Hcb::Client.stub :new, fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    found = JSON.parse(response.body)["matches"].sole
    assert_equal match.id, found["id"]
    assert_equal true, found["conflict"]
  end

  test "show returns the match with its legs resolved and its history" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        match = Match.create!(hcb_organization_id: "org_1", note: "for the workshop", discrepancy_cents: 0, created_by: @user)
        match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
        match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

        get :show, params: { organization_id: "org_1", id: match.id }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal "for the workshop", body["note"]
        assert_equal false, body["edited"]
        # The legs come back as whole transactions, so the popup can name them
        # without the page it opened over having loaded them.
        assert_equal "Donation", body.dig("transactions", "txn_in", "memo")
        assert_equal(-100.0, body.dig("transactions", "txn_out", "amount"))
        assert_equal [ "created" ], body["history"].map { |e| e["action"] }
        assert body.key?("created_by_name")
        assert body["created_at"].present?
      end
    end
  end

  # The one view where an undone match is still worth reading: a link to one
  # should explain what happened to it rather than 404.
  test "show still answers for a match that has been undone" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        match_id = JSON.parse(response.body)["id"]
        delete :destroy, params: { organization_id: "org_1", id: match_id }

        get :show, params: { organization_id: "org_1", id: match_id }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal true, body["undone"]
        assert body["undone_at"].present?
        assert_includes body["history"].map { |e| e["action"] }, "undone"
        # Undoing marks the legs undone too, so reporting only live ones would
        # leave the popup saying this match paired nothing at all.
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal [ "txn_out" ], body["outgoing_ids"]
        assert_equal "Grant", body.dig("transactions", "txn_out", "memo")
      end
    end
  end

  # A leg older than HCB's drained window is resolved by fetching it, which the
  # ledger caches. That fetch happens as whoever is asking, so it can only ever
  # return what they could already see -- unless a cached answer from somewhere
  # else is read back instead. Legs name whatever id their author gave them, so
  # this is reachable: the cache has to be keyed per organization, or one
  # organization's request answers another's.
  test "a leg is never described from another organization's cached copy" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_elsewhere", direction: :outgoing)

    # A real store for the duration: the test environment's null_store would
    # drop the write below and let this pass without proving anything.
    with_memory_cache do
      # Warmed by a request against a different organization, which is the only
      # place this transaction's contents exist.
      Rails.cache.write(
        OrganizationLedger.single_transaction_cache_key("org_2", "txn_elsewhere"),
        { "id" => "txn_elsewhere", "date" => "2026-01-01", "memo" => "Another org's grant", "amount_cents" => -500 }
      )

      Hcb::Client.stub :new, @fake_client do
        stub_membership("manager") do
          get :show, params: { organization_id: "org_1", id: match.id }
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    # The leg is no longer part of the match: org_1's history doesn't account
    # for this transaction, so the resync drops it and re-derives what's left
    # (see Matches::Resync). What matters here is that it was never *described*
    # on the way out -- the only copy of its contents belongs to another
    # organization, and a per-organization cache key is what keeps it there.
    assert_empty body["outgoing_ids"]
    assert_not body["transactions"].key?("txn_elsewhere")
    assert_no_match(/Another org/, response.body)
    # Kept, not deleted, so remapping it back into org_1 restores the leg.
    assert_equal [ "txn_elsewhere" ], match.match_transactions.dropped.map(&:hcb_transaction_id)
  end

  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # A match link is shareable, so it will end up in front of people who aren't
  # in the organization. The id in it is not a capability: access is decided
  # here, by the same membership check as everything else.
  test "a non-member cannot read a match through its link" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)

    Hcb::Client.stub :new, @fake_client do
      stub_membership(nil) do
        get :show, params: { organization_id: "org_1", id: match.id }
      end
    end
    assert_response :not_found
    assert_no_match(/discrepancy|history/, response.body)
  end

  test "show does not reach a match belonging to another organization" do
    other = Match.create!(hcb_organization_id: "org_2", discrepancy_cents: 0, created_by: @user)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        get :show, params: { organization_id: "org_1", id: other.id }
      end
    end
    assert_response :not_found
  end

  test "matching the same transaction twice returns a conflict" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("manager") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        assert_response :created

        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        assert_response :conflict
      end
    end
  end

  # The match popup's note editor sends nothing but a note. The legs it doesn't
  # mention are the whole match, so reading their absence as "no legs" would
  # empty it -- and the stored discrepancy has to survive too, since the
  # request carries no amounts to re-derive it from.
  test "a note-only update leaves the legs and the discrepancy alone" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        assert_response :created
        match_id = JSON.parse(response.body)["id"]

        patch :update, params: { organization_id: "org_1", id: match_id, note: "Refunded in February" }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal "Refunded in February", body["note"]
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal 100.0, body["discrepancy"]
        # The popup redraws its change log from this response.
        assert body["history"].any? { |e| e["action"] == "edited" }

        match = Match.find(match_id)
        assert_equal [ "txn_in" ], match.incoming_transaction_ids
        assert_equal 10_000, match.discrepancy_cents
      end
    end
  end

  test "an update that sends legs still rewrites them" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [], note: "First" }
        assert_response :created
        match_id = JSON.parse(response.body)["id"]

        patch :update, params: { organization_id: "org_1", id: match_id, incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal [ "txn_out" ], body["outgoing_ids"]
        assert_equal 0, body["discrepancy"]
        # Not sent, so not touched.
        assert_equal "First", body["note"]
      end
    end
  end

  # Hiding is how a discrepancy that's an engineering bug rather than missing
  # money stops sitting at the top of the unbalanced list. It must not touch
  # what the match pairs or what it's off by -- the frontend still counts it,
  # and an unhide has to put back exactly what was there.
  test "hiding and unhiding a match leaves its legs and discrepancy alone" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        match_id = JSON.parse(response.body)["id"]

        patch :update, params: { organization_id: "org_1", id: match_id, hidden: true }
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal true, body["hidden"]
        assert_equal [ "txn_in" ], body["incoming_ids"]
        assert_equal 100.0, body["discrepancy"]
        hidden_match = Match.find(match_id)
        assert hidden_match.hidden?
        assert_equal @user.id, hidden_match.hidden_by_user_id

        # The change log says who took it out of the list, in words rather than
        # as a timestamp appearing on the match from nowhere.
        change = body["history"].last["changes"].sole
        assert_equal "flag", change["kind"]
        assert_equal "no", change["from"]
        assert_equal "yes", change["to"]

        patch :update, params: { organization_id: "org_1", id: match_id, hidden: false }
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal false, body["hidden"]
        assert_nil body["hidden_by_name"]
        assert_equal [ "txn_in" ], body["incoming_ids"]

        match = Match.find(match_id)
        assert_not match.hidden?
        assert_nil match.hidden_by_user_id
        assert_equal 10_000, match.discrepancy_cents
      end
    end
  end

  test "an update that does not mention hidden leaves it as it stands" do
    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [] }
        match_id = JSON.parse(response.body)["id"]

        patch :update, params: { organization_id: "org_1", id: match_id, hidden: true }
        patch :update, params: { organization_id: "org_1", id: match_id, note: "Known HCB duplicate" }
        assert_response :success

        body = JSON.parse(response.body)
        assert_equal true, body["hidden"]
        assert_equal "Known HCB duplicate", body["note"]
      end
    end
  end

  test "a reader cannot hide a match" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 500, created_by: @user)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        patch :update, params: { organization_id: "org_1", id: match.id, hidden: true }
      end
    end
    assert_response :forbidden
    assert_not match.reload.hidden?
  end

  test "a reader cannot write a note" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        patch :update, params: { organization_id: "org_1", id: match.id, note: "mine now" }
      end
    end
    assert_response :forbidden
    assert_nil match.reload.note
  end

  # A member of org_1 naming a transaction that belongs to another org they can
  # see. HCB will answer a single-transaction fetch for it, and the ledger used
  # to cache that answer under org_1's key and store it as a leg -- putting a
  # foreign transaction's memo and amount in front of every org_1 member who
  # later read the match.
  test "a leg outside the organization's own history is refused on create" do
    Hcb::Client.stub :new, foreign_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_elsewhere" ] }
      end
    end

    assert_response :unprocessable_entity
    assert_equal 0, Match.count
  end

  test "a leg outside the organization's own history is refused on update" do
    match = nil
    Hcb::Client.stub :new, foreign_client do
      stub_membership("member") do
        post :create, params: { organization_id: "org_1", incoming_ids: [ "txn_in" ], outgoing_ids: [ "txn_out" ] }
        assert_response :created
        match = Match.find(JSON.parse(response.body)["id"])

        patch :update, params: { organization_id: "org_1", id: match.id, outgoing_ids: [ "txn_elsewhere" ] }
      end
    end

    assert_response :unprocessable_entity
    assert_equal [ "txn_out" ], match.reload.outgoing_transaction_ids
  end

  private

  def foreign_client
    FakeHcbClient.new(
      transactions: [
        { "id" => "txn_in", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 10_000 },
        { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 }
      ],
      foreign_transactions: [
        { "id" => "txn_elsewhere", "date" => "2026-01-03", "memo" => "Another org's payroll", "amount_cents" => -50_000 }
      ]
    )
  end

  test "index reports which matches the resync moved, not just the corrected numbers" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    # HCB restates the outgoing leg -- the match was confirmed as balanced and
    # silently isn't any more, which is exactly what someone reaching for a sync
    # or a full reload is trying to find out.
    @fake_client.update_transaction("txn_out", "amount_cents" => -9_000)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    resynced = JSON.parse(response.body)["match_changes"]
    assert_equal 1, resynced.size
    assert_equal match.id, resynced.first["id"]
    assert_equal "amount", resynced.first["kind"]
    assert_equal 0.0, resynced.first["from"]
    assert_equal 10.0, resynced.first["to"]
    assert_equal 1_000, match.reload.discrepancy_cents
  end

  test "index reports nothing resynced when every match still adds up" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_empty JSON.parse(response.body)["match_changes"]
  end

  test "a full reload in progress leaves stored discrepancies alone rather than resyncing against nothing" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        Hcb::OrganizationTransactions.new(@fake_client, "org_1").claim_full_reload!("stream-1")
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    # Every leg is unresolvable while the drain is being rebuilt. Summing what
    # can be resolved would replace a correct number with a wrong one and stamp
    # it as freshly confirmed, so the resync skips the match entirely.
    assert_empty JSON.parse(response.body)["match_changes"]
    assert_equal 0, match.reload.discrepancy_cents
  end

  test "index drops a leg that is no longer in the organization's history and re-derives the match" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    # HCB no longer accounts for the outgoing leg at all -- voided, reversed,
    # re-grouped under another organization. It isn't part of what this match
    # pairs any more, so it stops being part of the match.
    @fake_client.remove_transaction("txn_out")

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    assert_response :success
    body = JSON.parse(response.body)

    dropped = body["match_changes"].sole
    assert_equal match.id, dropped["id"]
    assert_equal "dropped", dropped["kind"]
    assert_equal [ "txn_out" ], dropped["transaction_ids"]
    assert_equal 0.0, dropped["from"]
    assert_equal 100.0, dropped["to"]
    assert_not dropped["undone"]

    # A match that read as balanced now reads as off by the leg that went --
    # which is what it actually claims now.
    assert_equal 10_000, match.reload.discrepancy_cents
    assert_equal [ "txn_in" ], match.match_transactions.active.map(&:hcb_transaction_id)

    # Serialized from the pruned rows, not the ones loaded before the resync.
    serialized = body["matches"].sole
    assert_equal [ "txn_in" ], serialized["incoming_ids"]
    assert_empty serialized["outgoing_ids"]
  end

  test "index leaves unresolved_ids empty for a match whose legs all still resolve" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        get :index, params: { organization_id: "org_1" }
      end
    end

    body = JSON.parse(response.body)
    assert_empty body["match_changes"]
    assert_empty body["matches"].sole["unresolved_ids"]
  end

  def unresolvable_matches(count)
    Array.new(count) do |n|
      m = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
      m.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_gone_#{n}", direction: :incoming)
      m
    end
  end

  test "prune applies the drops the safety valve declined, for the match asked about" do
    matches = unresolvable_matches(6)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") do
        # The valve refuses on its own: six legs gone at once looks like a short
        # drain rather than HCB losing all of them.
        get :index, params: { organization_id: "org_1" }
        assert_equal 6, JSON.parse(response.body)["match_changes"].count { |c| c["kind"] == "unresolved" }

        post :prune, params: { organization_id: "org_1", id: matches.first.id }
      end
    end

    assert_response :success
    change = JSON.parse(response.body)["match_changes"].sole
    assert_equal "dropped", change["kind"]
    assert_equal matches.first.id, change["id"]

    # Only the one asked about -- clicking one badge doesn't mean the whole org.
    assert_empty matches.first.match_transactions.active
    matches.drop(1).each { |m| assert_equal 1, m.match_transactions.active.count }
  end

  test "prune without a match id applies every declined drop" do
    matches = unresolvable_matches(6)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("member") { post :prune, params: { organization_id: "org_1" } }
    end

    assert_equal 6, JSON.parse(response.body)["match_changes"].size
    matches.each { |m| assert_empty m.match_transactions.active }
  end

  test "a reader cannot prune" do
    matches = unresolvable_matches(6)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") { post :prune, params: { organization_id: "org_1" } }
    end

    assert_response :forbidden
    matches.each { |m| assert_equal 1, m.match_transactions.active.count }
  end

  test "a pruned leg is picked back up when HCB accounts for the transaction again" do
    match = Match.create!(hcb_organization_id: "org_1", discrepancy_cents: 0, created_by: @user)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_in", direction: :incoming)
    match.match_transactions.create!(hcb_organization_id: "org_1", hcb_transaction_id: "txn_out", direction: :outgoing)

    Hcb::Client.stub :new, @fake_client do
      stub_membership("reader") do
        @fake_client.remove_transaction("txn_out")
        get :index, params: { organization_id: "org_1" }
        assert_equal 10_000, match.reload.discrepancy_cents

        # Remapped back into the organization. Nobody should have to rebuild the
        # match by hand to recover from someone else's mistake on HCB.
        @fake_client.add_transactions([ { "id" => "txn_out", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -10_000 } ])
        get :index, params: { organization_id: "org_1" }
      end
    end

    change = JSON.parse(response.body)["match_changes"].sole
    assert_equal "restored", change["kind"]
    assert_equal [ "txn_out" ], change["transaction_ids"]
    assert_equal 0, match.reload.discrepancy_cents
    assert_equal [ "txn_in", "txn_out" ], match.match_transactions.active.map(&:hcb_transaction_id).sort
  end
end
