module Webhooks
  # Matches errors that say something about the infrastructure (database
  # connectivity, locks, timeouts) rather than about the work being done, so
  # retrying the same work later can succeed. Used both in `rescue` clauses and
  # in `retry_on`, which accept any object that responds to `===`.
  #
  # Verified against activerecord 8.1.4:
  #   lib/active_record/errors.rb
  #     ConnectionNotEstablished      pool/connect failures; parent of ConnectionTimeoutError
  #                                   and DatabaseConnectionError (also "connection is closed")
  #     QueryAborted                  parent of ConnectionFailed (the connection dropped while a
  #                                   query was in flight, e.g. Postgres restarted), StatementTimeout,
  #                                   QueryCanceled and AdapterTimeout
  #     TransactionRollbackError      parent of Deadlocked and SerializationFailure
  #     LockWaitTimeout
  #   lib/active_record/connection_adapters/postgresql_adapter.rb (#translate_exception)
  #     SQLSTATE 57014 -> QueryCanceled (also what `statement_timeout` raises on PostgreSQL),
  #     55P03 -> LockWaitTimeout, 40P01 -> Deadlocked, 40001 -> SerializationFailure,
  #     PG::ConnectionBad ending in "\n" -> ConnectionFailed, other ConnectionBad -> ConnectionNotEstablished.
  #     A server shutdown in progress (57P01/57P02/57P03) carries a SQLSTATE the adapter does not
  #     map, so it surfaces as a plain StatementInvalid whose #cause is the PG error: the PG
  #     classes below are therefore also matched on the cause chain.
  module InfrastructureError
    ACTIVE_RECORD = [
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::QueryAborted,
      ActiveRecord::TransactionRollbackError,
      ActiveRecord::LockWaitTimeout
    ].freeze

    PG_DRIVER = [
      PG::ConnectionBad,
      PG::UnableToSend,
      PG::AdminShutdown,
      PG::CrashShutdown,
      PG::CannotConnectNow
    ].freeze

    CLASSES = (ACTIVE_RECORD + PG_DRIVER).freeze
    MAX_CAUSE_DEPTH = 5

    def self.===(error)
      depth = 0
      while error && depth <= MAX_CAUSE_DEPTH
        return true if CLASSES.any? { |klass| klass === error }

        error = error.cause
        depth += 1
      end
      false
    end
  end
end
