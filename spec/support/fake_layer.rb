# frozen_string_literal: true

require 'routing/layers/base'

# Тестовые двойники для контракта слоя (spec/support/shared/layer_contract.rb)
# и property-теста (spec/routing/layers/contract_property_spec.rb). Никогда не
# регистрируются в Routing::Layers — существуют только для проверки того, что
# сам контракт реально ловит нарушение, до появления настоящих слоёв.
# В lib/ не переезжают никогда.
class FakeLayer < Routing::Layers::Base
  def name = 'fake_layer'

  def adjust(ranked, _operation, _state)
    ranked.reverse
  end
end

# Намеренно нарушает инвариант «слой не добавляет и не убирает кандидатов» —
# теряет последнего в списке. Используется только чтобы показать, что контракт
# и property-тест валят такой слой, а не молча его пропускают.
class BrokenFakeLayerDropsCandidate < Routing::Layers::Base
  def name = 'broken_fake_layer_drops_candidate'

  def adjust(ranked, _operation, _state)
    ranked[0..-2]
  end
end

# Намеренно нарушает тот же инвариант с другой стороны — подставляет
# постороннего, никогда не бывшего в ranked.
class BrokenFakeLayerInjectsForeign < Routing::Layers::Base
  def name = 'broken_fake_layer_injects_foreign'

  def adjust(ranked, operation, _state)
    foreign = ProviderFactory.build_provider(payment_system: "интервент-#{operation.operation_id}")
    ranked + [foreign]
  end
end
