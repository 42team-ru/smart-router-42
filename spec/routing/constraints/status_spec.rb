# frozen_string_literal: true

require 'routing/constraints/status'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::Status do
  include ProviderFactory

  let(:operation) { build_operation }

  it 'пропускает провайдера со статусом active' do
    provider = build_provider(status: 'active')

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает провайдера со статусом suspended' do
    provider = build_provider(status: 'suspended')

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'отсеивает провайдера со статусом suspended с причиной provider_inactive' do
    provider = build_provider(status: 'suspended')

    violation = described_class.violation(provider, operation, nil)

    expect(violation.reason).to eq('provider_inactive')
  end

  it 'отсеивает провайдера со статусом suspended с details, содержащим цифру' do
    provider = build_provider(status: 'suspended')

    violation = described_class.violation(provider, operation, nil)

    expect(violation.details).to match(/\d/)
  end

  it 'отсеивает провайдера с nil в status' do
    provider = build_provider(status: nil)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'reason входит в Routing::Reasons::SKIP' do
    provider = build_provider(status: 'suspended')

    violation = described_class.violation(provider, operation, nil)

    expect(Routing::Reasons::SKIP).to include(violation.reason)
  end
end
