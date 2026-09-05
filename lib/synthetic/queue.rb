# frozen_string_literal: true

require_relative 'banks'
require_relative 'provider_set'

module Synthetic
  # Стримит операции одну за другой и параллельно наполняет Expectation —
  # вторым проходом её не пересчитывают.
  #
  # Порядок в потоке: сперва все якоря, затем шум. Порядок между провайдерами
  # неважен по построению (см. provider_set.rb): дневной бюджет exclusive-
  # провайдера трогают только его собственные якоря, поэтому "все якоря
  # провайдера i подряд, затем следующий провайдер" не может испортить чужую
  # арифметику — реалистичного вперемешку размещения ради него не нужно.
  #
  #   single (exclusive)         -> exact: сам провайдер, only_eligible_provider
  #   daily_limit_reject         -> exact: fallback (бюджет исчерпан ровно его же
  #                                  single-суммами — единственный runtime-стейтфул
  #                                  hard-constraint, DailyLimit, отрабатывает
  #                                  предсказуемо)
  #   amount_reject (любой kind) -> exact: fallback (сумма выше limit_amount_max)
  #   probe (poisoned)           -> exact: fallback (свой же маркер, но провайдер
  #                                  навсегда отсеян одним из статичных constraints)
  #   fallback-якорь             -> exact: fallback (bank_orphan, его нет ни у кого)
  #   шум                        -> НЕ exact: банк из общего пула достаётся
  #                                  garantированно допустимому "основному"
  #                                  wide-провайдеру, но конкурентов может быть
  #                                  больше одного — итог решает стратегия.
  # rubocop:disable-next Metrics/ClassLength -- один связный стример очереди, дробить на файлы вредит обзору.
  class Queue
    FALLBACK_REASON = 'fallback_no_eligible_provider'
    SINGLE_REASON = 'only_eligible_provider'

    def self.each(provider_set:, level:, profile:, seed:, expectation:, &)
      new(provider_set, level, profile, seed, expectation).each(&)
    end

    # rubocop:disable-next Metrics/MethodLength -- инициализация счётчиков одного прохода, все поля независимы.
    def initialize(provider_set, level, profile, seed, expectation)
      @ps = provider_set
      @level = level
      @profile = profile
      @seed = seed
      @expectation = expectation
      @base_time = Time.new(2026, 7, 30, 9, 0, 0, '+03:00')
      @digits = [level.operations.to_s.length, 6].max
      @index = 0
      @valid_total = 0
      @noise_targeted = 0
      @last_valid_id = nil
    end

    def each
      specs = anchor_specs
      specs.each { |spec| yield emit(spec) }
      noise_total = [@level.operations - specs.size, 0].max
      noise_total.times { |i| yield emit(noise_spec(i)) }
      finalize_expectation
      self
    end

    private

    # rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize -- линейный список видов якорей, дробить некуда без потери обзора.
    def anchor_specs
      specs = []
      @ps.exclusive.each do |d|
        d.single_amounts.each do |amount|
          specs << { bank: d.marker, amount: amount, exact_provider: d.name,
                     exact_reason: SINGLE_REASON }
        end
        specs << reject_spec(d.marker, d.daily_limit_reject_amount)
        specs << reject_spec(d.marker, d.amount_reject_amount)
      end
      @ps.wide.each { |d| specs << reject_spec(d.marker, d.amount_reject_amount) }
      @ps.poisoned.each { |d| specs << reject_spec(d.marker, d.probe_amount) }
      @ps.fallback_anchor_count.times { |i| specs << reject_spec(Banks::ORPHAN, fallback_amount(i)) }
      specs
    end

    def reject_spec(bank, amount)
      { bank: bank, amount: amount, exact_provider: @ps.fallback_name,
        exact_reason: FALLBACK_REASON }
    end

    def fallback_amount(seat)
      @level.amount_min + (seat % [@level.amount_max - @level.amount_min, 1].max)
    end

    def noise_spec(index)
      return { bank: Banks::ORPHAN, amount: noise_amount(index), noise: true, targeted: false } if
        @ps.wide.empty? || orphan_noise?(index)

      targeted_noise_spec(index)
    end

    # rubocop:disable-next Metrics/AbcSize -- один расчёт "банк+сумма гарантированно допустимы для основного кандидата".
    def targeted_noise_spec(index)
      descriptor = weighted_wide[index % weighted_wide.size]
      bank = descriptor.banks_pool[index % descriptor.banks_pool.size]
      span = descriptor.limit_max - descriptor.limit_min + 1
      amount = descriptor.limit_min + (ProviderSet.hash_int(@seed, 'noise_amt', index) % span)
      { bank: bank, amount: amount, noise: true, targeted: true }
    end

    # Список с повторами по traffic_percentage — недорогой (O(wide)) способ
    # смещать шум к более "жирным" wide-провайдерам без честного O(N)
    # взвешенного розыгрыша на каждой операции.
    def weighted_wide
      @weighted_wide ||= @ps.wide.flat_map do |d|
        repeats = [(ProviderSet.traffic_for(d, @seed) / 5.0).round, 1].max
        Array.new(repeats, d)
      end
    end

    def orphan_noise?(index)
      (ProviderSet.hash_int(@seed, 'orphan_pick', index) % 100) < @profile.orphan_noise_pct
    end

    def noise_amount(index)
      span = @level.amount_max - @level.amount_min + 1
      @level.amount_min + (ProviderSet.hash_int(@seed, 'orphan_amt', index) % span)
    end

    def emit(spec)
      operation_id, created_at = advance!
      hash = build_hash(operation_id, created_at, spec[:bank], spec[:amount])
      return finish_exact(hash, operation_id, spec) if spec[:exact_provider]

      finish_noise(hash, operation_id, spec)
    end

    def finish_exact(hash, operation_id, spec)
      @expectation.add_exact(operation_id, provider: spec[:exact_provider],
                                           reason: spec[:exact_reason])
      @expectation.increment('spacepayments_used') if spec[:exact_provider] == @ps.fallback_name
      @valid_total += 1
      @last_valid_id = operation_id
      hash
    end

    # rubocop:disable-next Metrics/MethodLength -- проверка порчи и подсчёт fallback-vs-targeted в одном месте.
    def finish_noise(hash, operation_id, spec)
      if corrupt?(operation_id)
        @expectation.increment('queue_errors')
        return corrupt(hash, operation_id)
      end

      @valid_total += 1
      @last_valid_id = operation_id
      # Шум с bank_orphan (профильная доля orphan_noise_pct, или весь шум,
      # если wide-провайдеров нет) гарантированно уходит в fallback — этого
      # никто не выбирает, банк ни у кого не значится, — но это НЕ якорь,
      # отдельной записи в exact ради него не заводим, только счётчик.
      if spec[:targeted]
        @noise_targeted += 1
      else
        @expectation.increment('spacepayments_used')
      end
      hash
    end

    def advance!
      n = @index
      @index += 1
      id = format("op_%0#{@digits}d", n + 1)
      created_at = (@base_time + (n * 30)).strftime('%Y-%m-%dT%H:%M:%S%:z')
      [id, created_at]
    end

    def build_hash(operation_id, created_at, bank, amount)
      {
        'operation_id' => operation_id, 'created_at' => created_at, 'amount' => amount,
        'bank' => bank, 'card_brand' => nil,
        'payout_requisite' => {
          'sbp' => { 'phone' => phone_for(operation_id), 'bank_name' => bank }
        }
      }
    end

    def phone_for(operation_id) = "79#{operation_id.gsub(/\D/, '').rjust(9, '0')[-9..]}"

    # broken_ratio — надстройка "битых" записей поверх шума (никогда поверх
    # якорей: иначе точный оракул перестал бы быть точным). Три вида порчи
    # ротируются по хешу id, а не по случайности — чтобы make gen дважды с
    # одним seed дал побайтово одинаковый файл.
    def corrupt?(operation_id)
      return false if @level.broken_ratio.zero?

      threshold = (@level.broken_ratio * 1_000_000).round
      (ProviderSet.hash_int(@seed, 'broken_pick', operation_id) % 1_000_000) < threshold
    end

    # Дубль operation_id ловит только Io::QueueLoader (у него есть @seen_ids).
    # Io::QueueStreamLoader (:jsonl-уровни — l/xl/insane) намеренно без
    # дедупликации: хеш на все N id при 20 млн строк — это сотни мегабайт
    # ради проверки, которую генератор и так не нарушает по построению. Раз
    # там некому поймать дубль, туда его и не кладём — иначе "битая" запись
    # молча дублировала бы решение вместо того, чтобы стать ошибкой.
    def corrupt(hash, operation_id)
      kinds = @level.mode == :jsonl ? 2 : 3
      case ProviderSet.hash_int(@seed, 'broken_kind', operation_id) % kinds
      when 0 then hash.except('amount')
      when 1 then hash.merge('amount' => -1)
      else hash.merge('operation_id' => @last_valid_id || operation_id)
      end
    end

    def finalize_expectation
      @expectation.record_tolerance('hard_constraint_violations', [0, 0])
      @expectation.record_distribution_tolerance(distribution_tolerance)
      @expectation.record_tolerance('delivered', delivered_tolerance)
      @expectation.increment_by('valid_operations', @valid_total)
    end

    # rubocop:disable-next Metrics/AbcSize -- один расчёт коридора на группу wide-провайдеров.
    def distribution_tolerance
      total_traffic = @ps.wide.sum { |d| ProviderSet.traffic_for(d, @seed) }
      denominator = [@valid_total, 1].max
      @ps.wide.to_h do |d|
        share = total_traffic.zero? ? 0.0 : share_pct(d, total_traffic, denominator)
        band = @profile.distribution_band_pp
        [d.name, [[share - band, 0.0].max.round(2), [share + band, 100.0].min.round(2)]]
      end
    end

    def share_pct(descriptor, total_traffic, denominator)
      weight = ProviderSet.traffic_for(descriptor, @seed).to_f / total_traffic
      weight * @noise_targeted / denominator * 100
    end

    # Пер-попытка вероятность rejected у Execution::OutcomeSource::Deterministic
    # фиксирована (reject_share = 500 бп = 5%, deterministic.rb:26) независимо
    # от conversion_24h — так что P(delivered) снизу ограничена 0.95 почти
    # везде (каскад из нескольких кандидатов только повышает её). Половина
    # ширины коридора — эвристика по 1/√N, чтобы не мигать на маленьких N и не
    # быть неоправданно широкой на миллионах.
    def delivered_tolerance
      total = @valid_total
      half_width = [0.02, 6.0 / Math.sqrt([total, 1].max)].max
      low = [((0.95 - half_width) * total).floor, 0].max
      [low, total]
    end
  end
end
