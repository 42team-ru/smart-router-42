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

    def self.check(provider, operation, state = nil)
      REGISTRY.lazy.filter_map do |constraint|
        constraint.violation(provider, operation, state)
      end.first
    end

    def self.eligible?(provider, operation, state = nil)
      check(provider, operation, state).nil?
    end
  end
end
