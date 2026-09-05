# frozen_string_literal: true

require 'routing/share_ledger'

# Проверка самого контракта (spec/support/shared/layer_contract.rb) на
# фейковых слоях (spec/support/fake_layer.rb), пока настоящих слоёв ещё нет.
# Не тестирует прод-код — тестирует нашу тестовую обвязку: если этот файл
# когда-нибудь начнёт падать сам по себе, значит контракт сломан, а не
# сами слои.
RSpec.describe 'контракт слоя на фейковых двойниках' do
  include ProviderFactory

  let(:ranked) do
    [build_provider(payment_system: 'vipay'),
     build_provider(payment_system: 'payflow'),
     build_provider(payment_system: 'quickpay')]
  end
  let(:operation) { build_operation }
  let(:state) { Routing::ShareLedger.new }

  describe 'корректный слой (FakeLayer)' do
    subject(:layer) { FakeLayer.new }

    it_behaves_like 'контракт слоя'
  end

  describe 'слой, теряющий кандидата' do
    subject(:layer) { BrokenFakeLayerDropsCandidate.new }

    it 'контракт ловит потерю кандидата' do
      expect(layer.adjust(ranked, operation, state).map(&:name))
        .not_to match_array(ranked.map(&:name))
    end
  end

  describe 'слой, подставляющий постороннего' do
    subject(:layer) { BrokenFakeLayerInjectsForeign.new }

    it 'контракт ловит появление постороннего' do
      expect(layer.adjust(ranked, operation, state).map(&:name))
        .not_to match_array(ranked.map(&:name))
    end
  end
end
