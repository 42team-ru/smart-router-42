# frozen_string_literal: true

require 'routing/layer_stack'
require_relative '../support/provider_factory'

module LayerStackSpecSupport
  class Layer
    def initialize(deviations, label)
      @deviations = deviations
      @label = label
    end

    def name = @label
    def deviation(provider, _operation, _state) = @deviations.fetch(provider.name)
    def explain(*_args) = "#{name}: 0"
  end
end

# rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- перестановка проверяется размером и множеством.
RSpec.describe Routing::LayerStack do
  include ProviderFactory

  let(:ranked) do
    %w[alpha beta gamma].map { |name| build_provider(payment_system: name) }
  end
  let(:operation) { build_operation }

  it 'пустая стопка возвращает тот же порядок и тот же массив' do
    result = described_class.new([]).adjust(ranked, operation, nil)

    expect(result).to equal(ranked)
  end

  it 'сохраняет порядок стратегии между кандидатами с равным отклонением' do
    layer = LayerStackSpecSupport::Layer.new({ 'alpha' => 0, 'beta' => 5, 'gamma' => 0 }, 'one')

    expect(described_class.new([layer]).adjust(ranked, operation, nil).map(&:name))
      .to eq(%w[alpha gamma beta])
  end

  it 'отдаёт приоритет первому слою списка при конфликте целей' do
    first = LayerStackSpecSupport::Layer.new({ 'alpha' => 0, 'beta' => 1, 'gamma' => 1 }, 'first')
    second = LayerStackSpecSupport::Layer.new({ 'alpha' => 1, 'beta' => 0, 'gamma' => 1 }, 'second')

    first_wins = described_class.new([first, second]).adjust(ranked, operation, nil).first.name
    second_wins = described_class.new([second, first]).adjust(ranked, operation, nil).first.name

    expect([first_wins, second_wins]).to eq(%w[alpha beta])
  end

  it 'не меняет порядок при равных отклонениях' do
    layer = LayerStackSpecSupport::Layer.new({ 'alpha' => 0, 'beta' => 0, 'gamma' => 0 }, 'equal')

    expect(described_class.new([layer]).adjust(ranked, operation, nil)).to eq(ranked)
  end

  it 'возвращает перестановку входа' do
    layer = LayerStackSpecSupport::Layer.new(
      { 'alpha' => 2, 'beta' => 1, 'gamma' => 0 }, 'permutation'
    )
    result = described_class.new([layer]).adjust(ranked, operation, nil)

    expect(result.size).to eq(ranked.size)
    expect(result.map(&:name).sort).to eq(ranked.map(&:name).sort)
  end

  it 'отклоняет отрицательное deviation' do
    layer = LayerStackSpecSupport::Layer.new(
      { 'alpha' => -1, 'beta' => 0, 'gamma' => 0 }, 'negative'
    )

    expect { described_class.new([layer]).adjust(ranked, operation, nil) }
      .to raise_error(ArgumentError, /non-negative Integer/)
  end
end
