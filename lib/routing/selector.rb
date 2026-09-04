# frozen_string_literal: true

require_relative 'strategies'

module Routing
  # Выбирает стратегию только по текущей операции, уже допущенным кандидатам и
  # текущему состоянию. Правила намеренно не получают очередь целиком.
  module Selector
    Choice = Data.define(:strategy, :rule_index, :why, :details)

    class Static
      def initialize(strategy, details: nil)
        @strategy = strategy
        @details = details || "selector: статический выбор (1 стратегия) -> #{strategy.name}"
      end

      def call(_candidates, _operation, _state)
        Choice.new(strategy: strategy, rule_index: nil, why: nil, details: details)
      end

      private

      attr_reader :strategy, :details
    end

    # rubocop:disable-next Metrics/ClassLength -- Rule и порядок применения неразделимы в контракте селектора.
    class Rules
      PREDICATE_KEYS = %w[amount_gte amount_lt bank_in eligible_count_lte].freeze

      Rule = Data.define(:predicates, :strategy_name, :strategy, :why, :index) do
        # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- валидация одного правила до создания объекта.
        def self.from_config(raw, index:, config:)
          raise ArgumentError, "правило ##{index} должно быть отображением" unless raw.is_a?(Hash)

          predicates = raw.fetch('when')
          unless predicates.is_a?(Hash)
            raise ArgumentError, "правило ##{index}: when должен быть отображением"
          end

          validate_predicates!(predicates, index)
          use = raw.fetch('use')
          unless use.is_a?(String) && !use.empty?
            raise ArgumentError, "правило ##{index}: use должен быть непустой строкой"
          end

          strategy = build_strategy!(use, index, config)
          new(predicates: predicates, strategy_name: use, strategy: strategy,
              why: raw['why'], index: index)
        rescue KeyError => e
          raise e unless e.message.include?('key not found')

          raise ArgumentError, "правило ##{index}: обязательны ключи when и use"
        end

        def matches?(candidates, operation)
          predicates.all? { |key, value| matches_predicate?(key, value, candidates, operation) }
        end

        def matched_details(candidates, operation)
          conditions = predicates.map do |key, value|
            predicate_details(key, value, candidates, operation, matched: true)
          end
          "selector: правило ##{index} (#{conditions.join(', ')}) -> #{strategy_name}#{why_details}"
        end

        def failure_details(candidates, operation)
          key, value = predicates.find do |predicate_key, predicate_value|
            !matches_predicate?(predicate_key, predicate_value, candidates, operation)
          end
          predicate_details(key, value, candidates, operation, matched: false)
        end

        def self.validate_predicates!(predicates, index)
          unknown = predicates.keys.map(&:to_s) - PREDICATE_KEYS
          unless unknown.empty?
            raise ArgumentError,
                  "правило ##{index}: неизвестный предикат #{unknown.join(', ')}; " \
                  "допустимы: #{PREDICATE_KEYS.join(', ')}"
          end

          predicates.each do |key, value|
            validate_predicate_value!(key, value, index)
          end
        end

        def self.validate_predicate_value!(key, value, index)
          if %w[amount_gte amount_lt eligible_count_lte].include?(key) && !value.is_a?(Integer)
            raise ArgumentError,
                  "правило ##{index}: #{key} должен быть Integer, получено #{value.inspect}"
          end
          return unless invalid_bank_list?(key, value)

          raise ArgumentError, "правило ##{index}: bank_in должен быть массивом строк"
        end

        def self.invalid_bank_list?(key, value)
          key == 'bank_in' && !(value.is_a?(Array) && value.all?(String))
        end

        def self.build_strategy!(name, index, config)
          return Strategies.build(name, config: config) if Strategies.known.include?(name)

          raise KeyError, "правило ##{index}: неизвестная стратегия #{name.inspect}; " \
                          "допустимы: #{Strategies.known.join(', ')}"
        end

        private_class_method :validate_predicates!, :validate_predicate_value!, :invalid_bank_list?,
                             :build_strategy!

        private

        def matches_predicate?(key, value, candidates, operation)
          case key
          when 'amount_gte' then operation.amount >= value
          when 'amount_lt' then operation.amount < value
          when 'bank_in' then value.include?(operation.bank)
          when 'eligible_count_lte' then candidates.size <= value
          end
        end

        def predicate_details(key, value, candidates, operation, matched:)
          case key
          when 'amount_gte' then amount_gte_details(operation.amount, value, matched)
          when 'amount_lt' then amount_lt_details(operation.amount, value, matched)
          when 'bank_in' then "bank #{operation.bank} из #{value.size}"
          when 'eligible_count_lte' then "eligible_count #{candidates.size} <= #{value}"
          end
        end

        def amount_gte_details(amount, value, matched)
          operator = matched ? '>=' : '<'
          "amount #{amount} #{operator} #{value}"
        end

        def amount_lt_details(amount, value, matched)
          operator = matched ? '<' : '>='
          "amount #{amount} #{operator} #{value}"
        end

        def why_details
          return '' if why.nil? || why.empty?

          " (причина: #{why})"
        end
      end

      def initialize(default:, rules:)
        @default = default
        @rules = rules.freeze
      end

      def call(candidates, operation, _state)
        rule = rules.find { |item| item.matches?(candidates, operation) }
        return selected_choice(rule, candidates, operation) if rule

        default_choice(candidates, operation)
      end

      private

      attr_reader :default, :rules

      def selected_choice(rule, candidates, operation)
        Choice.new(strategy: rule.strategy, rule_index: rule.index, why: rule.why,
                   details: rule.matched_details(candidates, operation))
      end

      def default_choice(candidates, operation)
        failed = rules.first&.failure_details(candidates, operation) || 'правил 0'
        details = "selector: 0 правил из #{rules.size} совпало, #{failed} -> " \
                  "default #{default.name}"
        Choice.new(strategy: default, rule_index: nil, why: nil, details: details)
      end
    end
  end
end
