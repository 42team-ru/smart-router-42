# frozen_string_literal: true

require 'json'
require_relative '../../lib/io/providers_loader'
require_relative '../../lib/io/queue_loader'
require_relative '../../lib/routing/achievable'
require_relative '../../lib/routing/constraints'
require_relative '../../lib/reporting/report_builder'
require_relative '../../lib/execution/outcome'

# Routing::Achievable на боевых данных. Фикстуры report_builder_spec
# синтетические: там никто никого не допускает, achievable выходит нулевым
# и регрессию не ловит. Здесь -- публичная очередь организаторов и таблица
# из ARCHITECTURE.md.
RSpec.describe Routing::Achievable do
  let(:providers) { Io::ProvidersLoader.load('reference/data/providers.json') }
  let(:operations) { Io::QueueLoader.load('reference/data/operations_queue_10.json').operations }

  let(:eligibility) do
    external = providers.reject { |provider| provider.name == 'spacepayments' }
    operations.to_h do |operation|
      names = external.select { |provider| Routing::Constraints.eligible?(provider, operation) }
      [operation.operation_id, names.map(&:name)]
    end
  end

  let(:achievable) do
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

  describe '.for_volume на той же публичной очереди' do
    let(:achievable_volume) do
      described_class.for_volume(operations: operations, providers: providers,
                                 eligibility: eligibility)
    end

    # op_103/104/108 суммарно 195 000 -- крупные операции, допустимые только
    # quickpay (vipay/payflow не проходят по сумме и/или банку). Даже
    # приближённая верхняя граница (см. комментарий у for_volume) не может
    # опустить его ниже этой суммы -- допуск, а не деньги, здесь потолок.
    it 'форсирует quickpay нижней границей по сумме singleton-операций' do
      expect(achievable_volume.fetch('quickpay')[:bound]).to eq(:only_option)
    end

    it 'не включает spacepayments (fallback исключён из расчёта по допуску)' do
      expect(achievable_volume).not_to have_key('spacepayments')
    end
  end

  # deviation_pp секции volume_distribution должен читаться от ДОСТИЖИМОЙ
  # доли той же секции, а не от паспортной -- ровно так же, как уже
  # устроено distribution по количеству (см. тесты выше).
  # rubocop:disable-next RSpec/MultipleMemoizedHelpers -- providers/operations/eligibility/pairs/report образуют один сценарий.
  describe 'volume_distribution в собранном отчёте' do
    let(:selected_by_operation) do
      {
        'op_101' => 'vipay', 'op_102' => 'payflow', 'op_103' => 'quickpay',
        'op_104' => 'quickpay', 'op_105' => 'vipay', 'op_106' => 'vipay',
        'op_107' => 'payflow', 'op_108' => 'quickpay', 'op_109' => 'vipay',
        'op_110' => 'payflow'
      }
    end
    let(:by_name) { providers.to_h { |provider| [provider.name, provider] } }
    let(:pairs) do
      operations.map do |operation|
        selected = by_name.fetch(selected_by_operation.fetch(operation.operation_id))
        [operation, Execution::Outcome.new(selected: selected, attempts: [], result: :approved)]
      end
    end
    let(:report) { Reporting::ReportBuilder.build(pairs, providers: providers) }
    let(:external_names) { %w[vipay payflow quickpay] }

    it 'заполняет achievable_pct у каждого внешнего провайдера' do
      external_names.each do |name|
        expect(report['volume_distribution'].fetch(name).fetch('achievable_pct')).not_to be_nil
      end
    end

    it 'считает deviation_pp как share_pct минус achievable_pct с точностью округления' do
      external_names.each do |name|
        entry = report['volume_distribution'].fetch(name)

        expect(entry.fetch('deviation_pp'))
          .to be_within(0.1).of(entry.fetch('share_pct') - entry.fetch('achievable_pct'))
      end
    end
  end
end
