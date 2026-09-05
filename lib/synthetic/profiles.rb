# frozen_string_literal: true

module Synthetic
  # Профиль патологичности входа. Управляет тремя долями провайдеров:
  #
  #   exclusive_pct — доля здоровых провайдеров, у которых banks = [маркер] и
  #                   только; они принимают собственные якоря (см. queue.rb),
  #                   поэтому их дневной бюджет не трогает шум и остаётся точным;
  #   poisoned_pct  — доля провайдеров, намеренно и навсегда отсеянных одним из
  #                   hard-constraints (не участвуют ни в якорях, ни в шуме);
  #   orphan_noise_pct — доля шумовых операций с банком, которого нет ни у
  #                   кого — гарантированный (но не адресный) fallback.
  #
  # Оставшиеся здоровые провайдеры — wide: маркер плюс общий пул банков,
  # конкурируют за шум по стратегии. distribution_band_pp — полуширина
  # допуска по распределению в п.п.: чем патологичнее профиль, тем меньше
  # предсказуема доля шума, и тем шире коридор.
  #
  # amount_span_divisor — во сколько раз окно допустимых сумм провайдера уже
  # диапазона уровня. Двойка (по умолчанию) даёт частичное пересечение окон;
  # единица — полное, все wide-провайдеры принимают любую сумму уровня.
  # Это ручка «сколько у стратегии реального выбора»: при делителе 2 и высокой
  # доле exclusive большинство заявок имеют ровно одного кандидата, и любая
  # стратегия даёт один и тот же ответ.
  module Profiles
    Profile = Data.define(:name, :exclusive_pct, :poisoned_pct, :orphan_noise_pct,
                          :distribution_band_pp, :amount_span_divisor, :normalize_traffic)

    DEFAULT_AMOUNT_SPAN_DIVISOR = 2
    DEFAULT_NORMALIZE_TRAFFIC = false

    TABLE = {
      'healthy' => { exclusive_pct: 30, poisoned_pct: 0, orphan_noise_pct: 0,
                     distribution_band_pp: 2 },
      'tight_limits' => { exclusive_pct: 70, poisoned_pct: 0, orphan_noise_pct: 2,
                          distribution_band_pp: 5 },
      'narrow_banks' => { exclusive_pct: 60, poisoned_pct: 0, orphan_noise_pct: 5,
                          distribution_band_pp: 6 },
      'fallback_heavy' => { exclusive_pct: 30, poisoned_pct: 0, orphan_noise_pct: 30,
                            distribution_band_pp: 8 },
      'pathological' => { exclusive_pct: 40, poisoned_pct: 30, orphan_noise_pct: 15,
                          distribution_band_pp: 15 },
      # Профиль для сравнения конфигураций, а не для проверки корректности:
      # мало эксклюзивных провайдеров, полный пул банков и полное пересечение
      # окон по сумме — у стратегии есть настоящий выбор почти на каждой заявке
      # (на сгенерированном входе пятеро кандидатов у 94% заявок против одного
      # у 70% в tight_limits).
      #
      # Коридор в 100 п.п. означает, что проверка распределения выключена, и это
      # не послабление: профиль существует ради того, чтобы распределение
      # ЗАВИСЕЛО от стратегии, поэтому «правильной» доли здесь нет — conversion
      # отдаёт почти всё лучшему провайдеру, count_share ведёт к целевым долям,
      # round_robin делит поровну. Корректность по-прежнему стерегут
      # конструктивные якоря и проверка hard-constraints.
      # normalize_traffic: целевые доли приводятся к сумме 100%. Без этого они
      # у каждого провайдера независимы (5..64) и в сумме дают под 300% — цель
      # недостижима для любой стратегии, отклонение у всех одинаково велико, и
      # сравнение вырождается. Остальные профили нормировку не включают: там
      # проверяется корректность, а не качество распределения, и менять их
      # генерацию задним числом нельзя.
      'competitive' => { exclusive_pct: 10, poisoned_pct: 0, orphan_noise_pct: 0,
                         distribution_band_pp: 100, amount_span_divisor: 1,
                         normalize_traffic: true }
    }.freeze

    # Ротация видов «отравления» для poisoned-провайдеров — по одному
    # представителю каждого hard-constraint, кроме DailyLimit (не статичен,
    # см. README к бенчмарку) и RateLimit (State::Providers не реализует
    # requests_in_minute, отсев никогда не срабатывает — ни в бою, ни здесь).
    POISON_TYPES = %i[inactive zero_traffic no_requisites negative_margin
                      in_progress_cap excluded_banks].freeze

    module_function

    def fetch(name)
      raw = TABLE.fetch(name.to_s) { raise unknown_profile(name) }
      Profile.new(name: name.to_s,
                  amount_span_divisor: DEFAULT_AMOUNT_SPAN_DIVISOR,
                  normalize_traffic: DEFAULT_NORMALIZE_TRAFFIC, **raw)
    end

    def known = TABLE.keys

    def unknown_profile(name)
      ArgumentError.new("неизвестный профиль #{name.inspect}; допустимы: #{known.join(', ')}")
    end
  end
end
