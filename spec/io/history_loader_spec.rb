# frozen_string_literal: true

require 'io/history_loader'

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength -- контрольные
# числа проверяются девяткой связанных значений (approved/rejected/expired на
# трёх провайдеров) на одном прогоне; дробить it на девять примеров — терять
# из виду, что все девять посчитаны одним k.
RSpec.describe Io::HistoryLoader do
  describe '.load на operations_history.csv (контрольные числа сглаживания)' do
    subject(:stats) { described_class.load(reference_path('operations_history.csv')) }

    it 'выводит k методом моментов, а не хардкодит его (mu=0.68, k≈11.39)' do
      expect(stats.k.to_f).to be_within(0.02).of(11.39)
    end

    it 'сглаживает approved_bp/rejected_bp/expired_bp с допуском ±2 бп на округление' do
      expect(stats.approved_bp('vipay')).to be_within(2).of(7586)
      expect(stats.rejected_bp('vipay')).to be_within(2).of(1493)
      expect(stats.expired_bp('vipay')).to be_within(2).of(920)

      expect(stats.approved_bp('quickpay')).to be_within(2).of(6761)
      expect(stats.rejected_bp('quickpay')).to be_within(2).of(1717)
      expect(stats.expired_bp('quickpay')).to be_within(2).of(1522)

      expect(stats.approved_bp('payflow')).to be_within(2).of(5510)
      expect(stats.rejected_bp('payflow')).to be_within(2).of(1587)
      expect(stats.expired_bp('payflow')).to be_within(2).of(2903)
    end

    it 'сглаженный payflow (маленькая выборка) поднимается заметно выше сырых 4737 бп' do
      expect(stats.approved_bp('payflow')).to be > 5300
    end

    it 'сглаженный vipay (большая выборка) опускается заметно ниже сырых 7805 бп' do
      expect(stats.approved_bp('vipay')).to be < 7700
    end
  end

  describe '.load с outcomes.smoothing: false -- сырые доли approved/всего' do
    subject(:stats) do
      described_class.load(reference_path('operations_history.csv'), smoothing: false)
    end

    it 'не сглаживает — approved_bp совпадает с approved/всего по провайдеру' do
      expect(stats.approved_bp('vipay')).to eq(7805)
      expect(stats.approved_bp('quickpay')).to eq(6750)
      expect(stats.approved_bp('payflow')).to eq(4737)
    end

    it 'помечает объект как несглаженный' do
      expect(stats.smoothed?).to be(false)
    end
  end

  describe 'k пересчитывается по входным данным, а не зашит константой' do
    it 'на выборке с другим разбросом даёт другой k' do
      reference_k = described_class.load(reference_path('operations_history.csv')).k
      other_k = described_class.load(fixture_path('history', 'wide_spread.csv')).k

      expect(other_k).not_to eq(reference_k)
      expect(other_k.to_f).to be_within(0.01).of(3.0)
    end
  end

  describe 'провайдер с малой выборкой сдвигается к общему среднему сильнее' do
    it 'на n=1 сдвиг заметно больше, чем на n=40+' do
      stats = described_class.load(fixture_path('history', 'sample_size_shift.csv'))

      raw_bp = lambda do |name|
        (Rational(stats.approved_count(name), stats.observations(name)) * 10_000).round
      end
      shift = lambda do |name|
        (raw_bp.call(name) - stats.approved_bp(name)).abs
      end

      expect(shift.call('solo')).to be > shift.call('bulkhigh') * 10
      expect(shift.call('solo')).to be > shift.call('bulklow') * 10
    end
  end

  describe 'провайдер отсутствует в истории вовсе' do
    subject(:stats) { described_class.load(reference_path('operations_history.csv')) }

    it 'не падает и отдаёт явный скалярный дефолт' do
      expect(stats.known?('spacepayments')).to be(false)
      expect(stats.approved_bp('spacepayments')).to eq(Io::HistoryStats::DEFAULT_APPROVED_BP)
      expect(stats.rejected_bp('spacepayments')).to eq(Io::HistoryStats::DEFAULT_REJECTED_BP)
      expect(stats.observations('spacepayments')).to eq(0)
    end
  end

  describe 'вырожденные файлы истории' do
    it 'пустой файл (только заголовок) не роняет загрузку' do
      stats = described_class.load(fixture_path('history', 'empty.csv'))

      expect(stats.providers).to eq([])
      expect(stats.k).to eq(0)
      expect(stats.approved_bp('vipay')).to eq(Io::HistoryStats::DEFAULT_APPROVED_BP)
    end

    it 'файл с одним провайдером не роняет загрузку и не сглаживает (не к чему тянуть)' do
      stats = described_class.load(fixture_path('history', 'single_provider.csv'))

      expect(stats.providers).to eq(['vipay'])
      expect(stats.k).to eq(0)
      expect(stats.approved_bp('vipay')).to eq(5000)
      expect(stats.rejected_bp('vipay')).to eq(2500)
      expect(stats.expired_bp('vipay')).to eq(2500)
    end
  end

  describe '.load с несуществующим файлом' do
    it 'падает с понятным сообщением' do
      expect { described_class.load('no/such/history.csv') }
        .to raise_error(/Файл истории операций не найден/)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
