# frozen_string_literal: true

# Девять граничных случаев из ARCHITECTURE.md.
# Каждый case — отдельный describe, тест один.
# Все используемые хелперы (build_provider, build_operation, build_spacepayments)
# автоматически подключаются из spec/support/build_helpers.rb.
#
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- граничный случай
# проверяет связанные утверждения об одной ситуации; дробить — терять контекст.

require 'io/queue_loader'
require 'routing/constraints/bank_filter'
require 'routing/constraints/daily_limit'
require 'routing/constraints/in_progress'
require 'routing/constraints/status'
require 'routing/planner'
require 'routing/strategies/count_share'
require 'routing/route_plan'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/always_ok'

# rubocop:disable RSpec/DescribeClass -- файл собирает 9 граничных случаев, а не один класс
RSpec.describe 'граничные случаи' do
  # rubocop:enable RSpec/DescribeClass

  # 1. null в любом лимите → ограничения нет ─────────────────────────────────
  describe 'null в лимите → ограничения нет' do
    it 'DailyLimit и InProgress пропускают операцию когда все лимиты nil' do
      provider = build_provider('sp', daily_amount_limit: nil, in_progress_count_limit: nil,
                                      in_progress_amount_limit: nil, available_requisites: 5)
      huge_op = build_operation(id: 'op_huge', amount: 999_999_999)

      expect(Routing::Constraints::DailyLimit.violation(provider, huge_op, nil)).to be_nil
      expect(Routing::Constraints::InProgress.violation(provider, huge_op, nil)).to be_nil
    end
  end

  # 2. Неизвестный банк → проходят только провайдеры с пустым banks ──────────
  describe 'неизвестный банк → проходят только провайдеры с пустым banks' do
    it 'white-list провайдер получает bank_not_in_list, провайдер с banks:[] проходит' do
      op = build_operation(id: 'op_unk', bank: 'bank_never_seen')
      white_list = build_provider('wl', banks: %w[sberbank tinkoff], exclude_banks: false)
      open_list  = build_provider('ol', banks: [], exclude_banks: false)

      expect(Routing::Constraints::BankFilter.violation(white_list, op, nil)&.reason)
        .to eq('bank_not_in_list')
      expect(Routing::Constraints::BankFilter.violation(open_list, op, nil)).to be_nil
    end
  end

  # 3. Пустой banks → принимает все банки ─────────────────────────────────────
  describe 'пустой banks → принимает все банки' do
    it 'возвращает nil для произвольного банка при banks: []' do
      provider = build_provider('any', banks: [], exclude_banks: false)
      %w[sberbank alfa unknown-99 中文银行].each do |bank|
        op = build_operation(id: "op_#{bank}", bank: bank)
        expect(Routing::Constraints::BankFilter.violation(provider, op, nil)).to be_nil
      end
    end
  end

  # 4. exclude_banks: true → список работает как чёрный ────────────────────────
  describe 'exclude_banks: true → чёрный список' do
    it 'банк в exclude-списке отсеивается, не в списке — проходит' do
      provider = build_provider('bl', banks: %w[sberbank], exclude_banks: true)
      blocked  = build_operation(id: 'op_bl1', bank: 'sberbank')
      allowed  = build_operation(id: 'op_bl2', bank: 'alfa')

      expect(Routing::Constraints::BankFilter.violation(provider, blocked, nil)&.reason)
        .to eq('bank_not_in_list')
      expect(Routing::Constraints::BankFilter.violation(provider, allowed, nil)).to be_nil
    end
  end

  # 5. Сумма ≤ 0 / нет обязательного поля → отклоняется, прогон продолжается ─
  describe 'сумма ≤ 0 или нет обязательного поля → операция отклоняется, прогон продолжается' do
    def with_queue(entries)
      require 'tmpdir'
      require 'json'
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'q.json')
        File.write(path, JSON.generate(entries))
        yield path
      end
    end

    let(:valid_entry) do
      {
        'operation_id' => 'op_good', 'created_at' => '2026-07-30T10:00:00Z',
        'amount' => 1000, 'bank' => 'sberbank', 'card_brand' => nil,
        'payout_requisite' => {}
      }
    end

    it 'amount: 0 отклоняется с причиной, следующая операция загружается' do
      zero_amount = valid_entry.merge('operation_id' => 'op_bad', 'amount' => 0)
      with_queue([zero_amount, valid_entry]) do |path|
        result = Io::QueueLoader.load(path)
        expect(result.operations.map(&:operation_id)).to eq(['op_good'])
        expect(result.errors.first).to include('amount')
      end
    end

    it 'отсутствие поля bank отклоняется с причиной, следующая операция загружается' do
      no_bank = valid_entry.merge('operation_id' => 'op_nobank').except('bank')
      with_queue([no_bank, valid_entry]) do |path|
        result = Io::QueueLoader.load(path)
        expect(result.operations.map(&:operation_id)).to eq(['op_good'])
        expect(result.errors.first).to include('bank')
      end
    end
  end

  # 6. Дубль operation_id → предупреждение, первое решение сохраняется ────────
  describe 'дубль operation_id → первое решение сохраняется' do
    it 'второй элемент с тем же id отклоняется с предупреждением о дубле' do
      require 'tmpdir'
      require 'json'
      entry = {
        'operation_id' => 'op_dup', 'created_at' => '2026-07-30T10:00:00Z',
        'amount' => 1000, 'bank' => 'sberbank', 'card_brand' => nil,
        'payout_requisite' => {}
      }
      dup = entry.merge('amount' => 9999)

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'q.json')
        File.write(path, JSON.generate([entry, dup]))
        result = Io::QueueLoader.load(path)

        expect(result.operations.size).to eq(1)
        expect(result.operations.first.amount).to eq(1000)
        expect(result.errors.first).to include('op_dup')
      end
    end
  end

  # 7. Пустая очередь → валидные файлы с нулями, не падение ──────────────────
  describe 'пустая очередь → валидные файлы с нулями, не падение' do
    it 'QueueLoader на пустом массиве возвращает пустой валидный результат без ошибок' do
      require 'tmpdir'
      require 'json'
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'empty.json')
        File.write(path, '[]')
        result = Io::QueueLoader.load(path)

        expect(result.operations).to eq([])
        expect(result.errors).to eq([])
      end
    end
  end

  # 8. Ни одного активного провайдера → всё уходит в spacepayments ───────────
  describe 'ни одного активного провайдера → всё уходит в spacepayments' do
    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations
    it 'Planner строит пустой candidates, Executor выбирает spacepayments' do
      inactive_vipay   = build_provider('vipay',   status: 'inactive', available_requisites: 5)
      inactive_payflow = build_provider('payflow', status: 'inactive', available_requisites: 5)
      sp               = build_spacepayments

      state    = State::Providers.new([inactive_vipay, inactive_payflow, sp])
      planner  = Routing::Planner.new(
        providers: [inactive_vipay, inactive_payflow, sp]
      )
      executor = Execution::Executor.new(outcomes: Execution::OutcomeSource::AlwaysOk.new)
      op       = build_operation(id: 'op_noactive', amount: 5_000)

      plan = planner.plan(op, state)
      expect(plan.candidates).to be_empty

      outcome = executor.run(plan, op, state)
      expect(outcome.selected.name).to eq('spacepayments')
    end
  end

  # 9. Провайдер не в providers.json → ArgumentError с внятным сообщением ─────
  describe 'обращение к провайдеру не из снапшота → понятная ошибка' do
    it 'State::Providers поднимает ArgumentError с именем неизвестного провайдера' do
      state = State::Providers.new([build_provider('vipay'), build_spacepayments])

      expect { state.in_progress_count('ghost_provider') }
        .to raise_error(ArgumentError, /ghost_provider/)
    end
  end

  # Риск «created_at без секунд/в другом формате»: срез created_at[0, 16] в
  # RateLimit.minute_key и в
  # State::Providers#reserve обязан не ронять прогон даже на нестандартной
  # строке времени -- он просто отрезает сколько есть, без ArgumentError.
  describe 'нестандартный created_at (короче 16 символов) → срез не роняет прогон' do
    # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations
    it 'Planner + Executor проходят операцию с обрезанным created_at без ошибок' do
      vipay = build_provider('vipay', requests_per_minute_limit: 7, available_requisites: 5,
                                      traffic_percentage: 40)
      sp    = build_spacepayments

      state    = State::Providers.new([vipay, sp])
      planner  = Routing::Planner.new(providers: [vipay, sp])
      executor = Execution::Executor.new(outcomes: Execution::OutcomeSource::AlwaysOk.new)
      op       = build_operation(id: 'op_short_time', amount: 5_000, created_at: '2026-07-30')

      plan = nil
      outcome = nil
      expect do
        plan = planner.plan(op, state)
        outcome = executor.run(plan, op, state)
      end.not_to raise_error

      expect(outcome.selected.name).to eq('vipay')
      expect(state.requests_in_minute('vipay', '2026-07-30')).to eq(1)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
