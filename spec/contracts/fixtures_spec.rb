# frozen_string_literal: true

require 'json'
require 'routing/reasons'
require 'routing/attempt'

# Дубль validate_structure из reference/scripts/validate_10.rb, строки 53-71.
# Сам скрипт подключить нельзя — он выполняет main при загрузке. Логика
# продублирована здесь осознанно (те же поля, те же сообщения об ошибках),
# разбита на две части ради метрик линтера, смысл проверки не меняется.
def validate_top_level_fields(decision)
  %w[operation_id selected_provider attempts].filter_map do |field|
    "отсутствует поле #{field}" unless decision.key?(field)
  end
end

def validate_attempt_fields(attempt, index)
  errors = %w[provider decision reason].filter_map do |field|
    "attempts[#{index}]: отсутствует #{field}" unless attempt.key?(field)
  end
  unless %w[selected skipped].include?(attempt['decision'])
    errors << "attempts[#{index}]: decision должен быть selected или skipped"
  end
  errors
end

def validate_structure(decision)
  errors = validate_top_level_fields(decision)
  decision['attempts']&.each_with_index do |attempt, i|
    errors.concat(validate_attempt_fields(attempt, i))
  end
  errors
end

# rubocop:disable RSpec/DescribeClass -- фикстуры контрактов, а не класс
RSpec.describe 'фикстуры контрактов (attempt/decisions/report)' do
  # rubocop:enable RSpec/DescribeClass
  def load_fixture(name)
    JSON.parse(File.read(fixture_path('contracts', name)))
  end

  def load_reference_decisions
    JSON.parse(File.read(reference_path('reference_decisions.json')))
  end

  def expect_common_attempt_fields!(attempt)
    expect(attempt).to include('provider', 'decision', 'reason')
    expect(attempt['decision']).to(satisfy { |value| %w[selected skipped].include?(value) })
    expect(attempt['details']).to match(/\d/)
  end

  def expect_skipped_attempt!(attempt)
    expect(Routing::Reasons::SKIP).to include(attempt['reason'])
    expect(attempt).not_to include('strategy', 'attempt_no', 'result')
  end

  def expect_selected_attempt!(attempt)
    expect(Routing::Reasons::SELECTED).to include(attempt['reason'])
    expect(attempt).to include('strategy', 'attempt_no', 'result')
    expect(attempt['result']).to(satisfy { |value| %w[approved rejected expired].include?(value) })
  end

  # Проверки 2-7 из БРИФ P2 для одного элемента attempts — общие для
  # attempt.json и для attempts внутри decisions.json.
  def expect_attempt_shape!(attempt)
    expect_common_attempt_fields!(attempt)

    if attempt['decision'] == 'skipped'
      expect_skipped_attempt!(attempt)
    else
      expect_selected_attempt!(attempt)
    end
  end

  # Проверка 8: элемент строится через Routing::Attempt без исключения, и его
  # #to_h после JSON.parse(JSON.generate(...)) равен исходному элементу фикстуры.
  def expect_attempt_roundtrips!(attempt)
    built = Routing::Attempt.new(**attempt.transform_keys(&:to_sym))
    roundtripped = JSON.parse(JSON.generate(built.to_h))

    expect(roundtripped).to eq(attempt)
  end

  def expect_attempts_conform!(attempts)
    attempts.each do |attempt|
      expect_attempt_shape!(attempt)
      expect_attempt_roundtrips!(attempt)
    end
  end

  def last_valid_selected_provider(decision)
    decision['attempts'].select do |attempt|
      attempt['decision'] == 'selected' && attempt['result'] != 'rejected'
    end.last.fetch('provider')
  end

  def deterministic_provider_for(reference, operation_id)
    reference.fetch('deterministic_cases')
             .find { |c| c['operation_id'] == operation_id }
             &.fetch('required_provider')
  end

  describe 'attempt.json' do
    subject(:attempts) { load_fixture('attempt.json') }

    it 'является массивом' do
      expect(attempts).to be_an(Array)
    end

    it 'содержит 4 элемента' do
      expect(attempts.size).to eq(4)
    end

    it 'каждый элемент соответствует формату attempts и раундтрипится через Routing::Attempt' do
      expect_attempts_conform!(attempts)
    end
  end

  describe 'decisions.json' do
    subject(:decisions) { load_fixture('decisions.json') }

    let(:reference) { load_reference_decisions }

    it 'массив решений' do
      expect(decisions).to be_an(Array)
    end

    it 'каждое решение проходит validate_structure без ошибок' do
      decisions.each { |decision| expect(validate_structure(decision)).to eq([]) }
    end

    it 'каждый элемент attempts проходит те же проверки, что и в attempt.json' do
      decisions.each { |decision| expect_attempts_conform!(decision['attempts']) }
    end

    it 'провайдер встречается в attempts одного решения не более одного раза' do
      decisions.each do |decision|
        providers = decision['attempts'].map { |attempt| attempt['provider'] }
        expect(providers.uniq.size).to eq(providers.size)
      end
    end

    it 'selected_provider равен provider последнего selected-элемента с result != rejected' do
      decisions.each do |decision|
        expect(decision['selected_provider']).to eq(last_valid_selected_provider(decision))
      end
    end

    it 'selected_provider входит в eligible_providers эталона' do
      decisions.each do |decision|
        eligible = reference.fetch('eligible_providers').fetch(decision['operation_id'])

        expect(eligible).to include(decision['selected_provider'])
      end
    end

    it 'для deterministic_cases selected_provider равен required_provider (op_103 -> quickpay)' do
      decisions.each do |decision|
        required = deterministic_provider_for(reference, decision['operation_id'])
        expect(decision['selected_provider']).to eq(required) unless required.nil?
      end
    end

    it 'op_103 в частности требует quickpay' do
      matching = decisions.find { |decision| decision['operation_id'] == 'op_103' }

      expect(matching['selected_provider']).to eq('quickpay')
    end

    it 'simulated_result каждого решения допустим' do
      expect(decisions).to all(
        satisfy { |d| %w[approved rejected expired].include?(d['simulated_result']) }
      )
    end

    it 'latency_sec каждого решения — целое положительное число' do
      expect(decisions).to all(satisfy { |d|
        d['latency_sec'].is_a?(Integer) && d['latency_sec'].positive?
      })
    end
  end

  describe 'report.json' do
    subject(:report) { load_fixture('report.json') }

    let(:required_keys) do
      %w[period total_operations distribution skip_reasons projected_daily_utilization
         recommendations]
    end

    it 'содержит все обязательные по ТЗ ключи' do
      expect(required_keys.all? { |key| report.key?(key) }).to be(true)
    end

    it 'ключи верхнего уровня идут в порядке фикстуры' do
      expect(report.keys).to eq(
        %w[period total_operations strategy distribution volume_distribution
           attempt_distribution skip_reasons projected_daily_utilization fallback
           benchmark deviation_causes recommendations]
      )
    end

    it 'каждый элемент distribution имеет ровно нужные ключи' do
      expect(report['distribution'].values).to all(
        satisfy { |entry|
          entry.keys.sort == %w[achievable_pct count deviation_pp share_pct target_pct]
        }
      )
    end

    it 'сумма count по distribution равна total_operations' do
      total = report['distribution'].values.sum { |entry| entry['count'] }

      expect(total).to eq(report['total_operations'])
    end

    it 'сумма share_pct по distribution равна 100.0 с допуском 0.05' do
      total = report['distribution'].values.sum { |entry| entry['share_pct'] }

      expect(total).to be_within(0.05).of(100.0)
    end

    it 'ключи skip_reasons входят в Routing::Reasons::SKIP' do
      expect(report['skip_reasons'].keys).to all(satisfy { |reason|
        Routing::Reasons::SKIP.include?(reason)
      })
    end

    it 'benchmark присутствует и допускает null в значениях' do
      expect(report['benchmark'].values).to all(satisfy { |v| v.nil? || v.is_a?(Numeric) })
    end

    it 'deviation_causes присутствует' do
      expect(report).to have_key('deviation_causes')
    end

    it 'recommendations — массив строк' do
      expect(report['recommendations']).to all(be_a(String))
    end

    it 'каждая рекомендация содержит цифру' do
      expect(report['recommendations']).to all(match(/\d/))
    end
  end
end
