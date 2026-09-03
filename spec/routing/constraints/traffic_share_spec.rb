# frozen_string_literal: true

require 'routing/constraints/traffic_share'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::TrafficShare do
  include ProviderFactory

  let(:operation) { build_operation }

  it 'пропускает провайдера с traffic_percentage 40' do
    provider = build_provider(traffic_percentage: 40)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает провайдера с traffic_percentage 0' do
    provider = build_provider(traffic_percentage: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'отсеивает провайдера с traffic_percentage 0 с причиной zero_traffic_share' do
    provider = build_provider(traffic_percentage: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation.reason).to eq('zero_traffic_share')
  end

  it 'отсеивает провайдера с traffic_percentage 0 с details, содержащим цифру' do
    provider = build_provider(traffic_percentage: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation.details).to match(/\d/)
  end

  it 'отсеивает провайдера с nil в traffic_percentage' do
    provider = build_provider(traffic_percentage: nil)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'пропускает fallback-провайдера spacepayments даже при нулевом трафике' do
    provider = build_provider(
      payment_system: described_class::FALLBACK_PROVIDER,
      traffic_percentage: 0
    )

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'reason входит в Routing::Reasons::SKIP' do
    provider = build_provider(traffic_percentage: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(Routing::Reasons::SKIP).to include(violation.reason)
  end
end
