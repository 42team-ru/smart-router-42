# frozen_string_literal: true

require 'digest'
require_relative 'banks'
require_relative 'profiles'

module Synthetic
  # Строит P провайдеров + обязательный spacepayments для уровня/профиля/seed.
  #
  # Разбивает здоровых провайдеров на две роли, и это единственная причина,
  # по которой конструктивный оракул вообще может быть дешёвым (O(providers),
  # а не O(operations · providers)):
  #
  #   exclusive — banks состоит РОВНО из одного маркерного банка. Ни одна
  #     операция с этим банком не может достаться никому другому (BankFilter),
  #     а раз шум (см. queue.rb) никогда не пользуется маркерными банками,
  #     дневной бюджет exclusive-провайдера трогают только его собственные
  #     якоря — daily_amount_limit можно выставить точной суммой заранее,
  #     не дожидаясь остальной очереди.
  #   wide — маркер плюс часть общего пула банков: настоящий конкурент за
  #     шумовые операции, его итоговая доля предсказуема только коридором.
  #
  # poisoned — здоровый по кворуму, но навсегда отсеянный ровно одним
  # hard-constraint (см. Profiles::POISON_TYPES); в якорях не участвует.
  #
  # Никакого Random: все "случайные" на вид числа — SHA256 от (seed, роль,
  # индекс/имя). То же соглашение, что у Execution::OutcomeSource::Deterministic
  # — генератор живёт вне lib/routing и lib/execution, но лишний источник
  # недетерминизма никому не нужен и здесь.
  # rubocop:disable-next Metrics/ModuleLength -- одна связная фабрика провайдеров, дробить на файлы вредит обзору.
  module ProviderSet
    FALLBACK_NAME = 'spacepayments'
    GENEROUS_REQUISITES = 1_000_000

    Descriptor = Data.define(:name, :kind, :marker, :limit_min, :limit_max,
                             :single_amounts, :daily_limit_reject_amount,
                             :amount_reject_amount, :probe_amount, :poison_type, :banks_pool)

    Result = Data.define(:raw_providers, :exclusive, :wide, :poisoned, :fallback_name,
                         :anchors_per_exclusive, :fallback_anchor_count)

    module_function

    # rubocop:disable-next Metrics/AbcSize -- сборка результата из уже готовых групп, дальше дробить некуда.
    def build(level:, profile:, seed:)
      roles = assign_roles(level.providers, profile, seed)
      anchor_count = anchors_per_exclusive(level.operations, roles[:exclusive].size)
      groups = build_groups(roles, level, profile, anchor_count)

      Result.new(
        raw_providers: groups.values.flatten.map { |d| raw_provider(d, seed) } + [fallback_raw],
        exclusive: groups[:exclusive], wide: groups[:wide], poisoned: groups[:poisoned],
        fallback_name: FALLBACK_NAME, anchors_per_exclusive: anchor_count,
        fallback_anchor_count: fallback_anchor_count(level.operations)
      )
    end

    def build_groups(roles, level, profile, anchor_count)
      {
        exclusive: roles[:exclusive].map do |i|
          exclusive_descriptor(i, level, anchor_count, profile.amount_span_divisor)
        end,
        wide: roles[:wide].map do |i|
          wide_descriptor(i, level, pool_size(profile), profile.amount_span_divisor)
        end,
        poisoned: roles[:poisoned].map { |i| poisoned_descriptor(i, level) }
      }
    end

    def hash_int(seed, *parts) = Digest::SHA256.hexdigest("#{seed}:#{parts.join(':')}").to_i(16)

    def pool_size(profile)
      %w[narrow_banks pathological].include?(profile.name) ? 2 : Banks::COMMON.size
    end

    # Роли распределяются рангом хеша, а не первыми/последними по индексу —
    # иначе "первые N по порядку" всегда были бы одной ролью, и естественный
    # порядок имён (p001, p002...) совпал бы с порядком ролей, что мешало бы
    # спекам различить два независимых свойства (имя vs роль).
    def assign_roles(providers, profile, seed)
      ranked = (0...providers).sort_by { |i| hash_int(seed, 'role', i) }
      poisoned_count = (providers * profile.poisoned_pct / 100.0).round
      poisoned = ranked.first(poisoned_count)
      healthy = ranked[poisoned_count..] || []
      exclusive_count = exclusive_count_for(healthy.size, profile.exclusive_pct)
      { exclusive: healthy.first(exclusive_count), wide: healthy[exclusive_count..] || [],
        poisoned: poisoned }
    end

    def exclusive_count_for(healthy_size, exclusive_pct)
      return healthy_size if healthy_size <= 1

      (healthy_size * exclusive_pct / 100.0).round.clamp(1, healthy_size - 1)
    end

    def anchors_per_exclusive(operations, exclusive_count)
      denominator = [exclusive_count, 1].max * 30
      (operations / denominator).clamp(1, 200)
    end

    def fallback_anchor_count(operations) = (operations / 50).clamp(5, 5_000)

    # Провайдер i получает окно [min_i, max_i] шириной в половину диапазона
    # уровня, сдвинутое по индексу — окна разных провайдеров пересекаются
    # (это нужно шуму: несколько wide-провайдеров одновременно допустимы по
    # сумме), но каждое остаётся внутри [amount_min, amount_max] уровня.
    # rubocop:disable-next Metrics/AbcSize -- линейная арифметика окна, дробить только на явно поименованные шаги.
    def amount_window(index, level, divisor = Profiles::DEFAULT_AMOUNT_SPAN_DIVISOR)
      span = level.amount_max - level.amount_min
      provider_span = [span / divisor, 1].max
      denom = [level.providers - 1, 1].max
      offset = ((span - provider_span) * index) / denom
      min = level.amount_min + offset
      max = [min + provider_span, level.amount_max].min
      max = min + 1 if max <= min
      [min, max]
    end

    def name_for(index) = format('p%03d', index + 1)

    def exclusive_descriptor(index, level, anchor_count,
                             divisor = Profiles::DEFAULT_AMOUNT_SPAN_DIVISOR)
      min, max = amount_window(index, level, divisor)
      denominator = [anchor_count, 1].max
      amounts = Array.new(anchor_count) { |seat| min + ((seat * (max - min)) / denominator) }
      Descriptor.new(
        name: name_for(index), kind: :exclusive, marker: Banks.marker(index),
        limit_min: min, limit_max: max, single_amounts: amounts,
        daily_limit_reject_amount: min, amount_reject_amount: max + 1,
        probe_amount: nil, poison_type: nil, banks_pool: nil
      )
    end

    def wide_descriptor(index, level, pool_size,
                        divisor = Profiles::DEFAULT_AMOUNT_SPAN_DIVISOR)
      min, max = amount_window(index, level, divisor)
      Descriptor.new(
        name: name_for(index), kind: :wide, marker: Banks.marker(index), limit_min: min,
        limit_max: max, single_amounts: [], daily_limit_reject_amount: nil,
        amount_reject_amount: max + 1, probe_amount: nil, poison_type: nil,
        banks_pool: Banks.pool_for(index, pool_size)
      )
    end

    def poisoned_descriptor(index, level)
      min, max = amount_window(index, level)
      type = Profiles::POISON_TYPES[index % Profiles::POISON_TYPES.size]
      Descriptor.new(
        name: name_for(index), kind: :poisoned, marker: Banks.marker(index), limit_min: min,
        limit_max: max, single_amounts: [], daily_limit_reject_amount: nil,
        amount_reject_amount: nil, probe_amount: min, poison_type: type, banks_pool: nil
      )
    end

    # rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize -- один плоский снимок JSON, как ProvidersLoader::FIELDS.
    def raw_provider(descriptor, seed)
      {
        'payment_system' => descriptor.name, 'status' => status_for(descriptor),
        'traffic_percentage' => traffic_for(descriptor, seed),
        'priority' => hash_int(seed, 'priority', descriptor.name) % 1000,
        'limit_amount_min' => descriptor.limit_min, 'limit_amount_max' => descriptor.limit_max,
        'daily_amount_limit' => daily_limit_for(descriptor),
        'daily_approved_amount' => 0,
        'in_progress_count_limit' => in_progress_limit_for(descriptor),
        'in_progress_count' => in_progress_count_for(descriptor),
        'in_progress_amount_limit' => nil, 'in_progress_amount' => 0,
        'available_requisites' => requisites_for(descriptor),
        'conversion_24h' => conversion_for(descriptor, seed),
        'avg_latency_sec' => 10 + (hash_int(seed, 'latency', descriptor.name) % 50),
        'banks' => banks_for(descriptor),
        'exclude_banks' => descriptor.poison_type == :excluded_banks,
        'provider_margin_pct' => margin_for(descriptor, seed),
        'merchant_margin_pct' => 1.5, 'allow_negative_agreement' => false
      }
    end

    def status_for(descriptor) = descriptor.poison_type == :inactive ? 'inactive' : 'active'

    def traffic_for(descriptor, seed)
      return 0 if descriptor.poison_type == :zero_traffic

      5 + (hash_int(seed, 'traffic', descriptor.name) % 60)
    end

    def daily_limit_for(descriptor)
      descriptor.kind == :exclusive ? descriptor.single_amounts.sum : nil
    end

    def in_progress_limit_for(descriptor) = descriptor.poison_type == :in_progress_cap ? 5 : nil
    def in_progress_count_for(descriptor) = descriptor.poison_type == :in_progress_cap ? 5 : 0

    def requisites_for(descriptor)
      descriptor.poison_type == :no_requisites ? 0 : GENEROUS_REQUISITES
    end

    # exclusive — всегда 1.0, и это не "реализм", а необходимость: Execution::
    # OutcomeSource::Deterministic закрывает daily_approved_amount только на
    # :approved (rollback/hold его не трогают, deterministic.rb:26-40), а
    # daily_limit_reject-якорь (queue.rb) держится на том, что бюджет
    # exclusive-провайдера заполнен РОВНО суммой его single-якорей к моменту,
    # когда reject-операция до него доходит. При conversion < 1.0 часть
    # single-попыток стала бы :rejected/:expired, бюджет остался бы
    # недозаполненным, и reject-якорь мог бы не сработать — конструктивный
    # оракул был бы неточным на статистике, а не по построению.
    def conversion_for(descriptor, seed)
      return 1.0 if descriptor.kind == :exclusive

      (0.60 + ((hash_int(seed, 'conv', descriptor.name) % 30) / 100.0)).round(2)
    end

    def banks_for(descriptor)
      return [descriptor.marker, *descriptor.banks_pool] if descriptor.kind == :wide

      [descriptor.marker]
    end

    def margin_for(descriptor, seed)
      return 2.0 if descriptor.poison_type == :negative_margin

      (0.5 + ((hash_int(seed, 'margin', descriptor.name) % 5) / 10.0)).round(2)
    end

    # rubocop:disable-next Metrics/MethodLength -- статический снимок fallback-провайдера, как в reference/data/providers.json.
    def fallback_raw
      {
        'payment_system' => FALLBACK_NAME, 'status' => 'active', 'traffic_percentage' => 0,
        'priority' => 9_999, 'limit_amount_min' => nil, 'limit_amount_max' => nil,
        'daily_amount_limit' => nil, 'daily_approved_amount' => 0,
        'in_progress_count_limit' => nil, 'in_progress_count' => 0,
        'in_progress_amount_limit' => nil, 'in_progress_amount' => 0,
        'available_requisites' => GENEROUS_REQUISITES, 'conversion_24h' => 0.95,
        'avg_latency_sec' => 15, 'banks' => [], 'exclude_banks' => false,
        'provider_margin_pct' => 0.5, 'merchant_margin_pct' => 1.5,
        'allow_negative_agreement' => false
      }
    end
  end
end
