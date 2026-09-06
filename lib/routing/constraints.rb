# frozen_string_literal: true

require_relative 'reasons'
require_relative 'constraints/base'
require_relative 'constraints/status'
require_relative 'constraints/traffic_share'
require_relative 'constraints/amount_range'
require_relative 'constraints/daily_limit'
require_relative 'constraints/in_progress'
require_relative 'constraints/bank_filter'
require_relative 'constraints/margin'
require_relative 'constraints/requisites'
require_relative 'constraints/rate_limit'

module Routing
  module Constraints
    # Причины отсева, которые вправе возвращать проверки допуска.
    REASONS = Reasons::SKIP

    # Порядок проверок. Он виден снаружи: каскад сохраняет первую сработавшую
    # причину, поэтому список отсортирован от самого общего к самому частному —
    # «провайдер выключен» объясняет ситуацию лучше, чем «не хватило реквизитов»,
    # даже если верно и то и другое.
    #
    # RateLimit сюда намеренно не входит, хотя это тоже проверка допуска.
    # Реестром пользуется не только планировщик, но и расчёт достижимых долей,
    # сборка отчёта и офлайн-эталон. У интенсивности особое правило (она не
    # применяется, если опустошает пул кандидатов), и живёт оно только на пути
    # реального роутинга — Planner дёргает Constraints::RateLimit напрямую.
    # Положи её сюда — и все перечисленные расчёты начали бы считать допуск
    # строже, чем он есть на самом деле, молча и без смягчения.
    REGISTRY = [Status, TrafficShare, AmountRange, DailyLimit,
                InProgress, BankFilter, Margin, Requisites].freeze

    # Обычный цикл, а не REGISTRY.lazy.filter_map{}.first, хотя тот выражал
    # намерение («первое нарушение») короче.
    #
    # Причина не в стиле, а в падении: на уровне l_oracle (1 000 000 заявок,
    # 50 провайдеров) прогон валился с [BUG] Segmentation fault ровно в этом
    # блоке — Ruby 4.0.6, кадры IFUNC от ленивого энумератора. Ruby-код
    # сегфолтиться не умеет, это баг интерпретатора; чинить его нам нечем, а вот
    # не подставляться под него — можно.
    #
    # Подставлялись мы масштабом: check зовётся на каждую пару (заявка,
    # провайдер), то есть здесь строилось до 50 000 000 объектов
    # Enumerator::Lazy, каждый со своей цепочкой блоков. Цикл не аллоцирует
    # ничего и на длинной очереди ещё и заметно быстрее.
    #
    # Поведение прежнее дословно: проверки идут в порядке REGISTRY, возвращается
    # первое нарушение, при чистом проходе — nil.
    def self.check(provider, operation, state = nil)
      REGISTRY.each do |constraint|
        violation = constraint.violation(provider, operation, state)
        return violation if violation
      end
      nil
    end

    def self.eligible?(provider, operation, state = nil)
      check(provider, operation, state).nil?
    end
  end
end
