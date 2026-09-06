# frozen_string_literal: true

require 'digest'
require_relative 'base'

module Execution
  module OutcomeSource
    # Детерминированный источник исходов: хеш от seed и идентификаторов вместо
    # генератора псевдослучайных чисел. Два прогона одного входа обязаны дать
    # побайтово одинаковый вывод — источники недетерминизма в решающем пути
    # запрещены (греп в CI, см. scripts/check_determinism.sh).
    #
    # Формула:
    #   roll = SHA256("seed:op_id:name:attempt_no").to_i(16) % 10_000
    #   approved_bp/rejected_bp — целые базисные пункты на провайдера (см.
    #   outcome_table ниже)
    #   roll < approved_bp                        -> :approved
    #   roll < approved_bp + rejected_bp           -> :rejected
    #   иначе                                      -> :expired
    #
    # outcome_table — Hash{имя провайдера => {approved_bp:, rejected_bp:}},
    # уже готовые целые базисные пункты. Раньше был один reject_share (доля
    # отказов) на ВСЕХ провайдеров сразу, будто бы "доля отказов среди
    # неодобренных" — на деле же он просто прибавлялся к approved-порогу поверх
    # общей шкалы 0..10_000, то есть был абсолютным, а не относительным, и
    # одинаковым для vipay/quickpay/payflow при том, что история по ним
    # совершенно разная (см. Io::HistoryLoader). Теперь approved_bp и
    # rejected_bp приходят пер-провайдерно — из сглаженной истории при
    # outcomes.calibrate_from_history: true (bin/route строит outcome_table из
    # Io::HistoryStats#to_outcome_table) или из паспортного conversion_24h с
    # прежним запасным reject 5% при false (см. .passport_outcome_table ниже) —
    # сборка таблицы остаётся на стороне вызывающего кода (bin/route,
    # lib/api/gateway.rb, lib/offline/comparison.rb), сам источник данные не
    # добывает и диска не касается.
    #
    # Формула по-прежнему чистая функция от (seed, operation_id, provider,
    # attempt_no) — никакой памяти между вызовами.
    class Deterministic < Base
      BASIS_POINTS = 10_000

      # Провайдера нет в outcome_table вовсе (например, синтетический
      # провайдер в спеке каскада, которому забыли завести историю) — тот же
      # осознанный дефолт, что и в Io::HistoryStats: без всяких данных
      # провайдер никогда не одобряется, 5% уходит в rejected (тот самый
      # прежний reject_share=500, перенесённый сюда как именованная
      # константа), остальное — expired.
      DEFAULT_OUTCOME = { approved_bp: 0, rejected_bp: 500 }.freeze

      # Запасной rejected_bp для паспортного режима (outcomes.calibrate_from_history:
      # false) — сохраняет прежнее поведение источника (approved строго по
      # conversion_24h, 5% неодобренных уходит в rejected) буквально, без
      # привязки к истории вовсе.
      PASSPORT_REJECTED_BP = 500

      def initialize(seed:, outcome_table:)
        super()
        @seed = seed
        @outcome_table = outcome_table
      end

      def call(operation, provider, attempt_no)
        key = "#{@seed}:#{operation.operation_id}:#{provider.name}:#{attempt_no}"
        roll = Digest::SHA256.hexdigest(key).to_i(16) % BASIS_POINTS
        bp = @outcome_table.fetch(provider.name, DEFAULT_OUTCOME)

        return :approved if roll < bp.fetch(:approved_bp)
        return :rejected if roll < bp.fetch(:approved_bp) + bp.fetch(:rejected_bp)

        :expired
      end

      # Паспортный режим (outcomes.calibrate_from_history: false): approved_bp
      # строго из conversion_24h снапшота, без всякой истории. Единственное
      # умножение на Float здесь — перевод уже готовой паспортной доли в целые
      # базисные пункты один раз при сборке таблицы, а не при каждом броске;
      # сам #call выше работает только с целыми числами.
      def self.passport_outcome_table(providers, rejected_bp: PASSPORT_REJECTED_BP)
        providers.to_h do |provider|
          approved_bp = (provider.conversion_24h.to_f * BASIS_POINTS).round
          [provider.name, { approved_bp: approved_bp, rejected_bp: rejected_bp }]
        end
      end
    end
  end
end
