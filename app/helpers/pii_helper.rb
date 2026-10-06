# How customer identity is shown to the operator. With DEMO_MASK_PII=1
# (config.whatsapp.mask_pii) phone numbers show their last four digits and names
# become "Customer #<id>", so a screen share or a demo leaks nothing
# (docs/v2/DESIGN.md §11). Every admin view goes through these helpers; none
# prints a customer's number or name directly.
module PiiHelper
  DOT = "•".freeze

  def pii_masked?
    Rails.application.config.whatsapp.mask_pii ? true : false
  end

  def display_name(customer)
    return "—" unless customer
    return "Customer ##{customer.id}" if pii_masked?

    customer.display_name.presence || "Customer ##{customer.id}"
  end

  # "+15550001234", or "+•• ••••• •1234" when masked. Customers Meta identifies
  # only by a business-scoped user id (username users) have no number.
  def display_phone(customer)
    return "—" unless customer
    return display_user_id(customer) if customer.whatsapp_number.blank?
    return "+#{customer.whatsapp_number}" unless pii_masked?

    "+#{DOT * 2} #{DOT * 5} #{DOT}#{customer.whatsapp_number.to_s.gsub(/\D/, '').last(4).rjust(4, DOT)}"
  end

  def display_user_id(customer)
    tail = customer.wa_user_id.to_s.last(pii_masked? ? 4 : 6)
    "username user #{DOT * 3}#{tail}"
  end

  # "Jordan · +15550001234" for list cells.
  def display_customer(customer)
    "#{display_name(customer)} · #{display_phone(customer)}"
  end

  # Meta ids embed phone numbers, so they are never shown. A reference that
  # must be recognisable (a delivery item) shows its last six characters.
  def mask_ref(ref)
    return "—" if ref.blank?

    "…#{ref.to_s.last(6)}"
  end

  # Free text from outside (message bodies, Meta error text, outcome details)
  # with any Meta message id removed.
  def scrub_ids(text)
    text.to_s.gsub(Redact::WAMID, "[id]")
  end
end
