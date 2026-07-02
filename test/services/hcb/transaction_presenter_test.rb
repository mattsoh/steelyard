require "test_helper"

class Hcb::TransactionPresenterTest < ActiveSupport::TestCase
  test "presents a credit as incoming with a positive dollar amount" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 12_345, "tags" => [ "complete" ], "code" => "donation" })

    assert_equal "in", presenter.direction
    assert_equal 123.45, presenter.amount
    assert_equal "complete", presenter.tags
    assert_equal "Donation", presenter.category_label
  end

  test "presents a debit as outgoing with a negative dollar amount" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -5_000 })

    assert_equal "out", presenter.direction
    assert_equal(-50.0, presenter.amount)
  end

  test "as_json matches the legacy frontend's expected field shape" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_3", "date" => "2026-01-03", "memo" => "Fee", "amount_cents" => -100 })
    json = presenter.as_json

    assert_equal %i[id date memo amount direction tags comments user_name category_label].sort, json.keys.sort
  end
end
