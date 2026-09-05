# frozen_string_literal: true

require_relative 'levels'
require_relative 'profiles'
require_relative 'provider_set'
require_relative 'queue'
require_relative 'expectation'

module Synthetic
  # Единственная точка входа для bin/gen и lib/bench: собирает уровень,
  # профиль и провайдеров, отдаёт поток операций и (после того как поток
  # полностью пройден) готовый Expectation.
  module Generator
    Bundle = Data.define(:level, :profile, :seed, :provider_set, :expectation)

    def self.prepare(level_name:, seed:)
      level = Levels.fetch(level_name)
      profile = Profiles.fetch(level.profile)
      provider_set = ProviderSet.build(level: level, profile: profile, seed: seed)
      expectation = Expectation.new(meta: meta(level, profile, seed), exact_cap: level.exact_cap)

      Bundle.new(level: level, profile: profile, seed: seed, provider_set: provider_set,
                 expectation: expectation)
    end

    # Полностью проходит поток операций один раз, передавая каждую вызывающему.
    # expectation.to_h корректен только ПОСЛЕ того, как этот метод вернул
    # управление — коридоры (distribution_pp/delivered) считаются в конце
    # прохода, а не заранее.
    def self.each_operation(bundle, &)
      Queue.each(provider_set: bundle.provider_set, level: bundle.level, profile: bundle.profile,
                 seed: bundle.seed, expectation: bundle.expectation, &)
    end

    def self.meta(level, profile, seed)
      {
        'level' => level.name, 'seed' => seed.to_s, 'operations' => level.operations,
        'providers' => level.providers, 'profile' => profile.name, 'generator_version' => 1
      }
    end
    private_class_method :meta
  end
end
