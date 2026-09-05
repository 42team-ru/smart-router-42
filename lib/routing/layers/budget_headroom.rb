# frozen_string_literal: true

require_relative '../layers'
require_relative 'base'

module Routing
  module Layers
    # Придерживает провайдера, у которого кончается дневной бюджет.
    #
    # Проверка допуска DailyLimit отвечает только «влезает или нет» и пропускает
    # провайдера, у которого остался последний процент лимита. Этот слой смотрит
    # на ту же цифру заранее: чем меньше запаса, тем ниже провайдер в списке.
    #
    # Смысл — не в экономии ради экономии. Остаток лимита ценен тем, что им
    # можно оплатить заявку, которую больше некому взять. Потратив его на
    # заявку, доступную всем троим, мы теряем возможность провести ту, что
    # доступна только ему. Ровно эта ловушка заложена в публичной очереди:
    # у payflow остаётся 100 000 ₽, а среди доступных ему заявок есть одна на
    # 800 ₽, которую не возьмёт никто другой.
    #
    # Правило взято из задачи AdWords о распределении рекламных показов между
    # рекламодателями с ограниченными бюджетами — там та же дилемма «потратить
    # сейчас или сберечь под то, что подойдёт только этому». Функция
    # ψ(T) = 1 − e^(T−1), где T — доля израсходованного бюджета, даёт плавное
    # снижение вместо порогового «пока можно — можно, потом резко нельзя».
    #
    # Экспонента считается рядом Тейлора на рациональных числах, а не готовой
    # библиотечной функцией: в решающем пути не должно быть float, иначе
    # побайтовая воспроизводимость зависит от платформы. Результат — целое в
    # миллионных долях, как того требует контракт слоя.
    #
    # Остаток бюджета берётся из состояния прогона, если оно передано: за время
    # очереди мы сами могли потратить часть лимита, и снапшот об этом не знает.
    #
    # В боевом конфиге слой выключен — замер показал, что на публичной очереди
    # он ухудшает итоговое отклонение. Числа этого сравнения лежат в секции
    # comparison отчёта.
    #
    # Дальше по коду: секция comparison в отчёте — прогон со слоями и без;
    # README, раздел про алгоритмы — первоисточник (Mehta et al., FOCS 2005).
    class BudgetHeadroom < Base
      MICRO = 1_000_000
      TAYLOR_TERMS = 16
      DEFAULT_PSI_THRESHOLD_MICRO = 100_000
      CONFIG_KEY = 'psi_threshold_micro'

      def self.from_config(config)
        goals = config.goals.fetch('budget_headroom', {})
        new(psi_threshold_micro: goals.fetch(CONFIG_KEY, DEFAULT_PSI_THRESHOLD_MICRO))
      end

      def initialize(psi_threshold_micro: DEFAULT_PSI_THRESHOLD_MICRO)
        super()
        validate_threshold!(psi_threshold_micro)
        @psi_threshold_micro = psi_threshold_micro
      end

      def name = 'budget_headroom'

      def psi_micro(provider, state)
        limit = provider.daily_amount_limit
        return MICRO if limit.nil? || limit <= 0

        x = 1 - Rational(live_daily_approved(provider, state), limit)
        x = 0 if x.negative?
        ((1 - taylor_exp_neg(x)) * MICRO).round
      end

      def deviation(provider, _operation, state)
        [0, psi_threshold_micro - psi_micro(provider, state)].max
      end

      def explain(ranked_before, ranked_after, _operation, state)
        minimum = ranked_before.map { |provider| psi_micro(provider, state) }.min
        return no_reordering_details(minimum) if ranked_before == ranked_after

        reordered_details(ranked_before, ranked_after, state)
      end

      private

      attr_reader :psi_threshold_micro

      def live_daily_approved(provider, state)
        if state.respond_to?(:daily_approved_amount)
          return state.daily_approved_amount(provider.name)
        end

        provider.daily_approved_amount.to_i
      end

      def taylor_exp_neg(value)
        term = Rational(1, 1)
        sum = term
        1.upto(TAYLOR_TERMS - 1) do |n|
          term *= -value
          term /= n
          sum += term
        end
        sum
      end

      def no_reordering_details(minimum)
        "#{name}: без перестановки, минимальный psi #{format_micro(minimum)}; " \
          "порог #{format_micro(psi_threshold_micro)}"
      end

      def reordered_details(ranked_before, ranked_after, state)
        after_positions = positions(ranked_after)
        providers = ranked_before.each_with_index.map do |provider, index|
          provider_details(provider, index, after_positions, state)
        end
        "#{name}: #{providers.join('; ')}; порог #{format_micro(psi_threshold_micro)}"
      end

      def positions(ranked)
        ranked.each_with_index.to_h { |provider, index| [provider.name, index + 1] }
      end

      def provider_details(provider, index, after_positions, state)
        psi = psi_micro(provider, state)
        deviation_value = deviation(provider, nil, state)
        "#{provider.name} psi #{format_micro(psi)} (отклонение #{deviation_value}) " \
          "-> с #{index + 1} на #{after_positions.fetch(provider.name)}"
      end

      def format_micro(value)
        return '1.000' if value == MICRO

        format('0.%03d', (value + 500) / 1000)
      end

      def validate_threshold!(value)
        return if value.is_a?(Integer) && value.between?(0, MICRO)

        raise ArgumentError,
              "goals.budget_headroom.#{CONFIG_KEY} must be Integer 0..#{MICRO}, " \
              "got #{value.inspect}"
      end
    end

    register('budget_headroom', BudgetHeadroom)
  end
end
