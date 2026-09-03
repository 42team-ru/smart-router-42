# frozen_string_literal: true

require_relative 'strategies/base'

module Routing
  module Strategies
    # rubocop:disable-next Style/MutableConstant -- реестр расширяется регистрацией классов.
    REGISTRY = {}

    class << self
      def register(name, klass)
        key = name.to_s
        raise ArgumentError, "strategy already registered: #{key}" if registry.key?(key)

        registry[key] = klass
        klass
      end

      def build(name)
        registry.fetch(name.to_s).new
      rescue KeyError
        raise KeyError, "unknown strategy #{name.inspect}; known: #{known.join(', ')}"
      end

      def known = registry.keys.sort

      private

      def registry
        REGISTRY
      end
    end
  end
end
