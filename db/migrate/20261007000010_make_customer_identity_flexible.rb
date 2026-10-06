# Meta no longer always sends a phone number (users with usernames), but always
# sends a business-scoped user id. A customer is therefore identified by either
# one: each is unique when present, and at least one must be.
class MakeCustomerIdentityFlexible < ActiveRecord::Migration[8.1]
  def change
    change_column_null :customers, :whatsapp_number, true

    remove_index :customers, :whatsapp_number, unique: true
    add_index :customers, :whatsapp_number, unique: true, where: "whatsapp_number IS NOT NULL"
    add_index :customers, :wa_user_id, unique: true, where: "wa_user_id IS NOT NULL"

    add_check_constraint :customers, "whatsapp_number IS NOT NULL OR wa_user_id IS NOT NULL",
                         name: "customers_identity_present"
  end
end
