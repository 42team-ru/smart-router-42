# frozen_string_literal: true

require_relative 'errors'
require_relative '../routing/strategies'
require_relative '../routing/layers'

module Config
  # CFG-1: валидация полей-коллекций конфига (layers, amount_ranges, obligations,
  # rate_limits, cascade, comparison). Вынесено из SchemaValidator отдельным
  # модулем, чтобы оба файла оставались небольшими и проверяемыми по отдельности.
  # rubocop:disable-next Metrics/ModuleLength -- набор мелких проверок одной формы
  # (список, отображение, известное имя) на каждое коллекционное поле конфига;
  # разрезание по полям потеряло бы связность одного модуля правил.
  module SchemaRules
    OBLIGATION_KEYS = %w[daily_turnover_min daily_turnover_max].freeze

    # П7 (docs/plans/P6/P7_настраиваемый_fallback.md): переключатель поведения
    # каскада. Отсутствующий ключ `cascade` целиком и отсутствующие подключи —
    # законный вход, дефолты подставляются на стороне сборки (bin/route), не
    # здесь -- здесь только форма и допустимые значения.
    CASCADE_KEYS = %w[exhausted on_timeout].freeze
    CASCADE_ALLOWED_VALUES = {
      'exhausted' => %w[last_candidate fallback_provider].freeze,
      'on_timeout' => %w[stop continue].freeze
    }.freeze

    # Источники исходов, которые умеет собрать bin/route. Держим список здесь,
    # а не только в bin/route: опечатка в имени источника должна падать на
    # загрузке конфига внятным сообщением, а не «неизвестный источник» позже.
    # scripted требует ещё и outcomes.script -- путь к сценарию.
    OUTCOME_SOURCES = %w[deterministic always_ok always_fail scripted].freeze

    # Допустимые исходы во встроенном сценарии. Совпадают с
    # Execution::OutcomeSource::Scripted::ALLOWED, но записаны строками: конфиг
    # грузится без permitted_classes: [Symbol], в нём это обычный текст.
    SCRIPT_OUTCOMES = %w[approved rejected expired].freeze

    def self.validate_layers!(layers)
      return if layers.nil?
      return if layers.is_a?(Array) && layers.all?(String)

      raise SchemaError, "Ключ `layers` должен быть списком строк, получено: #{layers.inspect}"
    end

    def self.validate_amount_ranges!(ranges)
      return if ranges.nil?

      raise SchemaError, 'Ключ `amount_ranges` должен быть списком' unless ranges.is_a?(Array)

      ranges.each_with_index { |range, index| validate_amount_range_entry!(range, index) }
    end

    def self.validate_amount_range_entry!(range, index)
      raise SchemaError, "amount_ranges[#{index}] должен быть отображением" unless range.is_a?(Hash)

      validate_integer!(range, 'from', "amount_ranges[#{index}].from", allow_nil: false)
      validate_integer!(range, 'to', "amount_ranges[#{index}].to", allow_nil: true)
      validate_prefer!(range, index)
    end

    def self.validate_prefer!(range, index)
      prefer = range['prefer']
      return if prefer.is_a?(String) && !prefer.empty?

      raise SchemaError, "amount_ranges[#{index}].prefer обязателен и должен быть строкой"
    end

    def self.validate_obligations!(obligations)
      return if obligations.nil?

      unless obligations.is_a?(Hash)
        raise SchemaError, 'Ключ `obligations` должен быть отображением'
      end

      obligations.each { |provider, rules| validate_obligation_entry!(provider, rules) }
    end

    def self.validate_obligation_entry!(provider, rules)
      raise SchemaError, "obligations.#{provider} должен быть отображением" unless rules.is_a?(Hash)

      validate_obligation_keys!(provider, rules)
      OBLIGATION_KEYS.each do |field|
        next unless rules.key?(field)

        validate_integer!(rules, field, "obligations.#{provider}.#{field}", allow_nil: true)
      end
    end

    def self.validate_obligation_keys!(provider, rules)
      unknown = rules.keys.map(&:to_s) - OBLIGATION_KEYS
      return if unknown.empty?

      raise SchemaError, "obligations.#{provider}: неизвестный ключ #{unknown.join(', ')}; " \
                         "допустимые: #{OBLIGATION_KEYS.join(', ')}"
    end

    def self.validate_rate_limits!(rate_limits)
      return if rate_limits.nil?

      unless rate_limits.is_a?(Hash)
        raise SchemaError, 'Ключ `rate_limits` должен быть отображением'
      end

      rate_limits.each { |provider, limit| validate_rate_limit!(provider, limit) }
    end

    def self.validate_rate_limit!(provider, limit)
      return if limit.is_a?(Integer)

      raise SchemaError, "rate_limits.#{provider} должен быть целым числом, " \
                         "получено: #{limit.inspect}"
    end

    def self.validate_cascade!(cascade)
      return if cascade.nil?

      unless cascade.is_a?(Hash)
        raise SchemaError,
              "Ключ `cascade` должен быть отображением, получено: #{cascade.class}"
      end

      validate_cascade_keys!(cascade)
      CASCADE_KEYS.each { |key| validate_cascade_value!(cascade, key) }
    end

    def self.validate_cascade_keys!(cascade)
      unknown = cascade.keys.map(&:to_s) - CASCADE_KEYS
      return if unknown.empty?

      raise SchemaError, "cascade: неизвестный ключ #{unknown.join(', ')}; " \
                         "допустимые: #{CASCADE_KEYS.join(', ')}"
    end

    def self.validate_cascade_value!(cascade, key)
      return unless cascade.key?(key)

      value = cascade[key]
      allowed = CASCADE_ALLOWED_VALUES.fetch(key)
      return if allowed.include?(value)

      raise SchemaError, "cascade.#{key} должен быть одним из: #{allowed.join(', ')}; " \
                         "получено #{value.inspect}"
    end

    # Значение outcomes.source и парный ему outcomes.script. Сам ключ
    # `outcomes` уже проверен на «это отображение» в SchemaValidator; здесь --
    # только имя источника и обязательность пути для scripted.
    def self.validate_outcomes!(outcomes)
      return if outcomes.nil? || !outcomes.is_a?(Hash)

      validate_outcome_source!(outcomes)
      validate_outcome_script!(outcomes)
    end

    def self.validate_outcome_source!(outcomes)
      return unless outcomes.key?('source')

      source = outcomes['source']
      return if OUTCOME_SOURCES.include?(source)

      raise SchemaError, "outcomes.source должен быть одним из: #{OUTCOME_SOURCES.join(', ')}; " \
                         "получено #{source.inspect}"
    end

    # outcomes.script принимает две формы: сам сценарий отображением
    # (операция -> провайдер -> исход) прямо в конфиге, либо строку — путь к
    # отдельному YAML. Первая форма основная: сценарий — такая же настройка
    # поведения, как стратегия или слои, и живёт там же, где остальная
    # конфигурация.
    #
    # scripted без сценария — не «источник по умолчанию», а ошибка конфига:
    # тихий дефолт скрыл бы опечатку и подсунул детерминированные исходы там,
    # где автор сценария ждёт своих.
    def self.validate_outcome_script!(outcomes)
      script = outcomes['script']

      if outcomes['source'] == 'scripted' && !(script.is_a?(String) || script.is_a?(Hash))
        raise SchemaError, 'outcomes.source: scripted требует outcomes.script — сценарий ' \
                           'исходов отображением или путь к YAML со сценарием'
      end

      return if script.nil? || script.is_a?(String)
      return validate_inline_script!(script) if script.is_a?(Hash)

      raise SchemaError, 'outcomes.script должен быть отображением или строкой, ' \
                         "получено: #{script.class}"
    end

    # Форма встроенного сценария проверяется на загрузке, а не в момент первого
    # промаха по ключу: конфиг с опечаткой в имени исхода обязан падать сразу и
    # с указанием пары, а не на середине прогона очереди.
    def self.validate_inline_script!(script)
      script.each do |operation_id, by_provider|
        unless by_provider.is_a?(Hash)
          raise SchemaError, "outcomes.script.#{operation_id} должен быть отображением " \
                             'провайдер -> исход'
        end

        by_provider.each do |provider, outcome|
          validate_script_outcome!(operation_id, provider, outcome)
        end
      end
    end

    def self.validate_script_outcome!(operation_id, provider, outcome)
      return if SCRIPT_OUTCOMES.include?(outcome.to_s)

      raise SchemaError, "outcomes.script.#{operation_id}.#{provider}: недопустимый исход " \
                         "#{outcome.inspect}; допустимы #{SCRIPT_OUTCOMES.join(', ')}"
    end

    # П4 (docs/plans/P6/P4_сравнение.md): офлайн-сравнение конфигураций.
    # Отсутствующий или пустой ключ `comparison` — законный вход, секции в
    # отчёте нет. Реестры стратегий/слоёв грузятся здесь же (`load_all!`
    # идемпотентен -- spec/routing/strategies_registry_spec.rb), чтобы проверка
    # `Routing::Strategies.known` не зависела от порядка require в остальном
    # прогоне тестов.
    def self.validate_comparison!(comparison, strategy:, layers:)
      return if comparison.nil?
      return validate_comparison_shape!(comparison) unless comparison.is_a?(Array)
      return if comparison.empty?

      names = validate_comparison_entries!(comparison)
      validate_comparison_names_unique!(names)
      validate_comparison_baseline!(comparison, strategy, layers)
    end

    def self.validate_comparison_shape!(comparison)
      raise SchemaError, "Ключ `comparison` должен быть списком, получено: #{comparison.class}"
    end

    def self.validate_comparison_entries!(comparison)
      Routing::Strategies.load_all!
      Routing::Layers.load_all!
      comparison.each_with_index.map { |entry, index| validate_comparison_entry!(entry, index) }
    end

    def self.validate_comparison_entry!(entry, index)
      unless entry.is_a?(Hash)
        raise SchemaError, "comparison[#{index}] должен быть отображением, получено: #{entry.class}"
      end

      name = validate_comparison_name!(entry, index)
      validate_comparison_strategy!(entry, index)
      validate_comparison_layers!(entry, index)
      name
    end

    def self.validate_comparison_name!(entry, index)
      name = entry['name']
      return name if name.is_a?(String) && !name.empty?

      raise SchemaError, "comparison[#{index}].name обязателен и должен быть непустой строкой"
    end

    def self.validate_comparison_strategy!(entry, index)
      strategy = entry['strategy']
      return if strategy.is_a?(String) && Routing::Strategies.known.include?(strategy)

      raise SchemaError, "comparison[#{index}].strategy неизвестна: #{strategy.inspect}; " \
                         "допустимы: #{Routing::Strategies.known.join(', ')}"
    end

    def self.validate_comparison_layers!(entry, index)
      layers = entry.fetch('layers', [])
      unless layers.is_a?(Array) && layers.all?(String)
        raise SchemaError,
              "comparison[#{index}].layers должен быть списком строк, получено: #{layers.inspect}"
      end

      unknown = layers - Routing::Layers.known
      return if unknown.empty?

      raise SchemaError, "comparison[#{index}].layers: неизвестный слой #{unknown.join(', ')}; " \
                         "допустимые: #{Routing::Layers.known.join(', ')}"
    end

    def self.validate_comparison_names_unique!(names)
      duplicates = names.tally.select { |_name, count| count > 1 }.keys
      return if duplicates.empty?

      raise SchemaError, "comparison: повторяющееся имя #{duplicates.join(', ')}"
    end

    # baseline — вариант, буквально совпадающий с боевым strategy/layers
    # (сравнение читается ДО применения override CLI --strategy: тот
    # override — не про comparison, а про боевой пайплайн). Таблица без
    # опоры на фактический прогон бессмысленна (docs/plans/P6/P4, п. "Готово
    # когда" №3), поэтому отсутствие совпадения — ошибка схемы, а не тихий
    # пропуск.
    def self.validate_comparison_baseline!(comparison, strategy, layers)
      match = comparison.any? do |entry|
        entry['strategy'] == strategy && entry.fetch('layers', []) == layers
      end
      return if match

      raise SchemaError, 'comparison: ни один вариант не совпадает с боевыми strategy/layers ' \
                         "(strategy=#{strategy.inspect}, layers=#{layers.inspect})"
    end

    def self.validate_integer!(hash, key, path, allow_nil:)
      value = hash[key]
      return if value.is_a?(Integer)
      return if allow_nil && value.nil?

      expected = allow_nil ? 'целым числом или null' : 'целым числом'
      raise SchemaError, "#{path} должен быть #{expected}, получено: #{value.inspect}"
    end

    private_class_method :validate_amount_range_entry!, :validate_prefer!,
                         :validate_obligation_entry!, :validate_obligation_keys!,
                         :validate_rate_limit!, :validate_integer!,
                         :validate_cascade_keys!, :validate_cascade_value!,
                         :validate_comparison_shape!, :validate_comparison_entries!,
                         :validate_comparison_entry!, :validate_comparison_name!,
                         :validate_comparison_strategy!, :validate_comparison_layers!,
                         :validate_comparison_names_unique!, :validate_comparison_baseline!
  end
end
