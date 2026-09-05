# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'synthetic/generator'
require 'io/providers_loader'
require 'io/queue_loader'
require 'routing/constraints'
require 'routing/planner'
require 'routing/strategies'
require 'routing/strategies/count_share'
require 'state/providers'
require 'execution/executor'
require 'execution/outcome_source/deterministic'

Routing::Strategies.load_all!

# Быстрый спек генератора: только уровень smoke (200 операций), доли секунды.
# Не про распределение и не про бенчмарк — про то, что конструктивный оракул
# не разошёлся с настоящим Routing::Constraints, а сгенерённый вход читается
# штатными загрузчиками. l/xl/insane сюда не входят: make check обязан
# оставаться быстрым (см. Makefile).
# rubocop:disable RSpec/DescribeClass -- спек генератора, а не класс
RSpec.describe 'Synthetic generator (smoke)' do
  # rubocop:enable RSpec/DescribeClass
  def generate(seed: '42')
    bundle = Synthetic::Generator.prepare(level_name: 'smoke', seed: seed)
    operations = []
    Synthetic::Generator.each_operation(bundle) { |op| operations << op }
    [bundle, operations]
  end

  def build_pipeline(providers, seed: '42')
    conversions = providers.to_h { |p| [p.name, p.conversion_24h.to_f] }
    outcomes = Execution::OutcomeSource::Deterministic.new(seed: seed, conversions: conversions)
    strategy = Routing::Strategies.build('count_share')
    {
      state: State::Providers.new(providers),
      planner: Routing::Planner.new(providers: providers, strategy: strategy,
                                    fallback_provider: 'spacepayments'),
      executor: Execution::Executor.new(outcomes: outcomes)
    }
  end

  describe 'детерминизм' do
    # rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- три грани одной гарантии детерминизма.
    it 'один и тот же seed даёт побайтово одинаковые providers/queue/expectation' do
      bundle_a, ops_a = generate
      bundle_b, ops_b = generate
      providers_a = JSON.generate(bundle_a.provider_set.raw_providers)
      providers_b = JSON.generate(bundle_b.provider_set.raw_providers)

      expectation_a = JSON.generate(bundle_a.expectation.to_h)
      expectation_b = JSON.generate(bundle_b.expectation.to_h)

      expect(JSON.generate(ops_a)).to eq(JSON.generate(ops_b))
      expect(providers_a).to eq(providers_b)
      expect(expectation_a).to eq(expectation_b)
    end

    it 'разные seed дают разный вход' do
      _bundle_a, ops_a = generate(seed: '42')
      _bundle_b, ops_b = generate(seed: '43')

      expect(JSON.generate(ops_a)).not_to eq(JSON.generate(ops_b))
    end
  end

  describe 'конструктивный оракул против настоящего движка' do
    # Через живой State::Providers, а не голый Routing::Constraints.eligible?
    # без state: daily_limit_reject-якорь (queue.rb) сознательно зависит от
    # накопленного daily_approved_amount, а без state DailyLimit смотрит на
    # статичный снимок (всегда 0) и не сработает — это не баг оракула, это
    # свойство единственного state-зависимого hard-constraint (см. profiles.rb).
    # rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- один сквозной прогон дешевле множества мелких.
    it 'каждый якорь получает ровно предсказанного провайдера в реальном каскаде' do
      bundle, ops_raw = generate
      Dir.mktmpdir do |dir|
        providers_path = File.join(dir, 'providers.json')
        queue_path = File.join(dir, 'queue.json')
        raw = bundle.provider_set.raw_providers
        File.write(providers_path, JSON.generate('providers' => raw))
        File.write(queue_path, JSON.generate(ops_raw))

        providers = Io::ProvidersLoader.load(providers_path)
        queue_result = Io::QueueLoader.load(queue_path)
        expect(queue_result.errors).to be_empty

        pipeline = build_pipeline(providers)
        expect(pipeline[:state].fallback.name).to eq('spacepayments')

        expectation = bundle.expectation.to_h
        expect(expectation['exact']).not_to be_empty

        actual = {}
        queue_result.operations.each do |operation|
          plan = pipeline[:planner].plan(operation, pipeline[:state])
          outcome = pipeline[:executor].run(plan, operation, pipeline[:state])
          actual[operation.operation_id] = outcome.selected.name
        end

        expectation['exact'].each do |op_id, expected|
          expect(actual[op_id]).to eq(expected['provider']), "#{op_id}: got #{actual[op_id]}"
        end
        expect(actual.values.count { |name| name == 'spacepayments' })
          .to eq(expectation['counts']['spacepayments_used'])
      end
    end
  end

  describe 'профиль broken (надстройка над шумом)' do
    # rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- один сквозной прогон.
    it 'даёт ровно ожидаемое число ошибок очереди' do
      # smoke сам по себе broken_ratio: 0.0 — проверяем оверлей через
      # тот же Queue напрямую, с кастомным уровнем.
      level = Synthetic::Levels::Level.new(
        name: 'broken_smoke', operations: 1_000, providers: 5, profile: 'healthy',
        amount_min: 100, amount_max: 50_000, mode: :array, full_cli: true,
        exact_cap: 10_000, broken_ratio: 0.05, run_oracle: false
      )
      profile = Synthetic::Profiles.fetch(level.profile)
      provider_set = Synthetic::ProviderSet.build(level: level, profile: profile, seed: '9')
      expectation = Synthetic::Expectation.new(meta: {}, exact_cap: level.exact_cap)
      ops = []
      Synthetic::Queue.each(provider_set: provider_set, level: level, profile: profile, seed: '9',
                            expectation: expectation) { |op| ops << op }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'queue.json')
        File.write(path, JSON.generate(ops))
        result = Io::QueueLoader.load(path)

        expect(result.errors.size).to eq(expectation.to_h['counts']['queue_errors'])
        expect(result.operations.size).to eq(expectation.to_h['counts']['valid_operations'])
      end
    end
  end

  describe 'bin/route на сгенерённом входе' do
    let(:bin_route) { File.expand_path('../../bin/route', __dir__) }

    def run_route(*args)
      Open3.capture3('ruby', bin_route, *args)
    end

    # rubocop:disable-next RSpec/MultipleExpectations, RSpec/ExampleLength -- один прогон CLI, проверки о разных гранях одного вывода.
    it 'даёт валидную по контракту структуру, совпадающую с точным оракулом' do
      bundle, ops_raw = generate
      Dir.mktmpdir do |dir|
        providers_path = File.join(dir, 'providers.json')
        queue_path = File.join(dir, 'queue.json')
        raw = bundle.provider_set.raw_providers
        File.write(providers_path, JSON.generate('providers' => raw))
        File.write(queue_path, JSON.generate(ops_raw))
        config_path = File.expand_path('../../config/bench.yml', __dir__)

        _stdout, stderr, status = run_route(queue_path, '--providers', providers_path,
                                            '--config', config_path, '--out-dir', dir)
        expect(status.exitstatus).to eq(0), stderr

        decisions = JSON.parse(File.read(File.join(dir, 'routing_decisions_test.json')))
        decisions.each { |decision| expect(validate_structure(decision)).to eq([]) }

        by_id = decisions.to_h { |d| [d['operation_id'], d['selected_provider']] }
        bundle.expectation.to_h['exact'].each do |op_id, expected|
          expect(by_id[op_id]).to eq(expected['provider']), "#{op_id}: got #{by_id[op_id]}"
        end
      end
    end
  end
end
