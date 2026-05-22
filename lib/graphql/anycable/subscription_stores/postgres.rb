# frozen_string_literal: true

require "time"

module GraphQL
  module AnyCable
    module SubscriptionStores
      class Postgres
        SUBSCRIPTIONS_PREFIX = "subscriptions:"

        def initialize(config:)
          load_pg!

          @config = config
          @mutex = Mutex.new
          @subscriptions_table = quote_table_name(config.postgres_subscriptions_table)
          @events_table = quote_table_name(config.postgres_subscription_events_table)
          @channels_table = quote_table_name(config.postgres_channel_subscriptions_table)
        end

        def stream_for(fingerprint)
          "#{config.redis_prefix}-#{SUBSCRIPTIONS_PREFIX}#{fingerprint}"
        end

        def fingerprints_for_topic(topic)
          with_connection do |conn|
            conn.exec_params(<<~SQL, [topic]).map { |row| row.fetch("fingerprint") }
              SELECT events.fingerprint
              FROM #{events_table} events
              INNER JOIN #{subscriptions_table} subscriptions
                ON subscriptions.id = events.subscription_id
              WHERE events.topic = $1
                AND (subscriptions.expires_at IS NULL OR subscriptions.expires_at > CURRENT_TIMESTAMP)
              GROUP BY events.fingerprint
              ORDER BY COUNT(*) ASC, MIN(events.created_at) ASC
            SQL
          end
        end

        def subscription_ids_for_fingerprints(fingerprints)
          result = fingerprints.to_h { |fingerprint| [fingerprint, []] }
          return result if fingerprints.empty?

          with_connection do |conn|
            conn.exec_params(<<~SQL, fingerprints).each do |row|
              SELECT events.fingerprint, events.subscription_id
              FROM #{events_table} events
              INNER JOIN #{subscriptions_table} subscriptions
                ON subscriptions.id = events.subscription_id
              WHERE events.fingerprint IN (#{placeholders(fingerprints.length)})
                AND (subscriptions.expires_at IS NULL OR subscriptions.expires_at > CURRENT_TIMESTAMP)
              ORDER BY events.fingerprint ASC, events.created_at ASC
            SQL
              result[row.fetch("fingerprint")] << row.fetch("subscription_id")
            end
          end

          result
        end

        def subscription_exists?(subscription_id)
          with_connection do |conn|
            conn.exec_params(<<~SQL, [subscription_id]).getvalue(0, 0) == "t"
              SELECT EXISTS (
                SELECT 1
                FROM #{subscriptions_table}
                WHERE id = $1
                  AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
              )
            SQL
          end
        end

        def write_subscription(subscription_id, channel_id:, data:, events:, expiration_seconds:)
          expires_at = expiration_seconds ? (Time.now.utc + expiration_seconds).iso8601(6) : nil
          subscription_params = [
            subscription_id,
            data.fetch(:query_string),
            data.fetch(:variables),
            data.fetch(:context),
            data.fetch(:operation_name),
            data.fetch(:events),
            expires_at
          ]

          with_connection do |conn|
            transaction(conn) do
              conn.exec_params(<<~SQL, subscription_params)
                INSERT INTO #{subscriptions_table}
                  (id, query_string, variables, context, operation_name, events, expires_at, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                ON CONFLICT (id) DO UPDATE SET
                  query_string = EXCLUDED.query_string,
                  variables = EXCLUDED.variables,
                  context = EXCLUDED.context,
                  operation_name = EXCLUDED.operation_name,
                  events = EXCLUDED.events,
                  expires_at = EXCLUDED.expires_at,
                  updated_at = CURRENT_TIMESTAMP
              SQL

              conn.exec_params("DELETE FROM #{events_table} WHERE subscription_id = $1", [subscription_id])
              conn.exec_params("DELETE FROM #{channels_table} WHERE subscription_id = $1", [subscription_id])
              conn.exec_params(<<~SQL, [channel_id, subscription_id])
                INSERT INTO #{channels_table} (channel_id, subscription_id, created_at)
                VALUES ($1, $2, CURRENT_TIMESTAMP)
                ON CONFLICT (channel_id, subscription_id) DO NOTHING
              SQL

              events.each do |event|
                conn.exec_params(<<~SQL, [subscription_id, event.topic, event.fingerprint])
                  INSERT INTO #{events_table} (subscription_id, topic, fingerprint, created_at)
                  VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
                  ON CONFLICT (subscription_id, topic, fingerprint) DO NOTHING
                SQL
              end
            end
          end
        end

        def read_subscription(subscription_id)
          with_connection do |conn|
            result = conn.exec_params(<<~SQL, [subscription_id])
              SELECT query_string, variables, context, operation_name
              FROM #{subscriptions_table}
              WHERE id = $1
                AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
            SQL
            return if result.ntuples.zero?

            result.first.transform_keys(&:to_sym)
          end
        end

        def delete_channel_subscriptions(channel_id)
          with_connection do |conn|
            transaction(conn) do
              conn.exec_params(<<~SQL, [channel_id])
                DELETE FROM #{subscriptions_table}
                WHERE id IN (
                  SELECT subscription_id
                  FROM #{channels_table}
                  WHERE channel_id = $1
                )
              SQL
              conn.exec_params("DELETE FROM #{channels_table} WHERE channel_id = $1", [channel_id])
            end
          end
        end

        def delete_subscription(subscription_id)
          with_connection do |conn|
            conn.exec_params("DELETE FROM #{subscriptions_table} WHERE id = $1", [subscription_id])
          end
        end

        private

        attr_reader :channels_table, :config, :events_table, :mutex, :subscriptions_table

        def load_pg!
          require "pg"
        rescue LoadError
          raise "Please, install the pg gem to use Postgres GraphQL::AnyCable subscriptions"
        end

        def with_connection
          mutex.synchronize { yield connection }
        end

        def connection
          @connection ||= ::PG.connect(postgres_url)
        end

        def postgres_url
          config.postgres_url ||
            (::AnyCable.config.postgres_url if defined?(::AnyCable) && ::AnyCable.config.respond_to?(:postgres_url)) ||
            ENV["DATABASE_URL"]
        end

        def transaction(conn)
          conn.exec("BEGIN")
          yield
          conn.exec("COMMIT")
        rescue StandardError
          conn.exec("ROLLBACK")
          raise
        end

        def placeholders(count)
          Array.new(count) { |index| "$#{index + 1}" }.join(", ")
        end

        def quote_table_name(name)
          parts = name.to_s.split(".")
          raise ArgumentError, "Postgres table name cannot be empty" if parts.empty? || parts.any?(&:empty?)
          raise ArgumentError, "Postgres table name must be table or schema.table" if parts.size > 2

          parts.map { |part| ::PG::Connection.quote_ident(part) }.join(".")
        end
      end
    end
  end
end
