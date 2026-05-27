# frozen_string_literal: true

require "json"

module GraphQL
  module AnyCable
    module SubscriptionStores
      class Redis
        SUBSCRIPTION_PREFIX = "subscription:"  # HASH: Stores subscription data: query, context, ...
        FINGERPRINTS_PREFIX = "fingerprints:"  # ZSET: To get fingerprints by topic
        SUBSCRIPTIONS_PREFIX = "subscriptions:" # SET:  To get subscriptions by fingerprint
        CHANNEL_PREFIX = "channel:"       # SET:  Auxiliary structure for whole channel's subscriptions cleanup

        def initialize(redis_connector:, config:)
          @redis_connector = redis_connector
          @config = config
        end

        def stream_for(fingerprint)
          redis_key(SUBSCRIPTIONS_PREFIX) + fingerprint
        end

        def fingerprints_for_topic(topic)
          with_redis { |redis| redis.zrange(redis_key(FINGERPRINTS_PREFIX) + topic, 0, -1) }
        end

        def subscription_ids_for_fingerprints(fingerprints)
          return {} if fingerprints.empty?

          with_redis do |redis|
            fingerprints.zip(
              redis.pipelined do |pipeline|
                fingerprints.each do |fingerprint|
                  pipeline.smembers(stream_for(fingerprint))
                end
              end
            ).to_h
          end
        end

        def subscription_exists?(subscription_id)
          with_redis { |redis| redis.exists?(redis_key(SUBSCRIPTION_PREFIX) + subscription_id) }
        end

        def write_subscription(subscription_id, channel_id:, data:, events:, expiration_seconds:)
          with_redis do |redis|
            redis.multi do |pipeline|
              pipeline.sadd(redis_key(CHANNEL_PREFIX) + channel_id, [subscription_id])
              pipeline.mapped_hmset(redis_key(SUBSCRIPTION_PREFIX) + subscription_id, data)
              events.each do |event|
                pipeline.zincrby(redis_key(FINGERPRINTS_PREFIX) + event.topic, 1, event.fingerprint)
                pipeline.sadd(stream_for(event.fingerprint), [subscription_id])
              end
              next unless expiration_seconds

              pipeline.expire(redis_key(CHANNEL_PREFIX) + channel_id, expiration_seconds)
              pipeline.expire(redis_key(SUBSCRIPTION_PREFIX) + subscription_id, expiration_seconds)
            end
          end
        end

        def read_subscription(subscription_id)
          with_redis do |redis|
            subscription = redis.mapped_hmget(
              "#{redis_key(SUBSCRIPTION_PREFIX)}#{subscription_id}",
              :query_string, :variables, :context, :operation_name
            )
            return if subscription.values.all?(&:nil?) # Redis returns hash with all nils for missing key

            subscription.transform_keys(&:to_sym)
          end
        end

        def delete_channel_subscriptions(channel_id)
          with_redis do |redis|
            redis.smembers(redis_key(CHANNEL_PREFIX) + channel_id).each do |subscription_id|
              delete_subscription(subscription_id, redis: redis)
            end
            redis.del(redis_key(CHANNEL_PREFIX) + channel_id)
          end
        end

        def delete_subscription(subscription_id, redis: nil)
          return with_redis { |conn| delete_subscription(subscription_id, redis: conn) } unless redis

          events = redis.hget(redis_key(SUBSCRIPTION_PREFIX) + subscription_id, :events)
          events = events ? JSON.parse(events) : {}
          fingerprint_subscriptions = {}
          redis.pipelined do |pipeline|
            events.each do |topic, fingerprint|
              pipeline.srem(stream_for(fingerprint), subscription_id)
              score = pipeline.zincrby(redis_key(FINGERPRINTS_PREFIX) + topic, -1, fingerprint)
              fingerprint_subscriptions[redis_key(FINGERPRINTS_PREFIX) + topic] = score
            end
            pipeline.del(redis_key(SUBSCRIPTION_PREFIX) + subscription_id)
          end
          redis.pipelined do |pipeline|
            fingerprint_subscriptions.each do |key, score|
              pipeline.zremrangebyscore(key, "-inf", "0") if score.value.zero?
            end
          end
        end

        def stats(scan_count:, include_subscriptions: false)
          result = {total: {}}

          with_redis do |redis|
            list_prefixes_keys.each do |name, prefix|
              result[:total][name] = count_by_scan(redis, match: "#{prefix}*", scan_count: scan_count)
            end

            if include_subscriptions
              result[:subscriptions] = group_subscription_stats(redis, scan_count: scan_count)
            end
          end

          result
        end

        private

        attr_reader :config, :redis_connector

        def with_redis(&block)
          redis_connector.call(&block)
        end

        def redis_key(prefix)
          "#{config.redis_prefix}-#{prefix}"
        end

        def count_by_scan(redis, match:, scan_count:)
          total = 0
          cursor = "0"

          loop do
            cursor, keys = redis.scan(cursor, match: match, count: scan_count)
            total += keys.count

            break if cursor == "0"
          end

          total
        end

        def group_subscription_stats(redis, scan_count:)
          subscription_groups = {}

          redis.scan_each(match: "#{list_prefixes_keys[:fingerprints]}*", count: scan_count) do |fingerprint_key|
            subscription_name = fingerprint_key.gsub(/#{list_prefixes_keys[:fingerprints]}|:/, "")
            subscription_groups[subscription_name] = 0

            redis.zscan_each(fingerprint_key) do |data|
              redis.sscan_each("#{list_prefixes_keys[:subscriptions]}#{data[0]}") do |subscription_key|
                next unless redis.exists?("#{list_prefixes_keys[:subscription]}#{subscription_key}")

                subscription_groups[subscription_name] += 1
              end
            end
          end

          subscription_groups
        end

        def list_prefixes_keys
          {
            subscription: redis_key(SUBSCRIPTION_PREFIX),
            fingerprints: redis_key(FINGERPRINTS_PREFIX),
            subscriptions: redis_key(SUBSCRIPTIONS_PREFIX),
            channel: redis_key(CHANNEL_PREFIX)
          }
        end
      end
    end
  end
end
