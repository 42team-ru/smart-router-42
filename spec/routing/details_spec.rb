# frozen_string_literal: true

require 'routing/details'

RSpec.describe Routing::Details do
  describe '.inactive' do
    it 'формирует сравнение статуса с числом допустимых статусов' do
      expect(described_class.inactive('suspended'))
        .to eq('status suspended != active (1 допустимый статус)')
    end

    it 'содержит цифру' do
      expect(described_class.inactive('suspended')).to match(/\d/)
    end
  end

  describe '.zero_traffic' do
    it 'формирует сравнение доли трафика с нулём' do
      expect(described_class.zero_traffic(0)).to eq('traffic_percentage 0 == 0')
    end

    it 'содержит цифру' do
      expect(described_class.zero_traffic(0)).to match(/\d/)
    end
  end

  describe '.no_requisites' do
    it 'формирует сравнение количества реквизитов с нулём' do
      expect(described_class.no_requisites(0)).to eq('available_requisites 0 == 0')
    end

    it 'содержит цифру' do
      expect(described_class.no_requisites(0)).to match(/\d/)
    end
  end

  describe '.below_min' do
    it 'формирует сравнение суммы с минимальным лимитом' do
      expect(described_class.below_min(800, 1000)).to eq('800 < limit_amount_min 1000')
    end

    it 'содержит цифру' do
      expect(described_class.below_min(800, 1000)).to match(/\d/)
    end
  end

  describe '.above_max' do
    it 'формирует сравнение суммы с максимальным лимитом' do
      expect(described_class.above_max(150_000, 100_000))
        .to eq('150000 > limit_amount_max 100000')
    end

    it 'содержит цифру' do
      expect(described_class.above_max(150_000, 100_000)).to match(/\d/)
    end
  end

  describe '.sum_over' do
    it 'формирует сравнение накопленной суммы с лимитом' do
      expect(
        described_class.sum_over('daily_approved_amount', 2_900_000, 150_000,
                                 'daily_amount_limit', 3_000_000)
      ).to eq('daily_approved_amount 2900000 + 150000 = 3050000 > daily_amount_limit 3000000')
    end

    it 'содержит цифру' do
      result = described_class.sum_over('daily_approved_amount', 2_900_000, 150_000,
                                        'daily_amount_limit', 3_000_000)

      expect(result).to match(/\d/)
    end
  end

  describe '.bank_not_allowed' do
    it 'формирует сравнение банка со списком допустимых банков' do
      expect(described_class.bank_not_allowed('alfa', %w[sberbank tinkoff vtb]))
        .to eq('bank alfa не входит в banks [sberbank, tinkoff, vtb] (3 банка)')
    end

    it 'содержит цифру' do
      expect(described_class.bank_not_allowed('alfa', %w[sberbank tinkoff vtb])).to match(/\d/)
    end
  end

  describe '.bank_excluded' do
    it 'формирует сравнение банка со списком исключённых банков' do
      expect(described_class.bank_excluded('sberbank', %w[sberbank]))
        .to eq('bank sberbank входит в exclude_banks [sberbank] (1 банк)')
    end

    it 'содержит цифру' do
      expect(described_class.bank_excluded('sberbank', %w[sberbank])).to match(/\d/)
    end
  end

  describe '.negative_margin' do
    it 'формирует сравнение маржи провайдера с маржой мерчанта' do
      expect(described_class.negative_margin(1.8, 1.5))
        .to eq('provider_margin_pct 1.8 > merchant_margin_pct 1.5, allow_negative_agreement false')
    end

    it 'содержит цифру' do
      expect(described_class.negative_margin(1.8, 1.5)).to match(/\d/)
    end
  end

  describe 'склонение слова «банк»' do
    it '1 банк' do
      expect(described_class.bank_excluded('sberbank', %w[sberbank])).to include('1 банк)')
    end

    it '3 банка' do
      expect(described_class.bank_not_allowed('alfa', %w[sberbank tinkoff vtb]))
        .to include('3 банка)')
    end

    it '5 банков' do
      banks = %w[sberbank tinkoff vtb qiwi yoomoney]

      expect(described_class.bank_not_allowed('alfa', banks)).to include('5 банков)')
    end
  end
end
