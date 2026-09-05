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
  module Profiles
    Profile = Data.define(:name, :exclusive_pct, :poisoned_pct, :orphan_noise_pct,
                          :distribution_band_pp)

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
                          distribution_band_pp: 15 }
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
      Profile.new(name: name.to_s, **raw)
    end

    def known = TABLE.keys

    def unknown_profile(name)
      ArgumentError.new("неизвестный профиль #{name.inspect}; допустимы: #{known.join(', ')}")
    end
  end
end
