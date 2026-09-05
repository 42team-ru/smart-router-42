# frozen_string_literal: true

require 'json'
require 'domain/operation'
require 'domain/provider'
require 'routing/reasons'
require 'routing/violation'
require 'routing/attempt'
require 'routing/constraints/base'
require 'routing/constraints'
require 'routing/strategies/base'
require 'routing/layers/base'
require 'routing/route_plan'
require 'execution/outcome'
require 'execution/executor'
require 'execution/outcome_source/base'
require 'state/providers'

# Спек ловит переименование метода и молчаливую смену сигнатуры в семи
# замороженных интерфейсах пакета P1. Логики здесь нет — только контракт.
# rubocop:disable RSpec/DescribeClass -- один спек проверяет семь разных интерфейсов
RSpec.describe 'семь замороженных интерфейсов' do
  # rubocop:enable RSpec/DescribeClass
  def build_provider(name)
    Domain::Provider.new(
      payment_system: name, status: nil, traffic_percentage: nil, priority: nil,
      limit_amount_min: nil, limit_amount_max: nil, daily_amount_limit: nil,
      daily_approved_amount: nil, in_progress_count_limit: nil, in_progress_count: nil,
      in_progress_amount_limit: nil, in_progress_amount: nil, available_requisites: nil,
      conversion_24h: nil, avg_latency_sec: nil, banks: nil, exclude_banks: nil,
      provider_margin_pct: nil, merchant_margin_pct: nil, allow_negative_agreement: nil,
      volume_share_pct: nil, requests_per_minute_limit: nil, daily_turnover_min: nil,
      daily_turnover_max: nil
    )
  end

  describe 'Routing::Constraints::Base (интерфейс 1: Constraint)' do
    subject(:described_class) { Routing::Constraints::Base }

    it 'определяет классовый метод .violation' do
      expect(described_class).to respond_to(:violation)
    end

    it 'сигнатура .violation — (provider, operation, state), все req' do
      expect(described_class.method(:violation).parameters).to eq(
        [%i[req provider], %i[req operation], %i[req state]]
      )
    end

    it 'заглушка поднимает NotImplementedError' do
      expect { described_class.violation(nil, nil, nil) }.to raise_error(NotImplementedError)
    end
  end

  describe 'Routing::Strategies::Base (интерфейс 2: Strategy)' do
    subject(:described_class) { Routing::Strategies::Base }

    it 'определяет инстансный метод #rank' do
      expect(described_class.instance_methods(false)).to include(:rank)
    end

    it 'сигнатура #rank — (candidates, operation, state), все req' do
      expect(described_class.instance_method(:rank).parameters).to eq(
        [%i[req candidates], %i[req operation], %i[req state]]
      )
    end

    it 'заглушка поднимает NotImplementedError' do
      expect { described_class.new.rank(nil, nil, nil) }.to raise_error(NotImplementedError)
    end
  end

  describe 'Routing::Layers::Base (интерфейс 3: Layer)' do
    subject(:described_class) { Routing::Layers::Base }

    it 'определяет инстансный метод #adjust' do
      expect(described_class.instance_methods(false)).to include(:adjust)
    end

    it 'сигнатура #adjust — (ranked, operation, state), все req' do
      expect(described_class.instance_method(:adjust).parameters).to eq(
        [%i[req ranked], %i[req operation], %i[req state]]
      )
    end

    it 'заглушка поднимает NotImplementedError' do
      expect { described_class.new.adjust(nil, nil, nil) }.to raise_error(NotImplementedError)
    end
  end

  describe 'Routing::RoutePlan (интерфейс 4: RoutePlan)' do
    subject(:described_class) { Routing::RoutePlan }

    it 'сигнатура .new сохраняет три обязательных ключа и добавляет optional trace' do
      expect(described_class.instance_method(:initialize).parameters).to eq(
        [%i[keyreq operation], %i[keyreq candidates], %i[keyreq skipped], %i[key trace]]
      )
    end

    it 'строится из пустых candidates/skipped без ошибок' do
      plan = described_class.new(operation: nil, candidates: [], skipped: [])

      expect([plan.empty?, plan.trace]).to eq([true, nil])
    end

    it 'дубли по имени в candidates поднимают ArgumentError' do
      dup = build_provider('vipay')

      expect do
        described_class.new(operation: nil, candidates: [dup, dup], skipped: [])
      end.to raise_error(ArgumentError)
    end
  end

  describe 'Execution::Executor (интерфейс 5: Executor)' do
    subject(:described_class) { Execution::Executor }

    it 'определяет инстансный метод #run' do
      expect(described_class.instance_methods(false)).to include(:run)
    end

    it 'сигнатура #run — (plan, operation, state), все req' do
      expect(described_class.instance_method(:run).parameters).to eq(
        [%i[req plan], %i[req operation], %i[req state]]
      )
    end
  end

  describe 'State::Providers (интерфейс 6: State::Providers)' do
    subject(:described_class) { State::Providers }

    %i[reserve commit rollback hold].each do |method_name|
      it "определяет ##{method_name}" do
        expect(described_class.instance_methods(false)).to include(method_name)
      end

      it "сигнатура ##{method_name} — (provider, operation), все req" do
        expect(described_class.instance_method(method_name).parameters).to eq(
          [%i[req provider], %i[req operation]]
        )
      end
    end
  end

  describe 'Execution::OutcomeSource::Base (интерфейс 7: OutcomeSource)' do
    subject(:described_class) { Execution::OutcomeSource::Base }

    it 'определяет инстансный метод #call' do
      expect(described_class.instance_methods(false)).to include(:call)
    end

    it 'сигнатура #call — (operation, provider, attempt_no), все req' do
      expect(described_class.instance_method(:call).parameters).to eq(
        [%i[req operation], %i[req provider], %i[req attempt_no]]
      )
    end

    it 'заглушка поднимает NotImplementedError' do
      expect { described_class.new.call(nil, nil, nil) }.to raise_error(NotImplementedError)
    end
  end

  describe 'Routing::Reasons::SKIP' do
    it 'содержит ровно 10 дословных причин отсева' do
      expect(Routing::Reasons::SKIP.size).to eq(10)
    end

    it 'заморожен' do
      expect(Routing::Reasons::SKIP.frozen?).to be(true)
    end

    it 'является надмножеством причин из reference_decisions.json' do
      reference = JSON.parse(File.read(reference_path('reference_decisions.json')))
      expected_reasons = reference.fetch('skip_reasons_expected').values.flat_map(&:values).uniq

      expect(expected_reasons - Routing::Reasons::SKIP).to eq([])
    end
  end

  # SELECTED пополнился ровно одной причиной (fallback_after_cascade), SKIP не
  # изменился -- список отсева остаётся дословным по эталону организаторов
  # (проверяется выше).
  describe 'Routing::Reasons::SELECTED' do
    it 'содержит ровно 6 причин выбора' do
      expect(Routing::Reasons::SELECTED.size).to eq(6)
    end

    it 'заморожен' do
      expect(Routing::Reasons::SELECTED.frozen?).to be(true)
    end

    it 'включает fallback_after_cascade (буквальное прочтение ТЗ)' do
      expect(Routing::Reasons::SELECTED).to include('fallback_after_cascade')
    end

    it 'не пересекается с SKIP: причина выбора не может быть причиной отсева' do
      expect(Routing::Reasons::SELECTED & Routing::Reasons::SKIP).to eq([])
    end
  end

  describe 'Routing::Attempt' do
    let(:provider) { build_provider('vipay') }
    let(:full_attempt) do
      Routing::Attempt.new(
        provider: provider, decision: 'selected', reason: 'first_eligible',
        details: '1 candidate', strategy: 'round_robin', attempt_no: 1, result: 'approved'
      )
    end

    it 'принимает decision: "selected"' do
      expect do
        Routing::Attempt.new(provider: provider, decision: 'selected', reason: 'first_eligible')
      end.not_to raise_error
    end

    it 'принимает decision: "skipped"' do
      expect do
        Routing::Attempt.new(provider: provider, decision: 'skipped', reason: 'bank_not_in_list')
      end.not_to raise_error
    end

    it 'поднимает ArgumentError на произвольном значении decision' do
      expect do
        Routing::Attempt.new(provider: provider, decision: 'failed', reason: 'x')
      end.to raise_error(ArgumentError)
    end

    it '#to_h для полного набора полей возвращает ключи в фиксированном порядке' do
      expect(full_attempt.to_h.keys).to eq(%i[provider decision reason details strategy
                                              attempt_no result])
    end

    it '#to_h для минимального набора полей отбрасывает nil, кроме обязательных' do
      attempt = Routing::Attempt.new(provider: provider, decision: 'selected', reason: 'x')

      expect(attempt.to_h.keys).to eq(%i[provider decision reason])
    end
  end
end
