# frozen_string_literal: true

require 'config/loader'

# config/routing.yml держится коротким: в час стопкода в нём должны быть видны
# значения, а не проза. Обоснования живут в config/routing.annotated.yml.
#
# Разделение работает, только пока файлы несут ОДИН И ТОТ ЖЕ конфиг. Иначе
# аннотированная копия тихо протухает и начинает объяснять поведение, которого
# нет, — а это хуже, чем отсутствие комментариев вовсе.
#
# Сравниваются разобранные конфиги, а не текст: комментарии, порядок ключей и
# переносы строк отличаться обязаны, значения — нет.
#
# rubocop:disable-next RSpec/DescribeClass -- проверяется пара файлов конфига,
# а не класс.
RSpec.describe 'config/routing.annotated.yml' do
  def config_path(name) = File.expand_path("../../config/#{name}", __dir__)

  let(:production) { Config::Loader.load(config_path('routing.yml')) }
  let(:annotated) { Config::Loader.load(config_path('routing.annotated.yml')) }

  it 'несёт ровно тот же конфиг, что и боевой config/routing.yml' do
    expect(annotated).to eq(production)
  end

  # Отдельно от сравнения целиком: при расхождении RSpec покажет, КАКОЙ ключ
  # разъехался, а не свалит в одну строку весь Data-объект.
  it 'совпадает с боевым по каждому ключу в отдельности' do
    production.to_h.each_key do |key|
      expect(annotated.public_send(key)).to eq(production.public_send(key)),
                                            "ключ #{key} разошёлся с config/routing.yml"
    end
  end

  # Аннотированный файл — валидный конфиг, а не текстовая справка: по нему
  # можно прогнать bin/route и получить тот же результат. Проверяется тем, что
  # он вообще загрузился выше, плюс явным утверждением про боевой источник:
  # если кто-то оставит здесь deterministic «для примера», прогон по этому
  # файлу разойдётся со сдаваемым, а спек это назовёт.
  it 'сохраняет боевой источник исходов, а не демонстрационный' do
    expect(annotated.outcomes['source']).to eq('always_ok')
  end
end
