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

  describe 'таблица исходов' do
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

    it 'reserve после hold той же пары падает (закрывать через resolve_hold)' do
      state.reserve(vipay, operation)
      state.hold(vipay, operation)

      expect { state.reserve(vipay, operation) }
        .to raise_error(ArgumentError, /reserve already held/)
    end
  end

  # Счётчик интенсивности. Растёт только в #reserve (включая fallback-резерв —
  # это тоже #reserve), и намеренно не
  # уменьшается ни в #rollback, ни в #hold, ни в #commit, ни в #resolve_hold --
  # интенсивность считает отправленные запросы, а не занятую ёмкость.
  describe '#requests_in_minute' do
    def minute = '2026-07-30T10:00'
    def other_minute = '2026-07-30T10:01'
    def op_a = build_operation(id: 'op_rl_a', amount: 5_000, created_at: '2026-07-30T10:00:05Z')
    def op_b = build_operation(id: 'op_rl_b', amount: 5_000, created_at: '2026-07-30T10:00:59Z')
    def op_c = build_operation(id: 'op_rl_c', amount: 5_000, created_at: '2026-07-30T10:01:00Z')

    it 'нулевой счётчик до первого резерва' do
      expect(state.requests_in_minute('vipay', minute)).to eq(0)
    end

    it 'растёт на каждый reserve в ту же минуту' do
      state.reserve(vipay, op_a)
      state.reserve(vipay, op_b)

      expect(state.requests_in_minute('vipay', minute)).to eq(2)
    end

    it 'не уменьшается на rollback' do
      state.reserve(vipay, op_a)
      state.rollback(vipay, op_a)

      expect(state.requests_in_minute('vipay', minute)).to eq(1)
    end

    it 'не уменьшается на commit' do
      state.reserve(vipay, op_a)
      state.commit(vipay, op_a)

      expect(state.requests_in_minute('vipay', minute)).to eq(1)
    end

    it 'не уменьшается на hold ни на последующий resolve_hold' do
      state.reserve(vipay, op_a)
      state.hold(vipay, op_a)

      expect(state.requests_in_minute('vipay', minute)).to eq(1)

      state.resolve_hold(vipay, op_a, :approved)

      expect(state.requests_in_minute('vipay', minute)).to eq(1)
    end

    it 'разные минуты не смешиваются' do
      state.reserve(vipay, op_a)
      state.reserve(vipay, op_c)

      expect(state.requests_in_minute('vipay', minute)).to eq(1)
      expect(state.requests_in_minute('vipay', other_minute)).to eq(1)
    end

    it 'новый экземпляр State::Providers начинает с нуля' do
      state.reserve(vipay, op_a)

      fresh = described_class.new([vipay, payflow, spacepayments])

      expect(fresh.requests_in_minute('vipay', minute)).to eq(0)
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

  describe 'роль ShareCounters (интеграция с Routing::ShareLedger)' do
    subject(:ledger_state) do
      described_class.new([build_provider('vipay'), build_spacepayments])
    end

    require 'support/shared/share_counters'
    it_behaves_like 'счётчики долей'
  end

  describe '#resolve_hold' do
    before do
      state.reserve(vipay, operation)
      state.hold(vipay, operation)
    end

    it ':approved — in_progress откачен, daily_approved += amount, доля держится' do
      state.resolve_hold(vipay, operation, :approved)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_amount('vipay')).to eq(380_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_210_000)
      expect(state.count_units('vipay')).to eq(1)
      expect(state.open_reservations).to eq(0)
    end

    it ':rejected — in_progress откачен, daily не тронут, доля возвращается' do
      state.resolve_hold(vipay, operation, :rejected)

      expect(state.in_progress_count('vipay')).to eq(4)
      expect(state.in_progress_amount('vipay')).to eq(380_000)
      expect(state.daily_approved_amount('vipay')).to eq(3_200_000)
      expect(state.count_units('vipay')).to eq(0)
      expect(state.open_reservations).to eq(0)
    end

    it 'без предварительного hold — ArgumentError' do
      other = build_operation(id: 'op_999', amount: 5_000)

      expect { state.resolve_hold(vipay, other, :approved) }
        .to raise_error(ArgumentError, /no held reservation/)
    end

    it 'actual не в {:approved,:rejected} — ArgumentError' do
      expect { state.resolve_hold(vipay, operation, :expired) }
        .to raise_error(ArgumentError, /must be :approved or :rejected/)
    end

    it 'не задевает счётчики чужого провайдера (прошлые решения не пересчитываются)' do
      other_op = build_operation(id: 'op_202', amount: 20_000)
      state.reserve(payflow, other_op)
      state.commit(payflow, other_op)

      state.resolve_hold(vipay, operation, :approved)

      expect(state.in_progress_count('payflow')).to eq(0)
      expect(state.daily_approved_amount('payflow')).to eq(20_000)
      expect(state.count_units('payflow')).to eq(1)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
