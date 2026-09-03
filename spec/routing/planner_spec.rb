# frozen_string_literal: true

require 'json'
require 'routing/planner'
require_relative '../support/provider_factory'

# rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe Routing::Planner do
  include ProviderFactory

  let(:providers) do
    provider_snapshots.map do |snapshot|
      build_provider(**provider_attributes(snapshot))
    end
  end
  let(:planner) { described_class.new(providers: providers) }

  it 'строит для op_103 каскад только из quickpay' do
    plan = public_plan('op_103')

    expect(plan.candidates.map(&:name)).to eq(['quickpay'])
    expect(plan.skipped.map { |provider, violation| [provider.name, violation.reason] }).to eq(
      [%w[vipay amount_exceeds_limit], %w[payflow amount_exceeds_limit]]
    )
  end

  it 'строит для op_107 каскад только из payflow' do
    plan = public_plan('op_107')

    expect(plan.candidates.map(&:name)).to eq(['payflow'])
    expect(plan.skipped.map { |provider, violation| [provider.name, violation.reason] }).to eq(
      [%w[vipay amount_below_minimum], %w[quickpay amount_below_minimum]]
    )
  end

  it 'не помещает spacepayments в план ни одной операции' do
    operations.each do |operation|
      plan = planner.plan(operation)

      expect(plan.candidates.map(&:name) + plan.skipped.map do |provider, _violation|
        provider.name
      end)
        .not_to include('spacepayments')
    end
  end

  it 'возвращает fallback, когда внешних кандидатов нет' do
    fallback = build_provider(payment_system: 'spacepayments')
    rejected = build_provider(payment_system: 'vipay', status: 'suspended')
    empty_plan = described_class.new(providers: [rejected, fallback]).plan(build_operation)

    expect(empty_plan).to be_empty
    expect(described_class.new(providers: [rejected,
                                           fallback]).fallback_provider_object).to eq(fallback)
  end

  it 'сортирует кандидатов op_101 по priority' do
    expect(public_plan('op_101').candidates.map(&:name)).to eq(%w[vipay payflow quickpay])
  end

  it 'разрешает равный priority именем независимо от порядка входа' do
    alpha = build_provider(payment_system: 'alpha', priority: 1)
    beta = build_provider(payment_system: 'beta', priority: 1)
    fallback = build_provider(payment_system: 'spacepayments')
    operation = build_operation
    first = described_class.new(providers: [beta, alpha, fallback]).plan(operation)
    second = described_class.new(providers: [alpha, beta, fallback]).plan(operation)

    expect(first.candidates.map(&:name)).to eq(second.candidates.map(&:name))
  end

  it 'покрывает каждого внешнего провайдера ровно одним исходом для всех операций' do
    operations.each do |operation|
      plan = planner.plan(operation)
      names = plan.candidates.map(&:name) + plan.skipped.map do |provider, _violation|
        provider.name
      end

      expect(names.sort).to eq(external_providers.map(&:name).sort)
    end
  end

  def public_plan(operation_id)
    planner.plan(operations.find { |operation| operation.operation_id == operation_id })
  end

  def operations
    JSON.parse(File.read(reference_path('operations_queue_10.json'))).map do |snapshot|
      build_operation(**snapshot.transform_keys(&:to_sym))
    end
  end

  def provider_snapshots
    JSON.parse(File.read(reference_path('providers.json'))).fetch('providers')
  end

  def provider_attributes(snapshot)
    snapshot.transform_keys(&:to_sym).slice(*ProviderFactory::PROVIDER_DEFAULTS.keys)
  end

  def external_providers
    providers.reject { |provider| provider.name == 'spacepayments' }
  end
end
