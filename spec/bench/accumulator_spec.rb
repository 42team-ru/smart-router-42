# frozen_string_literal: true

require 'json'
require 'synthetic/generator'
require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/planner'
require 'routing/strategies'
require 'routing/strategies/count_share'
require 'reporting/report_builder'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/deterministic'
require 'bench/accumulator'
require 'tmpdir'

Routing::Strategies.load_all!

# Единственная защита от того, что быстрый Bench::Accumulator (без pairs в
# памяти) считает не то же самое, что боевой Reporting::ReportBuilder (с
# pairs целиком): гоняет один и тот же smoke-вход обоими путями и сверяет
# пересекающиеся поля. achievable_pct/target_pct/deviation_pp в пересечение
# не входят — они требуют Routing::Achievable, которого у Accumulator
# намеренно нет (см. план бенчмарка, раздел про уровни l/xl/insane).
RSpec.describe Bench::Accumulator do
  def normalize(outcome)
    attempts = outcome.attempts.map do |attempt|
      name = attempt.provider.respond_to?(:name) ? attempt.provider.name : attempt.provider
      attempt.with(provider: name)
    end
    outcome.with(attempts: attempts)
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- один сквозной прогон, а не десяток мелких.
  it 'совпадает с Reporting::ReportBuilder по count/share/attempts/fallback на smoke' do
    bundle = Synthetic::Generator.prepare(level_name: 'smoke', seed: '42')
    ops_raw = []
    Synthetic::Generator.each_operation(bundle) { |op| ops_raw << op }

    Dir.mktmpdir do |dir|
      providers_path = File.join(dir, 'providers.json')
      queue_path = File.join(dir, 'queue.json')
      File.write(providers_path, JSON.generate('providers' => bundle.provider_set.raw_providers))
      File.write(queue_path, JSON.generate(ops_raw))

      providers = Io::ProvidersLoader.load(providers_path)
      operations = Io::QueueLoader.load(queue_path).operations

      outcome_table = Execution::OutcomeSource::Deterministic.passport_outcome_table(providers)
      outcomes = Execution::OutcomeSource::Deterministic.new(seed: '42',
                                                             outcome_table: outcome_table)
      state = State::Providers.new(providers)
      planner = Routing::Planner.new(providers: providers, strategy: Routing::Strategies.build('count_share'),
                                     fallback_provider: 'spacepayments')
      executor = Execution::Executor.new(outcomes: outcomes)

      accumulator = described_class.new(provider_names: providers.map(&:name))
      pairs = operations.map do |operation|
        plan = planner.plan(operation, state)
        outcome = executor.run(plan, operation, state)
        accumulator.add(operation, outcome)
        # Execution::Executor кладёт Domain::Provider в Attempt#provider;
        # bin/route нормализует его в строку до ReportBuilder
        # (explain_first_attempt/rebuild_attempt) — здесь тот же шаг руками,
        # иначе Distributions.by_attempt группирует по объекту и ReportBuilder
        # сам вернёт одни нули, а не честную базу для сравнения.
        [operation, normalize(outcome)]
      end

      report = Reporting::ReportBuilder.build(pairs, providers: providers)

      report['distribution'].each do |name, entry|
        expect(accumulator.distribution.dig(name, 'count')).to eq(entry['count'])
        expect(accumulator.distribution.dig(name, 'share_pct')).to eq(entry['share_pct'])
      end

      report['volume_distribution'].each do |name, entry|
        expect(accumulator.volume_distribution.dig(name, 'amount')).to eq(entry['amount'])
        expect(accumulator.volume_distribution.dig(name, 'share_pct')).to eq(entry['share_pct'])
      end

      report['attempt_distribution'].each do |name, entry|
        expect(accumulator.attempt_distribution[name]).to eq(entry)
      end

      expect(accumulator.skip_reasons).to eq(report['skip_reasons'])
      expect(accumulator.fallback).to eq(report['fallback'])
    end
  end
end
