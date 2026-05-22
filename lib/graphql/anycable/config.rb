# frozen_string_literal: true

require "anyway"

module GraphQL
  module AnyCable
    class Config < Anyway::Config
      config_name :graphql_anycable
      env_prefix :graphql_anycable

      attr_config subscription_expiration_seconds: nil
      attr_config subscription_store: nil
      attr_config use_redis_object_on_cleanup: true
      attr_config redis_prefix: "graphql" # Here, we set clear redis_prefix without any hyphen. The hyphen is added at the end of this value on our side.
      attr_config postgres_url: nil
      attr_config postgres_subscriptions_table: "graphql_anycable_subscriptions"
      attr_config postgres_subscription_events_table: "graphql_anycable_subscription_events"
      attr_config postgres_channel_subscriptions_table: "graphql_anycable_channel_subscriptions"
    end
  end
end
