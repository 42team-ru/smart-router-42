# frozen_string_literal: true

require 'io/provider_overrides'
require_relative '../support/provider_factory'

# Override из config/routing.yml поверх снапшота. Конфиг только перекрывает
# явно заданное, отсутствующий
# ключ оставляет снапшотное значение — в том числе nil.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- каждый пример проверяет
# несколько связанных полей одного применения override, дробить их — терять контекст сценария
RSpec.describe Io::ProviderOverrides do
  include ProviderFactory

  let(:vipay) { build_provider(payment_system: 'vipay', daily_turnover_max: 5_000_000) }
  let(:payflow) { build_provider(payment_system: 'payflow', daily_turnover_min: 2_000_000) }
  let(:providers) { [vipay, payflow] }

  describe '.apply' do
    it 'накладывает daily_turnover_min/max и requests_per_minute_limit' do
      applied = described_class.apply(
        providers,
        obligations: { 'vipay' => { 'daily_turnover_max' => 4_000_000 } },
        rate_limits: { 'vipay' => 7 }
      )

      result = applied.find { |p| p.name == 'vipay' }
      expect(result.daily_turnover_max).to eq(4_000_000)
      expect(result.requests_per_minute_limit).to eq(7)
    end

    it 'значение конфига перекрывает значение снапшота' do
      applied = described_class.apply(
        providers, obligations: { 'vipay' => { 'daily_turnover_max' => 1 } }
      )

      expect(applied.find { |p| p.name == 'vipay' }.daily_turnover_max).to eq(1)
    end

    it 'отсутствующий в конфиге провайдер не теряет снапшотное значение (в т.ч. nil)' do
      applied = described_class.apply(providers, obligations: {}, rate_limits: {})

      result = applied.find { |p| p.name == 'payflow' }
      expect(result.daily_turnover_min).to eq(2_000_000)
      expect(result.daily_turnover_max).to be_nil
      expect(result.requests_per_minute_limit).to be_nil
    end

    it 'отсутствующий ключ обязательства (только min задан) не затирает max' do
      applied = described_class.apply(
        providers, obligations: { 'vipay' => { 'daily_turnover_max' => 999 } }
      )

      result = applied.find { |p| p.name == 'vipay' }
      expect(result.daily_turnover_max).to eq(999)
      expect(result.daily_turnover_min).to be_nil
    end

    it 'не мутирует вход' do
      before = providers.dup

      described_class.apply(
        providers, obligations: { 'vipay' => { 'daily_turnover_max' => 1 } },
                   rate_limits: { 'payflow' => 3 }
      )

      expect(providers).to eq(before)
      expect(providers[0].daily_turnover_max).to eq(5_000_000)
      expect(providers[1].requests_per_minute_limit).to be_nil
    end

    it 'падает с отсортированным списком неизвестных провайдеров в obligations' do
      expect do
        described_class.apply(
          providers, obligations: { 'foo' => { 'daily_turnover_min' => 1 }, 'bar' => {} }
        )
      end.to raise_error(RuntimeError, /bar, foo/)
    end

    it 'падает с отсортированным списком неизвестных провайдеров в rate_limits' do
      expect do
        described_class.apply(providers, rate_limits: { 'zzz' => 1, 'aaa' => 2 })
      end.to raise_error(RuntimeError, /aaa, zzz/)
    end

    it 'пустой конфиг возвращает эквивалентный (тот же) список' do
      applied = described_class.apply(providers)

      expect(applied).to eq(providers)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
