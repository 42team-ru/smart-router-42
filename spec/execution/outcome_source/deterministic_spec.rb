# frozen_string_literal: true

require 'execution/outcome_source/deterministic'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- распределения
# исходов проверяются двумя-тремя связанными долями (approved / rejected / expired)
# на одном прогоне; дробить it — терять контекст границы approved_bp+rejected_bp.
RSpec.describe Execution::OutcomeSource::Deterministic do
  let(:provider) { build_provider('vipay') }

  describe '#call' do
    it 'два прогона одного входа дают побайтово одинаковую последовательность' do
      source = described_class.new(
        seed: 'seed42', outcome_table: { 'vipay' => { approved_bp: 7800, rejected_bp: 500 } }
      )
      ops = (1..50).map { |i| build_operation(id: "op_#{i}") }

      run1 = ops.each_with_index.map { |op, i| source.call(op, provider, (i % 3) + 1) }
      run2 = ops.each_with_index.map { |op, i| source.call(op, provider, (i % 3) + 1) }

      expect(run1).to eq(run2)
    end

    it 'на конверсии 7800 бп доля :approved держится около 78% на 1000 попыток' do
      source = described_class.new(
        seed: 'seed42', outcome_table: { 'vipay' => { approved_bp: 7800, rejected_bp: 500 } }
      )
      results = (1..1000).map { |n| source.call(build_operation(id: "op_#{n}"), provider, 1) }

      approved_share = results.count(:approved) / 1000.0

      expect(approved_share).to be_within(0.03).of(0.78)
    end

    it 'фиксирует ожидаемый исход для контрольной тройки (защита от смены реализации SHA256)' do
      # SHA256("s:op_1:vipay:1").to_i(16) % 10_000 = 41; threshold 7800 -> approved
      source = described_class.new(
        seed: 's', outcome_table: { 'vipay' => { approved_bp: 7800, rejected_bp: 500 } }
      )

      expect(source.call(build_operation(id: 'op_1'), provider, 1)).to eq(:approved)
    end

    it 'делит непринятые на :rejected и :expired по границе approved_bp+rejected_bp' do
      source = described_class.new(
        seed: 'seed42', outcome_table: { 'vipay' => { approved_bp: 0, rejected_bp: 3000 } }
      )
      results = (1..1000).map { |n| source.call(build_operation(id: "op_#{n}"), provider, 1) }

      expect(results).not_to include(:approved)
      expect(results.count(:rejected).to_f / 1000).to be_within(0.05).of(0.30)
      expect(results.count(:expired).to_f / 1000).to be_within(0.05).of(0.70)
    end

    it 'провайдер вне outcome_table получает явный скалярный дефолт без падения' do
      source = described_class.new(seed: 'seed42', outcome_table: {})

      expect { source.call(build_operation(id: 'op_1'), provider, 1) }.not_to raise_error
      results = (1..200).map { |n| source.call(build_operation(id: "op_#{n}"), provider, 1) }
      expect(results).not_to include(:approved)
    end

    it 'пер-провайдерные пороги: разные approved_bp у разных провайдеров не мешают друг другу' do
      source = described_class.new(
        seed: 'seed42',
        outcome_table: {
          'vipay' => { approved_bp: 9000, rejected_bp: 500 },
          'payflow' => { approved_bp: 1000, rejected_bp: 500 }
        }
      )
      payflow = build_provider('payflow')

      vipay_results = (1..500).map { |n| source.call(build_operation(id: "op_#{n}"), provider, 1) }
      payflow_results = (1..500).map { |n| source.call(build_operation(id: "op_#{n}"), payflow, 1) }
      vipay_approved = vipay_results.count(:approved)
      payflow_approved = payflow_results.count(:approved)

      expect(vipay_approved).to be > payflow_approved
    end
  end

  describe '.passport_outcome_table' do
    it 'строит таблицу из conversion_24h с общим запасным rejected_bp' do
      table = described_class.passport_outcome_table([build_provider('vipay',
                                                                     conversion_24h: 0.91)])

      expect(table).to eq('vipay' => { approved_bp: 9100, rejected_bp: 500 })
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
