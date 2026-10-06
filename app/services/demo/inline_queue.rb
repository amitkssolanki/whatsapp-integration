module Demo
  # An ActiveJob adapter that keeps jobs in memory so the demo simulator can run
  # them in the foreground, in order, without Solid Queue workers (and without
  # leaving rows in the queue tables that a real worker could pick up later).
  #
  # Jobs scheduled for later (a retry in 30 seconds) wait until the simulator
  # decides time has passed: #drain(scheduled: true).
  class InlineQueue
    attr_reader :performed

    def initialize
      @pending = []
      @performed = 0
    end

    def enqueue(job)
      @pending << [ job.serialize, nil ]
      job.successfully_enqueued = true
    end

    def enqueue_at(job, timestamp)
      @pending << [ job.serialize, timestamp ]
      job.successfully_enqueued = true
    end

    def enqueue_after_transaction_commit? = false

    # True when no job, due or delayed, is waiting.
    def empty? = @pending.empty?

    def scheduled? = @pending.any? { |_data, at| at }

    # Runs every job that is due, including the ones those jobs enqueue. With
    # `scheduled: true` the delayed ones count as due too.
    def drain(scheduled: false)
      while (index = @pending.index { |_data, at| scheduled || at.nil? })
        data, = @pending.delete_at(index)
        ActiveJob::Base.execute(data)
        @performed += 1
      end
    end
  end
end
