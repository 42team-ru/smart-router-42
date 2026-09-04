# frozen_string_literal: true

require 'execution/pending_resolver'
require 'state/providers'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- сценарии
# resolve проверяют триплет State (in_progress, daily_approved, count_units)
# после одного действия. Дробить это на три it — терять контекст исхода.
RSpec.describe Execution::PendingResolver do
  subject(:resolver) { described_class.new }

  let(:vipay) do
    build_provider('vipay', traffic_percentage: 40, in_progress_count: 4,
                            in_progress_amount: 380_000, daily_approved_amount: 3_200_000,
                            available_requisites: 12)
  end
  let(:payflow) { build_provider('payflow', traffic_percentage: 35) }
  let(:spacepayments) { build_spacepayments }
  let(:operation) { build_operation(id: 'op_101', amount: 10_000) }
  let(:state) { State::Providers.new([vipay, payflow, spacepayments]) }

  describe '#resolve' do
    before do
      state.reserve(vipay, operation)
      state.hold(vipay, operation)
    end

    it ':approved закрывает hold как одобрение' do
      resolver.resolve(state, vipay, operation, :approved)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.daily_approved_amount('vipay')).to eq(3_210_000)
      expect(state.count_units('vipay')).to eq(1)
      expect(state.open_reservations).to eq(0)
    end

    it ':rejected закрывает hold как отказ' do
      resolver.resolve(state, vipay, operation, :rejected)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.daily_approved_amount('vipay')).to eq(3_200_000)
      expect(state.count_units('vipay')).to eq(0)
      expect(state.open_reservations).to eq(0)
    end

    it ':expired — ArgumentError (только actual статусы)' do
      expect { resolver.resolve(state, vipay, operation, :expired) }
        .to raise_error(ArgumentError, /must be :approved or :rejected/)
    end

    it 'без предварительного hold — ArgumentError из State' do
      other_op = build_operation(id: 'op_999', amount: 5_000)

      expect { resolver.resolve(state, vipay, other_op, :approved) }
        .to raise_error(ArgumentError, /no held reservation/)
    end

    it 'не пересчитывает прошлые решения по другим (op, provider)' do
      earlier = build_operation(id: 'op_100', amount: 20_000)
      state.reserve(payflow, earlier)
      state.commit(payflow, earlier)

      resolver.resolve(state, vipay, operation, :approved)

      expect(state.in_progress_count('payflow')).to eq(0)
      expect(state.daily_approved_amount('payflow')).to eq(20_000)
      expect(state.count_units('payflow')).to eq(1)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
