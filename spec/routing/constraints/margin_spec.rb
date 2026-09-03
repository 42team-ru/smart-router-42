# frozen_string_literal: true

require 'routing/constraints/margin'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::Margin do
  include ProviderFactory

  it 'пропускает положительную маржу' do
    provider = build_provider(provider_margin_pct: 1.2, merchant_margin_pct: 1.5)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'отсеивает отрицательную маржу с каноническим details' do
    expect_negative_margin_violation(
      described_class.violation(negative_margin_provider, build_operation, nil)
    )
  end

  it 'пропускает отрицательную маржу при явном соглашении' do
    result = described_class.violation(negative_margin_provider(agreement: true), build_operation,
                                       nil)

    expect(result).to be_nil
  end

  it 'пропускает равные проценты' do
    provider = build_provider(provider_margin_pct: 1.5, merchant_margin_pct: 1.5)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'пропускает провайдера без одного из процентов' do
    provider = build_provider(provider_margin_pct: nil)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  it 'сравнивает десятичные проценты через Rational' do
    provider = build_provider(provider_margin_pct: 0.3, merchant_margin_pct: 0.1 + 0.2)

    expect(described_class.violation(provider, build_operation, nil)).to be_nil
  end

  def expect_negative_margin_violation(result)
    expect(result).to have_attributes(
      reason: 'negative_margin',
      details: 'provider_margin_pct 1.8 > merchant_margin_pct 1.5, allow_negative_agreement false'
    )
  end

  def negative_margin_provider(agreement: false)
    build_provider(provider_margin_pct: 1.8, merchant_margin_pct: 1.5,
                   allow_negative_agreement: agreement)
  end
end
