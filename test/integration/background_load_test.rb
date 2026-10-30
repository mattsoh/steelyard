require "test_helper"

# The whole load flow through the real middleware stack, as two browsers would
# see it: one opens a cold organization and starts the background task, the
# job runs it, and a second person -- signed in as somebody else, in another
# tab -- reads the same progress, the same rows, and the same activity log.
class BackgroundLoadTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Rails.cache = @previous_cache
  end

  test "a cold load is one background task that every viewer follows, with its log" do
    matthew = User.create!(hcb_user_id: "usr_1", name: "Matthew", email: "m@example.com", access_token: "a",
                           refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..250).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions, user_id: matthew.id)

    Hcb::Client.stub :new, client do
      Hcb::Client.stub :for_user, ->(_u) { client } do
        stub_membership("reader") do
          sign_in_via_hcb!(matthew)

          # The first tab opens the organization: nothing cached, so this
          # request claims a task, hands it to the job, and answers at once.
          assert_enqueued_with(job: WarmOrganizationTransactionsJob) do
            get "/organizations/org_1/api/transactions/page"
          end
          assert_response :success
          first = JSON.parse(response.body)
          assert_not first["warm"]
          assert_equal "starting", first.dig("progress", "phase")
          assert_equal "Matthew", first.dig("progress", "requested_by")
          assert_match(/Matthew started loading/, first["log"].sole["text"])
          assert_equal 0, client.transactions_calls

          # The authoritative view, asked for too early, says so rather than
          # reporting an empty organization -- and starts nothing extra.
          assert_no_enqueued_jobs(only: WarmOrganizationTransactionsJob) do
            get "/organizations/org_1/api/transactions"
          end
          assert JSON.parse(response.body)["draining"]
          assert_empty JSON.parse(response.body)["transactions"]

          # The job runs the task to completion.
          perform_enqueued_jobs(only: WarmOrganizationTransactionsJob)
          assert_equal 3, client.transactions_calls

          # The tab's next poll finds the result warm and the token to cache it by.
          get "/organizations/org_1/api/transactions/page", params: { after_page: 0, log_after: first["log"].last["seq"] }
          warm = JSON.parse(response.body)
          assert warm["warm"]
          assert_equal 250, warm["rows"].size
          assert warm["token"].present?
          assert_equal "done", warm.dig("progress", "phase")
          # Only the lines it hadn't seen: the pages, the publish, the finish.
          texts = warm["log"].map { |e| e["text"] }
          assert_equal 3, texts.count { |t| t.start_with?("page ") }
          assert_match(/250 transactions published/, texts.last)
          assert_not texts.any? { |t| t.include?("started loading") }

          get "/organizations/org_1/api/transactions"
          assert_equal 250, JSON.parse(response.body)["transactions"].size
        end
      end
    end

    # Somebody else opens the organization afterwards, in their own session:
    # nothing to fetch, and the full history of what happened to it.
    other = User.create!(hcb_user_id: "usr_2", name: "Other", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    other_session = open_session
    other_client = FakeHcbClient.new(transactions: transactions, user_id: other.id)
    Hcb::Client.stub :new, other_client do
      stub_membership("reader") do
        other_session.sign_in_via_hcb!(other)
        other_session.get "/organizations/org_1/api/transactions/sync_status"
        status = JSON.parse(other_session.response.body)

        assert_not status["draining"]
        assert_equal "done", status.dig("progress", "phase")
        assert_equal "Matthew", status.dig("progress", "requested_by")
        assert_match(/Matthew started loading/, status["log"].first["text"])
        assert_match(/published/, status["log"].last["text"])
        assert_equal 0, other_client.transactions_calls
      end
    end
  end

  test "a tab that joins mid-walk is handed the pages fetched so far and follows the rest" do
    matthew = User.create!(hcb_user_id: "usr_1", name: "Matthew", access_token: "a", refresh_token: "b", token_expires_at: 1.hour.from_now)
    transactions = (1..300).map { |n| { "id" => "txn_#{n}", "date" => "2026-01-01", "amount_cents" => n } }.reverse
    client = FakeHcbClient.new(transactions: transactions, user_id: matthew.id)
    service = Hcb::OrganizationTransactions.new(client, "org_1")

    # A task somebody started is two pages into a three-page walk.
    service.start_task!(kind: :cold, requested_by: "somebody else")
    Rails.cache.write(service.send(:page_key, 1), transactions[0, 100], expires_in: 1.minute)
    Rails.cache.write(service.send(:page_key, 2), transactions[100, 100], expires_in: 1.minute)
    service.progress.advance!(pages_done: 2, transactions_done: 200, total_count: 300)

    Hcb::Client.stub :new, client do
      stub_membership("reader") do
        sign_in_via_hcb!(matthew)

        get "/organizations/org_1/api/transactions/page"
        joined = JSON.parse(response.body)
        assert_not joined["warm"]
        assert_equal 200, joined["rows"].size
        assert_equal 2, joined["pages_done"]
        assert_equal "somebody else", joined.dig("progress", "requested_by")

        # The task finishes while the tab waits; its next poll is warm.
        service.run_task!(service.task_claim[:task_id])
        get "/organizations/org_1/api/transactions/page", params: { after_page: joined["pages_done"] }
        finished = JSON.parse(response.body)
        assert finished["warm"]
        assert_equal 300, finished["rows"].size
      end
    end
  end
end
