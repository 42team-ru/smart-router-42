# frozen_string_literal: true

module Reporting
  # Три раздельных распределения.
  #   by_final(..., :count)  -- итоговый selected_provider, доля заявок
  #   by_final(..., :amount) -- итоговый selected_provider, доля объёма
  #   by_attempt              -- все реальные попытки исполнения (decision
  #                              == 'selected'), а не эл. отсев -- нагрузка
  #                              на провайдера и наблюдаемая конверсия.
  module Distributions
    # achievable -- Routing::Achievable.for_queue для weight == :count,
    # Routing::Achievable.for_volume для weight == :amount. Формы записей
    # разные (achievable_seats/achievable_amount), но обе несут achievable_bp,
    # и только он используется здесь -- секции читают один и тот же метод.
    def self.by_final(pairs, providers, weight, achievable = {})
      total = weight == :count ? pairs.size : pairs.sum { |operation, _| operation.amount }

      providers.to_h do |provider|
        [provider.name, final_entry(pairs, provider, weight, total, achievable)]
      end
    end

    def self.by_attempt(outcomes, providers)
      grouped = real_attempts(outcomes).group_by(&:provider)

      providers.to_h { |provider| [provider.name, attempt_entry(grouped.fetch(provider.name, []))] }
    end

    # Тальи причин эл. отсева (decision == 'skipped') -- дополняет by_attempt,
    # который считает только реальные попытки исполнения.
    def self.skip_reasons(outcomes)
      outcomes.flat_map(&:attempts)
              .select { |attempt| attempt.decision == 'skipped' }
              .each_with_object(Hash.new(0)) { |attempt, tally| tally[attempt.reason] += 1 }
    end

    def self.final_entry(pairs, provider, weight, total, achievable)
      part = weight_of(pairs, provider, weight)
      share_pct = percentage(part, total)

      { (weight == :count ? 'count' : 'amount') => part, 'share_pct' => share_pct }
        .merge(targets(provider, weight, achievable, share_pct))
    end
    private_class_method :final_entry

    def self.targets(provider, weight, achievable, share_pct)
      target_pct = target_of(provider, weight)
      achievable_pct = achievable_pct(provider, achievable)

      {
        'target_pct' => target_pct,
        'achievable_pct' => achievable_pct,
        'deviation_pp' => (share_pct - (achievable_pct || target_pct)).round(1)
      }
    end
    private_class_method :targets

    # volume_share_pct отсутствует в снапшоте организаторов, поэтому цель по
    # объёму берётся из traffic_percentage -- тем
    # же фоллбэком, что и Routing::Strategies::VolumeShare. Без него target_pct
    # равен нулю, а deviation_pp вырождается в саму долю: quickpay показывал
    # 64 п.п. отклонения там, где цели просто нет.
    def self.target_of(provider, weight)
      return provider.traffic_percentage.to_i if weight == :count

      (provider.volume_share_pct || provider.traffic_percentage).to_i
    end
    private_class_method :target_of

    # Отклонение меряется ОТ ДОСТИЖИМОЙ доли, а не от паспортной. На десяти
    # заявках доля квантуется шагом 10 п.п., в 35% попасть нельзя в принципе, и
    # разница цель/достижимое -- арифметический пол, а не промах движка.
    #
    # По объёму достижимое считает Routing::Achievable.for_volume -- та же
    # база, что и по количеству, только приближённая (см. комментарий у
    # for_volume): верхняя граница провайдера — оценка сверху, а не точный
    # рюкзак. У spacepayments достижимого нет в обеих секциях: fallback
    # исключён из расчёта по допуску, а не по исходу, null здесь честнее
    # копии цели.
    def self.achievable_pct(provider, achievable)
      entry = achievable[provider.name]
      return nil if entry.nil?

      (entry[:achievable_bp] / 100.0).round(1)
    end
    private_class_method :achievable_pct

    def self.weight_of(pairs, provider, weight)
      pairs.sum do |operation, outcome|
        next 0 unless outcome.selected.name == provider.name

        weight == :count ? 1 : operation.amount
      end
    end
    private_class_method :weight_of

    def self.real_attempts(outcomes)
      outcomes.flat_map(&:attempts).select { |attempt| attempt.decision == 'selected' }
    end
    private_class_method :real_attempts

    def self.attempt_entry(attempts)
      successful = attempts.count { |attempt| attempt.result == 'approved' }

      {
        'attempts' => attempts.size,
        'successful' => successful,
        'observed_conversion' => attempts.empty? ? nil : (successful.to_f / attempts.size).round(3)
      }
    end
    private_class_method :attempt_entry

    def self.percentage(part, total)
      return 0.0 if total.zero?

      (part.to_f / total * 100).round(1)
    end
    private_class_method :percentage
  end
end
