# One structured line per event: `event=webhook.stored delivery_id=12 status=received`.
#
# Logs carry our own ids (request_id, delivery_id, message_id, order_id,
# job_id) and error classes, never Meta message ids (they embed phone numbers),
# phone numbers, names or payload bodies. Fields that look like PII are
# rejected so a mistake fails loudly in development and test, and is dropped
# in production.
module AppLog
  FORBIDDEN_FIELDS = %i[
    body raw_body payload text name display_name phone whatsapp_number wa_id from to
    wa_message_id wamid message_id_meta recipient recipient_id contact
  ].freeze

  def self.event(name, **fields)
    write(:info, name, fields)
  end

  # For events an operator should notice (an experiment overriding a safety
  # guard, Meta contradicting our own state).
  def self.warn(name, **fields)
    write(:warn, name, fields)
  end

  def self.write(level, name, fields)
    forbidden = fields.keys & FORBIDDEN_FIELDS
    raise ArgumentError, "AppLog must not log #{forbidden.join(', ')}" if forbidden.any? && !Rails.env.production?

    pairs = fields.except(*FORBIDDEN_FIELDS).compact.map { |key, value| "#{key}=#{format_value(value)}" }
    Rails.logger.public_send(level, ([ "event=#{name}" ] + pairs).join(" "))
  end
  private_class_method :write

  # Runs a block with SQL debug logging off. insert_all/upsert render values
  # inline in the SQL text, where attribute filtering cannot reach them, so
  # statements that carry phone numbers, names or Meta ids run through here.
  def self.quietly(&block)
    Rails.logger.silence(Logger::INFO, &block)
  end

  def self.format_value(value)
    text = value.to_s
    text.match?(/\A[\w.:\-\/]+\z/) ? text : text.inspect
  end
  private_class_method :format_value
end
