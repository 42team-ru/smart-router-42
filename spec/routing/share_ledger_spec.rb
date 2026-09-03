# frozen_string_literal: true

require 'routing/share_ledger'
require_relative '../support/provider_factory'
require_relative '../support/shared/share_counters'

RSpec.describe Routing::ShareLedger do
  include ProviderFactory

  subject(:ledger) { described_class.new }

  it_behaves_like 'счётчики долей'

  it 'принимает provider-объект и строку одинаково' do
    provider = build_provider
    operation = build_operation
    ledger.reserve(provider, operation)

    expect(ledger.count_units(provider)).to eq(ledger.count_units('vipay'))
  end

  it 'отклоняет повторный reserve' do
    operation = build_operation
    ledger.reserve('vipay', operation)

    expect { ledger.reserve('vipay', operation) }.to raise_error(ArgumentError)
  end

  it 'отклоняет неизвестный резерв' do
    expect { ledger.commit('vipay', build_operation) }.to raise_error(ArgumentError)
  end

  it 'отклоняет нулевую сумму' do
    expect { ledger.reserve('vipay', build_operation(amount: 0)) }.to raise_error(ArgumentError)
  end
end
