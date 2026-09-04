# frozen_string_literal: true

require 'routing/planner'
require 'routing/layer_stack'
require_relative '../support/provider_factory'

module PlannerLayersSpecSupport
  class Strategy
    def initialize(label)
      @label = label
    end

    def rank(candidates, _operation, _state) = candidates
    def name = @label
    def explain(ranked, _operation, _state) = "#{name}: #{ranked.size} candidates"
  end

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

# rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- сценарии проверяют один план целиком.
RSpec.describe Routing::Planner do
  include ProviderFactory

  it 'применяет стопку после стратегии и сохраняет оба сегмента trace' do
    vipay = build_provider(payment_system: 'vipay')
    payflow = build_provider(payment_system: 'payflow')
    fallback = build_provider(payment_system: 'spacepayments')
    layer = PlannerLayersSpecSupport::Layer.new({ 'vipay' => 1, 'payflow' => 0 }, 'test_layer')
    planner = described_class.new(
      providers: [vipay, payflow, fallback],
      strategy: PlannerLayersSpecSupport::Strategy.new('test_strategy'),
      layers: Routing::LayerStack.new([layer])
    )

    plan = planner.plan(build_operation, nil)

    expect(plan.candidates.map(&:name)).to eq(%w[payflow vipay])
    expect(plan.trace).to have_attributes(
      strategy_name: 'test_strategy',
      segments: ['selector: статический выбор (1 стратегия) -> test_strategy',
                 'test_strategy: 2 candidates', 'test_layer: 0']
    )
  end

  it 'падает, если стопка расширяет множество кандидатов' do
    vipay = build_provider(payment_system: 'vipay')
    payflow = build_provider(payment_system: 'payflow')
    fallback = build_provider(payment_system: 'spacepayments')
    rogue = build_provider(payment_system: 'rogue')
    stack = Class.new do
      def adjust(_ranked, _operation, _state) = [@rogue]
      def explain(*_args) = ['rogue: 1']
      def empty? = false

      def initialize(provider)
        @rogue = provider
      end
    end.new(rogue)
    planner = described_class.new(
      providers: [vipay, payflow, fallback],
      strategy: PlannerLayersSpecSupport::Strategy.new('test_strategy'), layers: stack
    )

    expect { planner.plan(build_operation, nil) }.to raise_error(RuntimeError, /non-permutation/)
  end

  it 'не строит trace для пустого каскада' do
    suspended = build_provider(payment_system: 'vipay', status: 'suspended')
    fallback = build_provider(payment_system: 'spacepayments')
    planner = described_class.new(
      providers: [suspended, fallback], strategy: PlannerLayersSpecSupport::Strategy.new('test')
    )

    plan = planner.plan(build_operation, nil)

    expect(plan).to be_empty
    expect(plan.trace).to be_nil
  end
end
