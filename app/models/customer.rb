class Customer < ApplicationRecord
  include Synthetic

  has_one :conversation, dependent: :destroy
  has_many :orders, dependent: :nullify

  # A customer is known by a phone number, a business-scoped user id, or both.
  # Meta omits the phone number for users with usernames, so neither one alone
  # is required (the database enforces "at least one" with a check constraint).
  validates :whatsapp_number, uniqueness: true, allow_nil: true
  validates :wa_user_id, uniqueness: true, allow_nil: true
  validate :identified

  # Ops::Purge anonymised this customer (name and phone number removed, user id
  # replaced by "purged:<id>"): it can no longer be written to.
  def purged? = purged_at.present?

  # Finds or creates the customer (and its conversation) for an inbound
  # webhook. docs/v2/DESIGN.md §6: the business-scoped user id wins when
  # present, the phone number is the fallback.
  #
  # An existing customer is returned untouched. Refreshing it (the identifier a
  # later message brings, a changed profile name) is #fill_in!, which callers
  # run only once the message is known to be new: a replayed or duplicate old
  # message must never overwrite newer customer data.
  #
  # A customer created while a Demo::Sandbox is entered is synthetic, whoever
  # asked for it: nothing a demo run creates can pass for real.
  #
  # Safe when two workers see the same new customer at once: the INSERT uses
  # ON CONFLICT DO NOTHING (on whichever unique index trips) instead of
  # find-then-create, so the loser waits for the winner's commit and reads the
  # winner's row.
  def self.resolve!(whatsapp_number: nil, wa_user_id: nil, display_name: nil)
    number = whatsapp_number.presence
    user_id = wa_user_id.presence
    raise ArgumentError, "a customer needs a phone number or a user id" unless number || user_id

    customer = lookup(number, user_id)
    unless customer
      AppLog.quietly do # the INSERT renders the number and name inline
        insert({ whatsapp_number: number, wa_user_id: user_id, display_name: display_name.presence, synthetic: Demo::Sandbox.entered? })
      end
      customer = lookup(number, user_id) or raise ActiveRecord::RecordNotFound, "customer vanished after insert"
    end

    Conversation.insert({ customer_id: customer.id }, unique_by: :customer_id)
    customer
  end

  def self.lookup(number, user_id)
    (find_by(wa_user_id: user_id) if user_id) || (find_by(whatsapp_number: number) if number)
  end
  private_class_method :lookup

  # Adds what this message knows that the row does not. Identifiers are only
  # ever filled in, never overwritten (a changed phone number is a different
  # conversation until proven otherwise); the display name follows the latest
  # profile. If the identifier already belongs to another customer (two rows
  # were created before they were known to be one person) it is left alone and
  # logged: merging customers is a human decision.
  def fill_in!(whatsapp_number: nil, wa_user_id: nil, display_name: nil)
    fill_identifier(:whatsapp_number, whatsapp_number)
    fill_identifier(:wa_user_id, wa_user_id)

    name = display_name.presence
    return if name.nil? || name == self.display_name

    AppLog.quietly { update_columns(display_name: name, updated_at: Time.current) }
  end

  private

  def fill_identifier(column, value)
    return if value.blank? || self[column].present?

    # A savepoint: a unique violation must not abort the caller's transaction.
    AppLog.quietly do
      transaction(requires_new: true) do
        self.class.where(id: id, column => nil).update_all(column => value, updated_at: Time.current)
      end
    end
    reload
  rescue ActiveRecord::RecordNotUnique
    AppLog.event("customer.identity_conflict", customer_id: id, field: column)
  end

  def identified
    errors.add(:base, "needs a phone number or a user id") if whatsapp_number.blank? && wa_user_id.blank?
  end
end
