# frozen_string_literal: true

require 'routing/constraints/requisites'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::Requisites do
  include ProviderFactory

  let(:operation) { build_operation }

  it 'пропускает провайдера с available_requisites 12' do
    provider = build_provider(available_requisites: 12)

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает провайдера с available_requisites 0' do
    provider = build_provider(available_requisites: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'отсеивает провайдера с available_requisites 0 с причиной no_requisites' do
    provider = build_provider(available_requisites: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation.reason).to eq('no_requisites')
  end

  it 'отсеивает провайдера с available_requisites 0 с details, содержащим цифру' do
    provider = build_provider(available_requisites: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(violation.details).to match(/\d/)
  end

  it 'отсеивает провайдера с nil в available_requisites' do
    provider = build_provider(available_requisites: nil)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'отсеивает провайдера с отрицательным available_requisites' do
    provider = build_provider(available_requisites: -1)

    violation = described_class.violation(provider, operation, nil)

    expect(violation).to be_a(Routing::Violation)
  end

  it 'reason входит в Routing::Reasons::SKIP' do
    provider = build_provider(available_requisites: 0)

    violation = described_class.violation(provider, operation, nil)

    expect(Routing::Reasons::SKIP).to include(violation.reason)
  end
end
