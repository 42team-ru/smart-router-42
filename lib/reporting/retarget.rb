# frozen_string_literal: true

require_relative '../offline/objective'

module Reporting
  # Обратная задача: вместо констатации недостижимости целей — ближайшая
  # достижимая точка. `proposed` — уже посчитанный achievable_bp из
  # того же Routing::Achievable.for_queue, что и DeviationCauses; ничего
  # заново не считается.
  #
  # `effect` — не пересчёт фактов, а смена целей: "если бы паспортными целями
  # были proposed, наш же результат отклонялся бы на столько". Domain::Provider
  # -- Data.define, поэтому подстановка новой цели через #with не требует
  # копирования остальных полей и не мутирует исходный снапшот.
  #
  # Одна строка в recommendations, а не Hash и не отдельный top-level ключ:
  # spec/fixtures/contracts/report.json фиксирует и порядок ключей отчёта, и
  # recommendations как массив строк -- см. lib/reporting/report_builder.rb.
  module Retarget
    def self.build(providers, achievable, metrics)
      external = providers.select { |provider| achievable.key?(provider.name) }
      current = external.to_h { |provider| [provider.name, provider.traffic_percentage.to_i] }
      proposed = external.to_h { |provider| [provider.name, achievable_pct(achievable, provider)] }

      return nil if current == proposed

      # Без структурной причины (:only_option/:money хотя бы у одного из
      # изменившихся провайдеров) рекомендация превращается в голое "поменяйте
      # цифры", а идея 6 требует именно объяснённой недостижимости -- лучше не
      # выдать retarget вообще, чем выдать с пустой причиной в скобках.
      reason = reason_for(external, achievable)
      return nil if reason.empty?

      message(current, proposed, reason, providers, metrics)
    end

    def self.message(current, proposed, reason, providers, metrics)
      before = max_deviation(providers, metrics)
      after = max_deviation(retargeted(providers, proposed), metrics)

      "retarget: паспортные цели (#{format_targets(current, proposed)}) недостижимы " \
        "(#{reason}) — максимальное отклонение падает с #{format_number(before)} до " \
        "#{format_number(after)} п.п."
    end
    private_class_method :message

    def self.achievable_pct(achievable, provider)
      (achievable.fetch(provider.name).fetch(:achievable_bp) / 100.0).round
    end
    private_class_method :achievable_pct

    def self.retargeted(providers, proposed)
      providers.map { |provider| retarget_one(provider, proposed) }
    end
    private_class_method :retargeted

    def self.retarget_one(provider, proposed)
      return provider unless proposed.key?(provider.name)

      provider.with(traffic_percentage: proposed.fetch(provider.name))
    end
    private_class_method :retarget_one

    def self.max_deviation(providers, metrics)
      deviations = Offline::Objective.deviations_pp(counts: metrics.counts, providers: providers,
                                                    total: metrics.total)
      deviations.values.map(&:abs).max
    end
    private_class_method :max_deviation

    def self.reason_for(external, achievable)
      external.filter_map { |provider| reason_phrase(provider, achievable.fetch(provider.name)) }
              .join('; ')
    end
    private_class_method :reason_for

    def self.reason_phrase(provider, entry)
      case entry.fetch(:bound)
      when :only_option then "#{provider.name} форсирован отсутствием альтернатив у части операций"
      when :money then "#{provider.name} ограничен дневным лимитом"
      end
    end
    private_class_method :reason_phrase

    def self.format_targets(current, proposed)
      current.map { |name, current_pct| format_target(name, current_pct, proposed.fetch(name)) }
             .join(', ')
    end
    private_class_method :format_targets

    def self.format_target(name, current_pct, proposed_pct)
      return "#{name} #{current_pct}%" if current_pct == proposed_pct

      "#{name} #{current_pct}% → #{proposed_pct}%"
    end
    private_class_method :format_target

    def self.format_number(value)
      (value % 1).zero? ? value.to_i.to_s : format('%.1f', value)
    end
    private_class_method :format_number
  end
end
