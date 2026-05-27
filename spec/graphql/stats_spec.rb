# frozen_string_literal: true

RSpec.describe GraphQL::AnyCable::Stats do
  it "delegates collection to the configured subscription store" do
    original_store_defined = GraphQL::AnyCable.instance_variable_defined?(:@subscription_store)
    original_store = GraphQL::AnyCable.instance_variable_get(:@subscription_store) if original_store_defined
    store = instance_double("SubscriptionStore")

    allow(store).to receive(:stats).with(scan_count: 25, include_subscriptions: true).and_return(total: {})
    GraphQL::AnyCable.subscription_store = store

    expect(described_class.new(scan_count: 25, include_subscriptions: true).collect).to eq(total: {})
  ensure
    if original_store_defined
      GraphQL::AnyCable.instance_variable_set(:@subscription_store, original_store)
    elsif GraphQL::AnyCable.instance_variable_defined?(:@subscription_store)
      GraphQL::AnyCable.remove_instance_variable(:@subscription_store)
    end
  end

  describe "#collect" do
    let(:query) do
      <<~GRAPHQL
        subscription SomeSubscription {
          productUpdated { id }
        }
      GRAPHQL
    end

    let(:query2) do
      <<~GRAPHQL
        subscription SomeSubscription {
          productCreated { id title }
        }
      GRAPHQL
    end

    let(:channel) do
      socket = double("Socket", istate: AnyCable::Socket::State.new({}))
      connection = double("Connection", anycable_socket: socket)
      double("Channel", id: "legacy_id", params: {"channelId" => "legacy_id"}, stream_from: nil, connection: connection)
    end

    let(:subscription_id) do
      "some-truly-random-number"
    end

    before do
      res = AnycableSchema.execute(
        query: query,
        context: {channel: channel, subscription_id: subscription_id},
        variables: {},
        operation_name: "SomeSubscription"
      )
      expect(res.to_h.fetch("errors", [])).to be_empty

      res2 = AnycableSchema.execute(
        query: query2,
        context: {channel: channel, subscription_id: subscription_id},
        variables: {},
        operation_name: "SomeSubscription"
      )
      expect(res2.to_h.fetch("errors", [])).to be_empty
    end

    context "when include_subscriptions is false" do
      let(:expected_result) do
        {total: {subscription: 1, fingerprints: 2, subscriptions: 2, channel: 1}}
      end

      it "returns total stat" do
        expect(subject.collect).to eq(expected_result)
      end
    end

    context "when include_subscriptions is true" do
      subject { described_class.new(include_subscriptions: true) }

      let(:expected_result) do
        {
          total: {subscription: 1, fingerprints: 2, subscriptions: 2, channel: 1},
          subscriptions: {
            "productCreated" => 1,
            "productUpdated" => 1
          }
        }
      end

      it "returns total stat with grouped subscription stats" do
        expect(subject.collect).to eq(expected_result)
      end
    end
  end
end
