# frozen_string_literal: true

require "bundler/setup"
require "ostruct"
require "graphql/anycable"
require "debug" unless ENV["CI"]

require_relative "support/graphql_schema"

subscription_store = GraphQL::AnyCable.config.subscription_store.to_s
broadcast_adapter = AnyCable.config.broadcast_adapter.to_s
require_relative "redis_helper" unless subscription_store == "postgres" || broadcast_adapter == "postgres"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec

  Kernel.srand config.seed
  config.order = :random
end
