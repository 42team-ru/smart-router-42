# frozen_string_literal: true

module Io
  # Итог калибровки operations_history.csv: три исхода (approved/rejected/
  # expired) в базисных пунктах на провайдера, посчитанных Io::HistoryLoader.
  #
  # Раньше HistoryLoader.load отдавал голый Hash{имя => Float approved}.
  # Теперь исходов три, оценка сглажена (см. HistoryLoader), и голого Hash
  # недостаточно — нужно ещё число наблюдений и применённое k, чтобы отчёт и
  # explain могли объяснить, откуда взялась цифра. Отсюда отдельный класс, а
  # не Hash с более длинными значениями.
  #
  # Класс НАМЕРЕННО не отвечает на #[] / #each / #to_h "как Hash" -- старый
  # код, который ждал Hash{имя => Float}, обязан упасть NoMethodError на
  # первом же вызове, а не тихо получить объект, ведущий себя почти как
  # ожидалось. Кому нужен старый Hash-контракт явно и осознанно (мосты к
  # ещё не переведённым потребителям) -- берёт #to_conversion_hash.
  class HistoryStats
    # Одна строка на провайдера: сколько наблюдений видели и что из них вышло
    # (уже в базисных пунктах, возможно сглаженных).
    Entry = Struct.new(
      :n, :approved_count, :rejected_count, :expired_count,
      :approved_bp, :rejected_bp, :expired_bp,
      keyword_init: true
    )

    # Провайдера нет в CSV вовсе — ни одной строки. Сгладить тут нечего: mu и k
    # посчитаны по ДРУГИМ провайдерам и не имеют отношения к этому имени (а если
    # история пуста целиком, mu тоже взять неоткуда). Единственный честный выбор
    # — явная константа, а не подобранное на глаз число: провайдер без всякой
    # истории считается никогда не одобряющим, с тем же запасным 5% на rejected,
    # что раньше было жёстко зашитым Deterministic#reject_share. Это НЕ статистика
    # (в отличие от approved_bp известных провайдеров) — это осознанный
    # консервативный дефолт на случай отсутствия данных.
    DEFAULT_APPROVED_BP = 0
    DEFAULT_REJECTED_BP = 500
    DEFAULT_EXPIRED_BP = 10_000 - DEFAULT_APPROVED_BP - DEFAULT_REJECTED_BP
    DEFAULT_ENTRY = Entry.new(
      n: 0, approved_count: 0, rejected_count: 0, expired_count: 0,
      approved_bp: DEFAULT_APPROVED_BP, rejected_bp: DEFAULT_REJECTED_BP,
      expired_bp: DEFAULT_EXPIRED_BP
    ).freeze

    attr_reader :k, :rows, :diagnostics

    # k — эффективный размер приора; smoothed отмечает применённое сглаживание.
    # rubocop:disable-next Naming/MethodParameterName, Metrics/ParameterLists -- k — термин модели.
    def initialize(entries:, k:, smoothed:, rows: [], diagnostics: {}, bank_entries: {})
      @entries = entries
      @k = k
      @smoothed = smoothed
      @rows = rows
      @diagnostics = diagnostics
      @bank_entries = bank_entries
    end

    def smoothed? = @smoothed

    def providers = @entries.keys

    def known?(name) = @entries.key?(name)

    def observations(name) = entry(name).n

    def approved_count(name) = entry(name).approved_count

    def rejected_count(name) = entry(name).rejected_count

    def expired_count(name) = entry(name).expired_count

    def approved_bp(name) = entry(name).approved_bp

    # Второй уровень: банк тянется к уже калиброванному провайдеру, а не к
    # глобальной средней. Неизвестная пара честно возвращает provider-level.
    def approved_bp_for(name, bank)
      @bank_entries.fetch([name, bank], entry(name)).approved_bp
    end

    def observations_for(name, bank) = @bank_entries.fetch([name, bank], Entry.new(n: 0)).n

    def rejected_bp(name) = entry(name).rejected_bp

    def expired_bp(name) = entry(name).expired_bp

    # Мост к устаревшему контракту Io::HistoryLoader.load (Hash{имя => Float
    # approved 0..1, округлено до 3 знаков — так же, как было раньше}).
    # Нужен только там, где потребитель ещё не переведён на HistoryStats явно
    # (Reporting::ReportBuilder/Recommendations — отдельный пакет, см. бриф).
    # Это не duck typing: вызывающая сторона явно решает переключиться на
    # старый формат этим методом, а не получает его случайно через #[].
    def to_conversion_hash
      @entries.transform_values { |entry| (entry.approved_bp.to_f / 10_000).round(3) }
    end

    # Та же доля approved, что и в to_conversion_hash, но для одного
    # провайдера -- нужна там, где остальной объект (n, k, smoothed?) тоже
    # идёт в дело (Reporting::Recommendations), и заводить целый Hash ради
    # одного значения незачем.
    def approved_ratio(name) = (approved_bp(name).to_f / 10_000).round(3)

    # Таблица для Execution::OutcomeSource::Deterministic: только approved_bp и
    # rejected_bp на провайдера — expired там всегда подразумеваемый остаток
    # ("иначе"), отдельно его туда передавать незачем.
    def to_outcome_table
      @entries.transform_values do |entry|
        { approved_bp: entry.approved_bp, rejected_bp: entry.rejected_bp }
      end
    end

    private

    def entry(name) = @entries.fetch(name, DEFAULT_ENTRY)
  end
end
