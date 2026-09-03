# frozen_string_literal: true

require 'state/providers'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- сценарии State
# проверяют триплет (in_progress_count, in_progress_amount, daily_approved_amount)
# после одной операции. Дробить это на три it — терять контекст исхода.
RSpec.describe State::Providers do
  let(:vipay) do
    build_provider('vipay', traffic_percentage: 40, in_progress_count: 4,
                            in_progress_amount: 380_000, daily_approved_amount: 3_200_000,
                            available_requisites: 12)
  end
  let(:payflow) { build_provider('payflow', traffic_percentage: 35) }
  let(:spacepayments) { build_spacepayments }
  let(:operation) { build_operation(id: 'op_101', amount: 10_000) }
  let(:state) { described_class.new([vipay, payflow, spacepayments]) }

  describe '#initialize' do
    it 'принимает массив Domain::Provider с fallback внутри' do
      expect { described_class.new([vipay, payflow, spacepayments]) }.not_to raise_error
    end

    it 'без spacepayments — ArgumentError' do
      expect { described_class.new([vipay, payflow]) }
        .to raise_error(ArgumentError, /fallback provider spacepayments missing/)
    end

    it 'дубли по имени — ArgumentError' do
      expect { described_class.new([vipay, vipay, spacepayments]) }
        .to raise_error(ArgumentError, /duplicates by name/)
    end

    it 'снимает начальные значения из Provider' do
      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_amount('vipay')).to eq(380_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_200_000)
    end
  end

  describe 'таблица исходов §4 ARCH' do
    it 'approved: in_progress освобождается, daily_approved += amount' do
      state.reserve(vipay, operation)
      state.commit(vipay, operation)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_amount('vipay')).to eq(380_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_210_000)
    end

    it 'rejected: in_progress освобождается, daily_approved не тронут' do
      state.reserve(vipay, operation)
      state.rollback(vipay, operation)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_amount('vipay')).to eq(380_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_200_000)
    end

    it 'expired: in_progress держится, daily_approved не тронут' do
      state.reserve(vipay, operation)
      state.hold(vipay, operation)

      expect(state.in_progress_count('vipay')).to eq(5)
      expect(state.in_progress_amount('vipay')).to eq(390_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_200_000)
    end
  end

  describe '#reserve' do
    it 'инкрементит счётчики' do
      state.reserve(vipay, operation)

      expect(state.in_progress_count('vipay')).to eq(5)
      expect(state.in_progress_amount('vipay')).to eq(390_000)
    end

    it 'повторный reserve на ту же пару (op, provider) — ArgumentError' do
      state.reserve(vipay, operation)

      expect { state.reserve(vipay, operation) }
        .to raise_error(ArgumentError, /reserve already held/)
    end

    it 'reserve после hold той же пары проходит (для PendingResolver)' do
      state.reserve(vipay, operation)
      state.hold(vipay, operation)

      expect { state.reserve(vipay, operation) }.not_to raise_error
    end
  end

  describe 'spacepayments с null-лимитами' do
    it 'reserve/commit/rollback/hold не райзят' do
      expect { state.reserve(spacepayments, operation) }.not_to raise_error
      expect { state.commit(spacepayments, operation) }.not_to raise_error

      state.reserve(spacepayments, operation)
      expect { state.rollback(spacepayments, operation) }.not_to raise_error

      state.reserve(spacepayments, operation)
      expect { state.hold(spacepayments, operation) }.not_to raise_error
    end
  end

  describe '#fallback' do
    it 'возвращает Domain::Provider для spacepayments' do
      expect(state.fallback).to be(spacepayments)
    end
  end

  describe '#snapshot' do
    it 'отдаёт независимую копию (мутация не задевает state)' do
      snap = state.snapshot('vipay')
      snap[:in_progress_count] = 999

      expect(state.in_progress_count('vipay')).to eq(4)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
