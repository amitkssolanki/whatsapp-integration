require "json"
require "logger"
require "active_support"
require "active_support/tagged_logging"

# One JSON object per log line, for Docker's json-file driver (production).
#
# Tags (ActiveSupport::TaggedLogging) are emitted as an array in `tags`, never
# folded into a single field. The two ids operators correlate on are lifted out
# of them:
#
#   request_id  the first tag of a web request (config.log_tags = [:request_id])
#   job_id      the Active Job id, which ActiveJob logs as the third tag of a job:
#               ["ActiveJob", "SendMessageJob", "<uuid>"]
#
# A line written by a job carries `tags` and `job_id` but no request_id; a line
# written while a request is being served carries `request_id`; a job that runs
# inline inside a request carries both.
#
# Loaded with require_relative from config/environments/production.rb, which
# runs before autoloading is available (lib/json_log_formatter.rb is ignored by
# the autoloader in config/application.rb for that reason).
class JsonLogFormatter < ::Logger::Formatter
  include ActiveSupport::TaggedLogging::Formatter

  ACTIVE_JOB_TAG = "ActiveJob".freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def call(severity, time, _progname, message)
    line = { time: time.utc.iso8601(3), level: severity, message: msg2str(message).strip }
    add_tags(line, current_tags)
    "#{JSON.generate(line)}\n"
  end

  private

  def add_tags(line, tags)
    return if tags.empty?

    line[:tags] = tags.map(&:to_s)
    job_index = tags.index(ACTIVE_JOB_TAG)
    line[:request_id] = tags.first.to_s unless job_index == 0
    job_id = job_id_from(tags, job_index)
    line[:job_id] = job_id if job_id
  end

  # ["ActiveJob", "SomeJob", "<job_id>"], possibly preceded by a request id.
  def job_id_from(tags, job_index)
    candidate = tags[job_index + 2] if job_index
    candidate.to_s if candidate.to_s.match?(UUID)
  end
end
