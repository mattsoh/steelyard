# Hiding a match takes it out of the matcher's two lists without changing what
# it pairs: a discrepancy that is an engineering bug rather than money anyone
# has to find would otherwise sit at the top of the unbalanced list forever.
# The match, its legs and its discrepancy are all untouched -- this is about
# what the lists show by default, and hidden matches can be shown again.
class AddHiddenToMatches < ActiveRecord::Migration[8.1]
  def change
    add_column :matches, :hidden_at, :datetime
    add_column :matches, :hidden_by_user_id, :bigint
  end
end
