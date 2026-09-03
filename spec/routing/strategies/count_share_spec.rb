# frozen_string_literal: true

require 'routing/share_ledger'
require 'routing/strategies/count_share'
require_relative '../../support/provider_factory'
require_relative '../../support/shared/strategy_contract'

RSpec.describe Routing::Strategies::CountShare do
  include ProviderFactory

  subject(:strategy) { described_class.new }

  let(:candidates) do
    [build_provider(payment_system: 'vipay', traffic_percentage: 40),
     build_provider(payment_system: 'payflow', traffic_percentage: 35),
     build_provider(payment_system: 'quickpay', traffic_percentage: 25)]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  it_behaves_like 'контракт стратегии'
end
