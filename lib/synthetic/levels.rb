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
      's' => { operations: 10_000, providers: 8, profile: 'tight_limits',
               amount_min: 500, amount_max: 200_000, mode: :array,
               full_cli: true, exact_cap: 10_000, broken_ratio: 0.0, run_oracle: false },
      'm' => { operations: 100_000, providers: 20, profile: 'narrow_banks',
               amount_min: 100, amount_max: 1_000_000, mode: :array,
               full_cli: true, exact_cap: 20_000, broken_ratio: 0.0, run_oracle: false },
      'l' => { operations: 1_000_000, providers: 50, profile: 'fallback_heavy',
               amount_min: 1, amount_max: 10_000_000, mode: :jsonl,
               full_cli: false, exact_cap: 20_000, broken_ratio: 0.0, run_oracle: false },
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
