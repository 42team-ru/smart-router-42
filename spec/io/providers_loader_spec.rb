# frozen_string_literal: true

require 'io/providers_loader'
require 'domain/provider'

# rubocop:disable RSpec/MultipleExpectations -- каждый пример проверяет несколько
# связанных полей одного и того же загруженного провайдера, дробить их — терять контекст
RSpec.describe Io::ProvidersLoader do
  describe '.load' do
    subject(:providers) { described_class.load(reference_path('providers.json')) }

    it 'возвращает Domain::Provider на каждого провайдера снапшота' do
      expect(providers).to all(be_a(Domain::Provider))
      expect(providers.map(&:name)).to eq(%w[vipay payflow quickpay spacepayments])
    end

    it 'грузит spacepayments тем же кодом, без спецкейсов' do
      spacepayments = providers.find { |p| p.name == 'spacepayments' }

      expect(spacepayments.limit_amount_min).to be_nil
      expect(spacepayments.limit_amount_max).to be_nil
      expect(spacepayments.daily_amount_limit).to be_nil
      expect(spacepayments.in_progress_count_limit).to be_nil
    end

    it 'null в лимите остаётся nil, а не нулём' do
      vipay = providers.find { |p| p.name == 'vipay' }

      expect(vipay.limit_amount_min).to eq(1000)
      expect(vipay.limit_amount_max).to eq(100_000)
    end

    it 'поля, которых нет в снапшоте, приходят nil' do
      vipay = providers.find { |p| p.name == 'vipay' }

      expect(vipay.volume_share_pct).to be_nil
      expect(vipay.requests_per_minute_limit).to be_nil
      expect(vipay.daily_turnover_min).to be_nil
      expect(vipay.daily_turnover_max).to be_nil
    end

    it 'сохраняет банки и признак exclude_banks' do
      payflow = providers.find { |p| p.name == 'payflow' }

      expect(payflow.banks).to eq(%w[sberbank alfa])
      expect(payflow.exclude_banks).to be(false)
    end
  end

  describe '.load с несуществующим файлом' do
    it 'падает с понятным сообщением' do
      expect { described_class.load('no/such/providers.json') }
        .to raise_error(/Файл провайдеров не найден/)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations
