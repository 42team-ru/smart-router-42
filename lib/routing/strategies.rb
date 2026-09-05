# frozen_string_literal: true

require_relative 'strategies/base'

module Routing
  # Реестр стратегий ранжирования: имя из конфига → класс стратегии.
  #
  # Существует ради одного свойства: сменить способ распределения заявок должно
  # быть можно строкой в YAML, а добавить новый — файлом в каталоге. Ни точка
  # входа, ни планировщик не содержат списка имён и о конкретных стратегиях не
  # знают.
  #
  # Реестр отдельный от Routing::Layers, хотя устроен так же: имена там
  # пересекаются, а контракты разные, и молчаливая подмена одного другим
  # выглядела бы как работающая настройка.
  module Strategies
    # rubocop:disable-next Style/MutableConstant -- реестр расширяется регистрацией классов.
    REGISTRY = {}

    class << self
      def register(name, klass)
        key = name.to_s
        raise ArgumentError, "strategy already registered: #{key}" if registry.key?(key)

        registry[key] = klass
        klass
      end

      # Собирает стратегию по имени. Реестр не знает, что лежит в конфиге, и
      # знать не должен: стратегия, которой нужны настройки, сама объявляет
      # фабрику from_config и забирает оттуда что ей надо — добавление
      # стратегии с параметрами не заставляет править общий реестр.
      #
      # Без конфига или без фабрики создаётся простым new. history — уже
      # загруженные наблюдаемые конверсии (Io::HistoryLoader); читать файл
      # самим стратегиям не положено — диска касается только bin/route.
      def build(name, config: nil, history: nil)
        klass = fetch!(name)
        return klass.from_config(config, history: history) if config &&
                                                              klass.respond_to?(:from_config)

        klass.new
      end

      def known = registry.keys.sort

      # Загружает каталог стратегий целиком: добавить стратегию — значит
      # положить файл в каталог и написать её имя в конфиге, ядро при этом
      # не трогается вовсе.
      #
      # Сортировка обязательна: порядок регистрации виден снаружи — в списке
      # известных имён и в текстах ошибок. Dir.glob сортирует сам, но это
      # деталь реализации, а не обещание, и опираться на неё при требовании
      # побайтовой воспроизводимости нельзя.
      #
      # base.rb попадает под маску, но ничего не регистрирует, поэтому
      # грузится безвредно.
      def load_all!
        # rubocop:disable-next Lint/RedundantDirGlobSort -- см. комментарий выше
        Dir[File.expand_path('strategies/*.rb', __dir__)].sort.each { |path| require path }
        known
      end

      private

      # rescue живёт здесь, а не вокруг build: иначе KeyError изнутри from_config
      # превратился бы в «unknown strategy» и спрятал настоящую ошибку.
      def fetch!(name)
        registry.fetch(name.to_s)
      rescue KeyError
        raise KeyError, "unknown strategy #{name.inspect}; known: #{known.join(', ')}"
      end

      def registry
        REGISTRY
      end
    end
  end
end
