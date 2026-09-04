# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength

require 'offline/simulation'

RSpec.describe Offline::Simulation do
  it 'передаёт номер попытки в источник исходов и не кэширует пару operation/provider' do
    providers, operations, = offline_context
    calls = []
    outcomes = Object.new
    outcomes.define_singleton_method(:call) do |operation, provider, attempt_no|
      calls << [operation.operation_id, provider.name, attempt_no]
      attempt_no == 1 ? :rejected : :approved
    end

    described_class.new(providers: providers, outcomes: outcomes).run([operations.first], ['vipay'])

    expect(calls).to include(['op_101', 'vipay', 1], ['op_101', 'payflow', 2])
  end

  it 'запускается на свежем state при каждом вызове' do
    providers, operations, outcomes = offline_context
    simulation = described_class.new(providers: providers, outcomes: outcomes)
    assignment = Array.new(operations.size)

    first = simulation.run(operations, assignment)
    second = simulation.run(operations, assignment)

    expect(first).to eq(second)
  end

  it 'фиксирует, что исход меняется с номером попытки' do
    _providers, operations, outcomes = offline_context
    vipay = offline_context.first.find { |provider| provider.name == 'vipay' }

    expect([1, 2, 3].map { |attempt_no| outcomes.call(operations[1], vipay, attempt_no) })
      .to eq(%i[expired approved approved])
  end
end
# rubocop:enable RSpec/ExampleLength
