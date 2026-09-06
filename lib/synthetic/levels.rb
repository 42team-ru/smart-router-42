# frozen_string_literal: true

module Synthetic
  # Единственная таблица уровней нагрузки. Меняются все четыре оси разом:
  # число операций, число провайдеров, профиль патологичности (Profiles),
  # разброс сумм. mode — формат очереди на диске (:array читает штатный
  # Io::QueueLoader, :jsonl — Io::QueueStreamLoader). full_cli — гоняется ли
  # bin/route целиком с записью JSON, или только ядро planner+executor.
  # exact_cap — сколько записей из точного оракула реально попадает в
  # expectation.json (для смысла: якорей у нас O(providers), не O(operations),
  # поэтому предел практически никогда не достигается — это просто страховка).
  module Levels
    Level = Data.define(:name, :operations, :providers, :profile,
                        :amount_min, :amount_max, :mode, :full_cli,
                        :exact_cap, :broken_ratio, :run_oracle)

    TABLE = {
      'smoke' => { operations: 200, providers: 3, profile: 'healthy',
                   amount_min: 1_000, amount_max: 50_000, mode: :array,
                   full_cli: true, exact_cap: 10_000, broken_ratio: 0.0, run_oracle: true },
      # Уровень для сравнения конфигураций: небольшой, чтобы гонять его подряд
      # с разными --config, и на профиле competitive, где у стратегии есть
      # выбор. Эталон считается сам (операций меньше порога автоматики).
      'compare' => { operations: 5_000, providers: 6, profile: 'competitive',
                     amount_min: 1_000, amount_max: 100_000, mode: :array,
                     full_cli: true, exact_cap: 10_000, broken_ratio: 0.0,
                     run_oracle: true },
      # Тот же профиль competitive, но масштаб m: сравнение конфигураций на
      # ста тысячах заявок, где успевают сработать дневные лимиты и накопиться
      # доли. Эталон по умолчанию не считается (порог автоматики 10 000
      # операций) — включается флагом ORACLE=1.
      'compare_m' => { operations: 100_000, providers: 20, profile: 'competitive',
                       amount_min: 1_000, amount_max: 1_000_000, mode: :array,
                       full_cli: true, exact_cap: 20_000, broken_ratio: 0.0,
                       run_oracle: true },
      's' => { operations: 10_000, providers: 8, profile: 'tight_limits',
               amount_min: 500, amount_max: 200_000, mode: :array,
               full_cli: true, exact_cap: 10_000, broken_ratio: 0.0, run_oracle: true },
      'm' => { operations: 100_000, providers: 20, profile: 'narrow_banks',
               amount_min: 100, amount_max: 1_000_000, mode: :array,
               full_cli: true, exact_cap: 20_000, broken_ratio: 0.0, run_oracle: true },
      'l' => { operations: 1_000_000, providers: 50, profile: 'fallback_heavy',
               amount_min: 1, amount_max: 10_000_000, mode: :jsonl,
               full_cli: false, exact_cap: 20_000, broken_ratio: 0.0, run_oracle: false },
      # Тот же масштаб и профиль, что у l, но очередь в памяти (:array) —
      # единственный способ посчитать на миллионе офлайн-эталон: оракулу нужны
      # вся очередь и все назначения целиком, а ради отказа от этого потоковый
      # режим и сделан (Bench::Runner гасит эталон при mode != :array).
      #
      # Эталон сам не включается — 1 000 000 больше ORACLE_AUTO_MAX_OPS, — и
      # это не формальность: на 100 000 операций замер дал 29 с и 582 МБ RSS,
      # здесь на порядок больше заявок и вдвое с половиной больше провайдеров.
      # Включается явно: make bench LEVEL=l_oracle ORACLE=1.
      'l_oracle' => { operations: 1_000_000, providers: 50, profile: 'fallback_heavy',
                      amount_min: 1, amount_max: 10_000_000, mode: :array,
                      full_cli: false, exact_cap: 20_000, broken_ratio: 0.0,
                      run_oracle: true },
      'xl' => { operations: 5_000_000, providers: 200, profile: 'pathological',
                amount_min: 1, amount_max: 1_000_000_000, mode: :jsonl,
                full_cli: false, exact_cap: 20_000, broken_ratio: 0.0002, run_oracle: false },
      'insane' => { operations: 20_000_000, providers: 500, profile: 'pathological',
                    amount_min: 1, amount_max: 1_000_000_000, mode: :jsonl,
                    full_cli: false, exact_cap: 20_000, broken_ratio: 0.0005, run_oracle: false }
    }.freeze

    module_function

    def fetch(name)
      raw = TABLE.fetch(name.to_s) { raise unknown_level(name) }
      Level.new(name: name.to_s, **raw)
    end

    def known = TABLE.keys

    def unknown_level(name)
      ArgumentError.new("неизвестный уровень #{name.inspect}; допустимы: #{known.join(', ')}")
    end
  end
end
