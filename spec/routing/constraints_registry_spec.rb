# frozen_string_literal: true

require 'json'
require 'routing/constraints'
require 'routing/reasons'
require_relative '../support/provider_factory'

module ConstraintsRegistryReference
  module_function

  def decisions
    JSON.parse(File.read(reference_path('reference_decisions.json')))
  end
end

# rubocop:disable-next RSpec/MultipleExpectations -- здесь проверяется единый контракт реестра.
RSpec.describe Routing::Constraints do
  include ProviderFactory

  let(:providers) do
    provider_snapshots.map do |snapshot|
      build_provider(**provider_attributes(snapshot))
    end
  end
  let(:operations) { operation_snapshots.map { |snapshot| build_operation(**symbolize(snapshot)) } }
  let(:payflow_for_limits) do
    build_provider(
      payment_system: 'payflow', limit_amount_max: 50_000,
      daily_approved_amount: 2_900_000, daily_amount_limit: 3_000_000
    )
  end

  it 'держит девять проверок в зафиксированном порядке' do
    expect(described_class::REGISTRY).to be_frozen
    expect(described_class::REGISTRY.map { |constraint| constraint.name.split('::').last }).to eq(
      %w[Status TrafficShare AmountRange DailyLimit InProgress BankFilter Margin Requisites
         RateLimit]
    )
  end

  it 'содержит наследников Base с трёхаргументным violation' do
    described_class::REGISTRY.each do |constraint|
      expect(constraint < Routing::Constraints::Base).to be(true)
      expect(constraint.method(:violation).parameters.map(&:first)).to eq(%i[req req req])
    end
  end

  it 'возвращает первое нарушение' do
    provider = build_provider(status: 'suspended', banks: [])
    operation = build_operation(bank: 'unknown-bank')

    expect(described_class.check(provider,
                                 operation)).to have_attributes(reason: 'provider_inactive')
  end

  it 'проверяет AmountRange раньше DailyLimit' do
    expect(described_class.check(payflow_for_limits, build_operation(amount: 150_000)))
      .to have_attributes(reason: 'amount_exceeds_limit')
  end

  it 'возвращает только причины из Routing::Reasons::SKIP' do
    provider = build_provider(status: 'suspended')

    expect(Routing::Reasons::SKIP).to include(described_class.check(provider,
                                                                    build_operation).reason)
  end

  ConstraintsRegistryReference.decisions.fetch('eligible_providers').each_key do |operation_id|
    it "совпадает с эталонным допуском для #{operation_id}" do
      expect(eligible_provider_names(operation_id))
        .to eq(expected_eligible_provider_names(operation_id))
    end
  end

  ConstraintsRegistryReference.decisions.fetch('skip_reasons_expected').each do |operation_id,
                                                                                provider_reasons|
    provider_reasons.each do |provider_name, expected_reason|
      it "совпадает с эталонной причиной #{operation_id}/#{provider_name}" do
        operation = operations.find { |item| item.operation_id == operation_id }
        provider = providers.find { |item| item.name == provider_name }

        expect(described_class.check(provider, operation).reason).to eq(expected_reason)
      end
    end
  end

  it 'пропускает fallback-провайдера для каждой операции публичной очереди' do
    fallback = providers.find { |provider| provider.name == 'spacepayments' }

    expect(operations).to all(satisfy { |operation|
      described_class.eligible?(fallback, operation)
    })
  end

  def external_providers
    providers.reject { |provider| provider.name == 'spacepayments' }
  end

  def reference_decisions
    ConstraintsRegistryReference.decisions
  end

  def provider_snapshots
    JSON.parse(File.read(reference_path('providers.json'))).fetch('providers')
  end

  def operation_snapshots
    JSON.parse(File.read(reference_path('operations_queue_10.json')))
  end

  def eligible_provider_names(operation_id)
    operation = operations.find { |item| item.operation_id == operation_id }
    external_providers.filter do |provider|
      described_class.eligible?(provider, operation)
    end.map(&:name).sort
  end

  def expected_eligible_provider_names(operation_id)
    reference_decisions.fetch('eligible_providers').fetch(operation_id).sort
  end

  def symbolize(snapshot)
    snapshot.transform_keys(&:to_sym)
  end

  def provider_attributes(snapshot)
    symbolize(snapshot).slice(*ProviderFactory::PROVIDER_DEFAULTS.keys)
  end
end
