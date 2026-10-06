# One row of runtime switches an operator flips from the Health page, so a
# scenario run needs no redeploy (a redeploy restarts Puma and the in-process
# queue, which turns in-flight sends into `unknown`). Only `fault_inject` for
# now; see FaultInjection.
class CreateOpsSettings < ActiveRecord::Migration[8.1]
  def up
    create_table :ops_settings do |t|
      t.string :fault_inject, array: true, default: [], null: false
      t.string :updated_by
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_check_constraint :ops_settings, "id = 1", name: "ops_settings_single_row"
    execute "INSERT INTO ops_settings (id) VALUES (1)"
  end

  def down
    drop_table :ops_settings
  end
end
