# frozen_string_literal: true

require "graphql"

require_relative "graphql/anycable/version"
require_relative "graphql/anycable/cleaner"
require_relative "graphql/anycable/config"
require_relative "graphql/anycable/subscription_stores/redis"
require_relative "graphql/anycable/subscription_stores/postgres"
require_relative "graphql/anycable/railtie" if defined?(Rails)
require_relative "graphql/anycable/stats"
require_relative "graphql/subscriptions/anycable_subscriptions"

module GraphQL
  module AnyCable
    class << self
      attr_writer :subscription_store

      def use(schema, **opts)
        schema.use(GraphQL::Subscriptions::AnyCableSubscriptions, **opts)
      end

      def stats(**opts)
        Stats.new(**opts).collect
      end

      def redis
        warn "Usage of `GraphQL::AnyCable.redis` is deprecated. Instead of `GraphQL::AnyCable.redis.whatever` use `GraphQL::AnyCable.with_redis { |redis| redis.whatever }`"
        @redis ||= with_redis { |conn| conn }
      end

      def redis=(connector)
        @redis_connector = if connector.is_a?(::Proc)
          connector
        else
          ->(&block) { block.call connector }
        end
      end

      def with_redis(&block)
        @redis_connector || default_redis_connector
        @redis_connector.call(&block)
      end

      def subscription_store
        @subscription_store ||= default_subscription_store
      end

      def with_subscription_store(&block)
        block.call(subscription_store)
      end

      def config
        @config ||= Config.new
      end

      def configure
        yield(config) if block_given?
      end

      private

      def default_redis_connector
        adapter = ::AnyCable.broadcast_adapter
        redis_adapter = defined?(::AnyCable::BroadcastAdapters::Redis) && ::AnyCable::BroadcastAdapters::Redis
        unless redis_adapter && adapter.is_a?(redis_adapter)
          raise "Unsupported AnyCable adapter: #{adapter.class}. " \
                "Please, configure Redis connector manually:\n\n" \
                "  GraphQL::AnyCable.configure do |config|\n" \
                "    config.redis = Redis.new(url: 'redis://localhost:6379/0')\n" \
                "  end\n"
        end

        self.redis = ::AnyCable.broadcast_adapter.redis_conn
      end

      def default_subscription_store
        adapter = config.subscription_store&.to_sym || inferred_subscription_store

        case adapter
        when :redis
          SubscriptionStores::Redis.new(redis_connector: ->(&block) { with_redis(&block) }, config: config)
        when :postgres
          SubscriptionStores::Postgres.new(config: config)
        else
          raise "Unsupported GraphQL::AnyCable subscription store: #{adapter.inspect}"
        end
      end

      def inferred_subscription_store
        adapter = ::AnyCable.broadcast_adapter
        return :redis if defined?(::AnyCable::BroadcastAdapters::Redis) && adapter.is_a?(::AnyCable::BroadcastAdapters::Redis)

        postgres_adapter = defined?(::AnyCable::BroadcastAdapters::Postgres) && ::AnyCable::BroadcastAdapters::Postgres
        return :postgres if postgres_adapter && adapter.instance_of?(postgres_adapter)

        :redis
      end
    end
  end
end
