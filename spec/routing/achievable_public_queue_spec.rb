# frozen_string_literal: true

require 'json'
require_relative '../../lib/io/providers_loader'
require_relative '../../lib/io/queue_loader'
require_relative '../../lib/routing/achievable'
require_relative '../../lib/routing/constraints'
require_relative '../../lib/reporting/report_builder'

# Routing::Achievable на боевых данных. Фикстуры report_builder_spec
# синтетические: там никто никого не допускает, achievable выходит нулевым
# и регрессию не ловит. Здесь -- публичная очередь организаторов и таблица
# из ARCHITECTURE.md.
RSpec.describe Routing::Achievable do
  let(:providers) { Io::ProvidersLoader.load('reference/data/providers.json') }
  let(:operations) { Io::QueueLoader.load('reference/data/operations_queue_10.json').operations }

  let(:achievable) do
    external = providers.reject { |provider| provider.name == 'spacepayments' }
    eligibility = operations.to_h do |operation|
      names = external.select { |provider| Routing::Constraints.eligible?(provider, operation) }
      [operation.operation_id, names.map(&:name)]
    end
    described_class.for_queue(operations: operations, providers: providers,
                              eligibility: eligibility)
  end

  # vipay 40%, payflow 30% (допущены 4 заявки, но headroom хватает на 3),
  # quickpay 30% (op_103, 104, 108 -- больше некому).
  it 'даёт 40/30/30, а не паспортные 40/35/25' do
    expect(achievable.transform_values { |entry| entry[:achievable_bp] })
      .to eq('vipay' => 4000, 'payflow' => 3000, 'quickpay' => 3000)
  end

  it 'сохраняет паспортную цель payflow как 35%' do
    expect(achievable.fetch('payflow')[:target_bp]).to eq(3500)
  end

  it 'опускает достижимое payflow до 30%: в 35% на десяти заявках не попасть' do
    expect(achievable.fetch('payflow')[:achievable_bp]).to eq(3000)
  end
end
