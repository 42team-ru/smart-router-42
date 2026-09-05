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
  #
  # Дальше по коду: Routing::Strategies::Base — контракт одной стратегии;
  # Routing::Assembly — где имя из конфига превращается в объект;
  # scripts/demo_new_strategy.sh — демонстрация «файл плюс строка», ядро не
  # трогается.
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

      # Собирает стратегию по имени.
      #
      # Реестр не знает, что лежит в конфиге, и знать не должен: стратегия,
      # которой нужны настройки, сама объявляет фабрику from_config и забирает
      # оттуда что ей надо. Так добавление стратегии с параметрами не заставляет
      # править реестр — а он общий для всех.
      #
      # Без конфига или без фабрики создаётся простым new: большинство стратегий
      # параметров не имеет.
      # history — уже загруженные наблюдаемые конверсии (Io::HistoryLoader).
      # Стратегии, которым они нужны, объявляют from_config и принимают их
      # именованным аргументом; читать файл самим им не положено — диска
      # касается только bin/route.
      def build(name, config: nil, history: nil)
        klass = fetch!(name)
        return klass.from_config(config, history: history) if config &&
                                                              klass.respond_to?(:from_config)

        klass.new
      end

      def known = registry.keys.sort

      # Загружает каталог стратегий целиком.
      #
      # Ради этого метода в bin/route нет ни одного поимённого require
      # стратегии: добавить стратегию — значит положить файл в каталог и
      # написать её имя в конфиге, ядро при этом не трогается вовсе.
      #
      # Сортировка обязательна и не является перестраховкой: порядок
      # регистрации виден снаружи — в списке известных имён и в текстах ошибок.
      # Dir.glob сортирует сам, но это деталь реализации, а не обещание, и
      # опираться на неё в проекте с требованием побайтовой воспроизводимости
      # нельзя.
      #
      # base.rb попадает под маску, но ничего не регистрирует, поэтому грузится
      # безвредно.
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
