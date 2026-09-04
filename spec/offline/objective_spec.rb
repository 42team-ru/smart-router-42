# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require 'offline/objective'
require 'execution/outcome'

RSpec.describe Offline::Objective do
  let(:providers) { offline_context.first }

  it 'считает целочисленную метрику и переводит в float только на границе отчёта' do
    metrics = described_class.metrics(
      counts: { 'vipay' => 4, 'payflow' => 3, 'quickpay' => 3, 'spacepayments' => 0 },
      delivered: 10, providers: providers, total: 10
    )

    expect(metrics.max_deviation_num).to eq(5000).and(be_a(Integer))
    expect(metrics.max_deviation_pp).to eq(5.0)
    expect(metrics.key).to eq([-10, 5000])
  end

  it 'считает approved и expired доставленными, а rejected — нет' do
    pairs = %i[approved expired rejected].map.with_index do |result, index|
      [nil, Execution::Outcome.new(providers[index], [], result)]
    end

    expect(described_class.from_pairs(pairs, providers: providers).delivered).to eq(2)
  end

  it 'обрабатывает пустую очередь без деления на ноль' do
    metrics = described_class.metrics(counts: {}, delivered: 0, providers: providers, total: 0)

    expect(metrics).to have_attributes(max_deviation_num: 0, max_deviation_pp: 0.0)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
