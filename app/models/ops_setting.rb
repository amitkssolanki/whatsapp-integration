# The single row of runtime switches (see the ops_settings migration). The row
# is created on first use, so a database loaded from schema.rb (which carries no
# data) works the same as a migrated one.
class OpsSetting < ApplicationRecord
  SINGLETON_ID = 1

  def self.current
    find_by(id: SINGLETON_ID) || begin
      insert({ id: SINGLETON_ID }, unique_by: :id)
      find(SINGLETON_ID)
    end
  end
end
