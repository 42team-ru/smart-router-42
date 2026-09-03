# frozen_string_literal: true

require 'routing/constraints/bank_filter'
require 'routing/reasons'
require_relative '../../support/provider_factory'

RSpec.describe Routing::Constraints::BankFilter do
  include ProviderFactory

  it 'отсеивает vipay для alfa в op_102 с каноническим details' do
    provider = build_provider(banks: %w[sberbank tinkoff vtb], exclude_banks: false)
    operation = build_operation(operation_id: 'op_102', bank: 'alfa')
    details = 'bank alfa не входит в banks [sberbank, tinkoff, vtb] (3 банка)'

    expect_violation(provider, operation, details)
  end

  it 'отсеивает vipay для gazprombank в op_104' do
    operation = build_operation(operation_id: 'op_104', bank: 'gazprombank')
    vipay = build_provider(banks: %w[sberbank tinkoff vtb], exclude_banks: false)

    expect(described_class.violation(vipay, operation, nil).reason).to eq('bank_not_in_list')
  end

  it 'отсеивает payflow для gazprombank в op_104' do
    operation = build_operation(operation_id: 'op_104', bank: 'gazprombank')
    payflow = build_provider(banks: %w[sberbank alfa], exclude_banks: false)

    expect(described_class.violation(payflow, operation, nil).reason).to eq('bank_not_in_list')
  end

  it 'пропускает quickpay с пустым списком банков для gazprombank' do
    provider = build_provider(banks: [], exclude_banks: false)
    operation = build_operation(operation_id: 'op_104', bank: 'gazprombank')

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает vipay для raiffeisen в op_108' do
    provider = build_provider(banks: %w[sberbank tinkoff vtb], exclude_banks: false)
    operation = build_operation(operation_id: 'op_108', bank: 'raiffeisen')

    expect(described_class.violation(provider, operation, nil).reason).to eq('bank_not_in_list')
  end

  it 'пропускает vipay для sberbank из белого списка' do
    provider = build_provider(banks: %w[sberbank tinkoff vtb], exclude_banks: false)
    operation = build_operation(bank: 'sberbank')

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает банк из чёрного списка с каноническим details' do
    provider = build_provider(banks: %w[sberbank], exclude_banks: true)
    operation = build_operation(bank: 'sberbank')
    details = 'bank sberbank входит в exclude_banks [sberbank] (1 банк)'

    expect_violation(provider, operation, details)
  end

  it 'пропускает банк, которого нет в чёрном списке' do
    provider = build_provider(banks: %w[sberbank], exclude_banks: true)
    operation = build_operation(bank: 'alfa')

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'пропускает любой банк, когда banks nil' do
    provider = build_provider(banks: nil)
    operation = build_operation(bank: 'unknown-bank')

    expect(described_class.violation(provider, operation, nil)).to be_nil
  end

  it 'отсеивает неизвестный банк в непустом белом списке' do
    operation = build_operation(bank: 'unknown-bank')
    white_list_provider = build_provider(banks: %w[sberbank tinkoff vtb], exclude_banks: false)

    expect(described_class.violation(white_list_provider, operation, nil).reason)
      .to eq('bank_not_in_list')
  end

  it 'reason входит в Routing::Reasons::SKIP' do
    provider = build_provider(banks: %w[sberbank], exclude_banks: false)
    operation = build_operation(bank: 'alfa')

    violation = described_class.violation(provider, operation, nil)

    expect(Routing::Reasons::SKIP).to include(violation.reason)
  end

  def expect_violation(provider, operation, details)
    expect(described_class.violation(provider, operation, nil)).to eq(
      Routing::Violation.new(reason: 'bank_not_in_list', details: details)
    )
  end
end
