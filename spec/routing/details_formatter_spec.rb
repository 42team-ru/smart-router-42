# frozen_string_literal: true

require 'routing/details_formatter'

RSpec.describe Routing::DetailsFormatter do
  describe '.only_eligible_provider' do
    it 'совпадает с контрактной фикстурой op_103: "1 допустимый провайдер из 3"' do
      expect(described_class.only_eligible_provider(3)).to eq('1 допустимый провайдер из 3')
    end
  end

  describe '.fallback_no_eligible_provider' do
    it 'совпадает с форматом bin/route: "допустимых внешних провайдеров 0 из 3"' do
      expect(described_class.fallback_no_eligible_provider(3))
        .to eq('допустимых внешних провайдеров 0 из 3')
    end
  end

  describe '.next_in_cascade' do
    it 'совпадает с контрактной фикстурой op_106' do
      expect(described_class.next_in_cascade('vipay', 1, 'count_share')).to eq(
        'vipay отказал на попытке 1, следующий в каскаде по count_share'
      )
    end
  end

  describe '.first_eligible' do
    it 'содержит число кандидатов в каскаде' do
      expect(described_class.first_eligible(2)).to match(/\d/)
    end
  end
end
