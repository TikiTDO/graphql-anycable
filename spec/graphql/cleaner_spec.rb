# frozen_string_literal: true

RSpec.describe GraphQL::AnyCable::Cleaner do
  around do |ex|
    original_store_defined = GraphQL::AnyCable.instance_variable_defined?(:@subscription_store)
    original_store = GraphQL::AnyCable.instance_variable_get(:@subscription_store) if original_store_defined

    ex.run
  ensure
    if original_store_defined
      GraphQL::AnyCable.instance_variable_set(:@subscription_store, original_store)
    elsif GraphQL::AnyCable.instance_variable_defined?(:@subscription_store)
      GraphQL::AnyCable.remove_instance_variable(:@subscription_store)
    end
  end

  %i[clean clean_channels clean_subscriptions clean_fingerprint_subscriptions clean_topic_fingerprints].each do |method_name|
    it "delegates .#{method_name} to the configured subscription store cleaner" do
      cleaner = double("Cleaner", method_name => nil)
      store = double("SubscriptionStore", cleaner: cleaner)

      GraphQL::AnyCable.subscription_store = store

      described_class.public_send(method_name)

      expect(cleaner).to have_received(method_name)
    end
  end

  it "raises a helpful error when the configured store has no cleaner" do
    store = Object.new

    GraphQL::AnyCable.subscription_store = store

    expect { described_class.clean }.to raise_error(
      RuntimeError,
      /does not support cleanup/
    )
  end
end

RSpec.describe GraphQL::AnyCable::SubscriptionStores::Redis::Cleaner do
  subject(:cleaner) do
    described_class.new(
      redis_connector: ->(&block) { block.call($redis) },
      config: GraphQL::AnyCable.config
    )
  end

  let(:fingerprint) do
    ":productUpdated:/SomeSubscription/fBDZmJU1UGTorQWvOyUeaHVwUxJ3T9SEqnetj6SKGXc=/0/RBNvo1WzZ4oRRq0W9-hknpT7T8If536DEMBg9hyq_4o="
  end

  it "removes missing subscription ids from fingerprint sets" do
    $redis.sadd("graphql-subscriptions:#{fingerprint}", ["missing-subscription-id"])

    cleaner.clean_fingerprint_subscriptions

    expect($redis.smembers("graphql-subscriptions:#{fingerprint}")).to be_empty
  end

  it "removes topic fingerprints with no subscription set" do
    $redis.zadd("graphql-fingerprints::productUpdated:", 1, fingerprint)

    cleaner.clean_topic_fingerprints

    expect($redis.zrange("graphql-fingerprints::productUpdated:", 0, -1)).to be_empty
  end
end
