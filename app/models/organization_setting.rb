class OrganizationSetting < ApplicationRecord
  belongs_to :updated_by, class_name: "User", foreign_key: :updated_by_user_id

  validates :hcb_organization_id, presence: true, uniqueness: true
end
