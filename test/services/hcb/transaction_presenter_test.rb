require "test_helper"

class Hcb::TransactionPresenterTest < ActiveSupport::TestCase
  test "presents a credit as incoming with a positive dollar amount" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_1", "date" => "2026-01-01", "memo" => "Donation", "amount_cents" => 12_345, "tags" => [ "complete" ], "code" => "200" })

    assert_equal "in", presenter.direction
    assert_equal 123.45, presenter.amount
    assert_equal "complete", presenter.tags
    assert_equal "Donation (200)", presenter.category_label
  end

  test "falls back to a humanized label for an unrecognized category code" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_4", "date" => "2026-01-04", "amount_cents" => 100, "code" => "incoming_disbursement" })

    assert_equal "Incoming disbursement (incoming_disbursement)", presenter.category_label
  end

  test "presents a debit as outgoing with a negative dollar amount" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_2", "date" => "2026-01-02", "memo" => "Grant", "amount_cents" => -5_000 })

    assert_equal "out", presenter.direction
    assert_equal(-50.0, presenter.amount)
  end

  test "exposes the bare HCB code alongside the human category label" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_3", "amount_cents" => 100, "code" => "550" })

    assert_equal "550", presenter.code
    assert_equal "550", presenter.as_json[:code]
    assert_equal "Incoming disbursement (550)", presenter.category_label
  end

  test "reads the user name from the sender of an ACH transfer, check, transfer, wire, or Wise transfer" do
    %w[ach_transfer check transfer wire_transfer wise_transfer].each do |type|
      presenter = Hcb::TransactionPresenter.new({ "id" => "txn_5", "amount_cents" => 100, type => { "sender" => { "name" => "Jane D." } } })

      assert_equal "Jane D.", presenter.user_name
    end
  end

  test "reads the user name from the cardholder of a card charge" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_6", "amount_cents" => -100, "card_charge" => { "card" => { "user" => { "name" => "Sam R." } } } })

    assert_equal "Sam R.", presenter.user_name
  end

  test "reads the user name from the submitter of a check deposit" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_7", "amount_cents" => 100, "check_deposit" => { "submitter" => { "name" => "Lee K." } } })

    assert_equal "Lee K.", presenter.user_name
  end

  test "has no user name for transaction types with no internal HCB sender, like donations" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_8", "amount_cents" => 100, "donation" => { "donor" => { "name" => "External Donor" } } })

    assert_equal "", presenter.user_name
  end

  test "as_json matches the legacy frontend's expected field shape" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_3", "date" => "2026-01-03", "memo" => "Fee", "amount_cents" => -100 })
    json = presenter.as_json

    assert_equal %i[
      id date settled_date memo amount direction tags user_name code category_label
      recipient_name reason pending declined reversed missing_receipt lost_receipt
      status_label decline_reason return_reason
    ].sort, json.keys.sort
  end

  test "date falls back to the settled date when there's no sent-side timestamp for this type" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_9", "date" => "2026-01-09", "amount_cents" => 100, "check_deposit" => { "status" => "deposited" } })

    assert_equal "2026-01-09", presenter.date
    assert_equal "2026-01-09", presenter.settled_date
  end

  test "date uses the sent-side timestamp when the transaction has since settled on a later date" do
    presenter = Hcb::TransactionPresenter.new({
      "id" => "txn_10", "date" => "2026-02-15", "amount_cents" => 5_000,
      "ach_transfer" => { "created_at" => "2026-02-01T12:00:00Z" }
    })

    assert_equal "2026-02-01", presenter.date
    assert_equal "2026-02-15", presenter.settled_date
  end

  test "donations use donated_at, preferring it over the sub-object's own created_at" do
    presenter = Hcb::TransactionPresenter.new({
      "id" => "txn_11", "date" => "2026-03-10", "amount_cents" => 2_500,
      "donation" => { "donated_at" => "2026-03-01T00:00:00Z", "created_at" => "2026-03-02T00:00:00Z" }
    })

    assert_equal "2026-03-01", presenter.date
  end

  test "wise transfers prefer sent_at over created_at when both are present" do
    presenter = Hcb::TransactionPresenter.new({
      "id" => "txn_12", "date" => "2026-04-20", "amount_cents" => -1_000,
      "wise_transfer" => { "created_at" => "2026-04-01T00:00:00Z", "sent_at" => "2026-04-05T00:00:00Z" }
    })

    assert_equal "2026-04-05", presenter.date
  end

  test "recipient_name reads the counterparty for common transaction types" do
    donation = Hcb::TransactionPresenter.new({ "id" => "txn_13", "amount_cents" => 100, "donation" => { "donor" => { "name" => "External Donor" } } })
    assert_equal "External Donor", donation.recipient_name

    ach = Hcb::TransactionPresenter.new({ "id" => "txn_14", "amount_cents" => -100, "ach_transfer" => { "recipient_name" => "Acme Co" } })
    assert_equal "Acme Co", ach.recipient_name

    card = Hcb::TransactionPresenter.new({ "id" => "txn_15", "amount_cents" => -100, "card_charge" => { "merchant" => { "name" => "COFFEE SHOP #123", "smart_name" => "Coffee Shop" } } })
    assert_equal "Coffee Shop", card.recipient_name
  end

  test "recipient_name reads the organization at the other end of a transfer, whichever way the money went" do
    transfer = { "from" => { "name" => "Sending Org" }, "to" => { "name" => "Receiving Org" } }

    outgoing = Hcb::TransactionPresenter.new({ "id" => "txn_16", "amount_cents" => -100, "transfer" => transfer })
    assert_equal "Receiving Org", outgoing.recipient_name

    incoming = Hcb::TransactionPresenter.new({ "id" => "txn_17", "amount_cents" => 100, "transfer" => transfer })
    assert_equal "Sending Org", incoming.recipient_name
  end

  test "reason reads whichever field this transaction's type files it under" do
    {
      "ach_transfer" => { "payment_for" => "Venue deposit" },
      "check" => { "payment_for" => "Printing" },
      "wire_transfer" => { "payment_for" => "Speaker travel" },
      "wise_transfer" => { "payment_for" => "Translator" },
      "transfer" => { "memo" => "Hardware grant" },
      "invoice" => { "description" => "Gold sponsorship" },
      "donation" => { "message" => "Good luck!" }
    }.each do |type, sub_object|
      presenter = Hcb::TransactionPresenter.new({ "id" => "txn_18", "amount_cents" => -100, type => sub_object })

      assert_equal sub_object.values.first, presenter.reason, "expected #{type} to supply the reason"
    end
  end

  # The whole point of surfacing it separately: on the receiving side HCB
  # rewrites the transaction memo, so the nested transfer is the only copy of
  # the sender's stated purpose the destination org can see.
  test "reason keeps an incoming transfer's stated purpose, which its memo no longer carries" do
    presenter = Hcb::TransactionPresenter.new({
      "id" => "txn_19", "amount_cents" => 1_000, "memo" => "Transfer from Daydream",
      "transfer" => { "memo" => "🛠️ Testing transparency API" }
    })

    assert_equal "🛠️ Testing transparency API", presenter.reason
  end

  test "reason skips a field HCB returned empty rather than absent" do
    presenter = Hcb::TransactionPresenter.new({
      "id" => "txn_20", "amount_cents" => -100,
      "check" => { "payment_for" => "" }, "invoice" => { "description" => "Booth fee" }
    })

    assert_equal "Booth fee", presenter.reason
  end

  test "reason is nil for a type that has nothing like it, e.g. a card charge" do
    presenter = Hcb::TransactionPresenter.new({ "id" => "txn_21", "amount_cents" => -100, "card_charge" => { "merchant" => { "name" => "COFFEE SHOP" } } })

    assert_nil presenter.reason
  end

  test "status_label reads the type's own state and reads it as words" do
    transfer = Hcb::TransactionPresenter.new({ "id" => "txn_22", "amount_cents" => 100, "transfer" => { "status" => "completed" } })
    assert_equal "Completed", transfer.status_label

    wire = Hcb::TransactionPresenter.new({ "id" => "txn_23", "amount_cents" => -100, "wire_transfer" => { "state" => "in_transit" } })
    assert_equal "In transit", wire.status_label

    fee = Hcb::TransactionPresenter.new({ "id" => "txn_24", "amount_cents" => -100 })
    assert_nil fee.status_label
  end

  test "return_reason is only carried by Wise transfers, which are the only ones HCB explains" do
    wise = Hcb::TransactionPresenter.new({
      "id" => "txn_25", "amount_cents" => -100,
      "wise_transfer" => { "state" => "returned", "return_reason" => "Recipient account closed" }
    })

    assert_equal "Returned", wise.status_label
    assert_equal "Recipient account closed", wise.return_reason

    check = Hcb::TransactionPresenter.new({ "id" => "txn_26", "amount_cents" => -100, "check" => { "status" => "in_transit" } })
    assert_nil check.return_reason
  end
end
