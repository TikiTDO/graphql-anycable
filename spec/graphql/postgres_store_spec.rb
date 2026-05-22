# frozen_string_literal: true

require "json"

RSpec.describe GraphQL::AnyCable::SubscriptionStores::Postgres do
  let(:postgres_url) { ENV["POSTGRES_URL"] || ENV["DATABASE_URL"] }
  let(:pg_conn) { PG.connect(postgres_url) }
  let(:config) { GraphQL::AnyCable.config }
  let(:store) { described_class.new(config: config) }
  let(:subscription_id) { "postgres-store-subscription" }
  let(:channel_id) { "postgres-store-channel" }
  let(:events) { [double(topic: "productUpdated", fingerprint: "fingerprint-1")] }
  let(:data) do
    {
      query_string: "subscription { productUpdated { id } }",
      variables: "{}",
      context: "serialized-context",
      operation_name: "ProductUpdated",
      events: {"productUpdated" => "fingerprint-1"}.to_json
    }
  end

  around do |example|
    original_subscription_store = config.subscription_store
    original_postgres_url = config.postgres_url
    original_subscriptions_table = config.postgres_subscriptions_table
    original_events_table = config.postgres_subscription_events_table
    original_channels_table = config.postgres_channel_subscriptions_table

    example.run
  ensure
    config.subscription_store = original_subscription_store
    config.postgres_url = original_postgres_url
    config.postgres_subscriptions_table = original_subscriptions_table
    config.postgres_subscription_events_table = original_events_table
    config.postgres_channel_subscriptions_table = original_channels_table
  end

  before do
    skip "POSTGRES_URL or DATABASE_URL is required" unless postgres_url

    require "pg"

    config.subscription_store = :postgres
    config.postgres_url = postgres_url
    config.postgres_subscriptions_table = "graphql_anycable_test_subscriptions"
    config.postgres_subscription_events_table = "graphql_anycable_test_subscription_events"
    config.postgres_channel_subscriptions_table = "graphql_anycable_test_channel_subscriptions"

    create_tables
  end

  after do
    drop_tables if postgres_url
    pg_conn.close if defined?(@pg_conn) && !@pg_conn.finished?
  end

  it "stores, indexes, reads, and deletes subscriptions" do
    store.write_subscription(
      subscription_id,
      channel_id: channel_id,
      data: data,
      events: events,
      expiration_seconds: nil
    )

    expect(store.stream_for("fingerprint-1")).to eq("graphql-subscriptions:fingerprint-1")
    expect(store.fingerprints_for_topic("productUpdated")).to eq(["fingerprint-1"])
    expect(store.subscription_ids_for_fingerprints(["fingerprint-1"])).to eq("fingerprint-1" => [subscription_id])
    expect(store.subscription_exists?(subscription_id)).to be true
    expect(store.read_subscription(subscription_id)).to include(data.slice(:query_string, :variables, :context, :operation_name))

    store.delete_channel_subscriptions(channel_id)

    expect(store.subscription_exists?(subscription_id)).to be false
    expect(store.fingerprints_for_topic("productUpdated")).to eq([])
  end

  private

  def create_tables
    drop_tables
    pg_conn.exec(<<~SQL)
      CREATE TABLE graphql_anycable_test_subscriptions (
        id text PRIMARY KEY,
        query_string text NOT NULL,
        variables text NOT NULL,
        context text NOT NULL,
        operation_name text NOT NULL,
        events jsonb NOT NULL DEFAULT '{}',
        expires_at timestamp,
        created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE graphql_anycable_test_subscription_events (
        subscription_id text NOT NULL REFERENCES graphql_anycable_test_subscriptions(id) ON DELETE CASCADE,
        topic text NOT NULL,
        fingerprint text NOT NULL,
        created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (subscription_id, topic, fingerprint)
      );

      CREATE INDEX index_graphql_anycable_test_events_topic_fingerprint
        ON graphql_anycable_test_subscription_events (topic, fingerprint);

      CREATE TABLE graphql_anycable_test_channel_subscriptions (
        channel_id text NOT NULL,
        subscription_id text NOT NULL REFERENCES graphql_anycable_test_subscriptions(id) ON DELETE CASCADE,
        created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (channel_id, subscription_id)
      );
    SQL
  end

  def drop_tables
    pg_conn.exec(<<~SQL)
      DROP TABLE IF EXISTS graphql_anycable_test_channel_subscriptions;
      DROP TABLE IF EXISTS graphql_anycable_test_subscription_events;
      DROP TABLE IF EXISTS graphql_anycable_test_subscriptions;
    SQL
  end
end
