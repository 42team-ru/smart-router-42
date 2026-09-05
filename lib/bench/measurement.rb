# frozen_string_literal: true

module Bench
  # Замеры для печати, не для решений: throughput, пиковая память, давление GC.
  # Живёт вне lib/routing/lib/execution — Process.clock_gettime тут не о
  # текущем времени операции (это был бы Time.now), а о том, сколько занял сам
  # бенчмарк.
  module Measurement
    Snapshot = Data.define(:elapsed, :peak_rss_kb, :gc_stat)

    module_function

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # /proc/self/status есть только под Linux (WSL в том числе) — под другой ОС
    # честно возвращаем nil, а не выдумываем вторую метрику памяти.
    def peak_rss_kb
      status = File.read('/proc/self/status')
      status[/VmHWM:\s+(\d+)/, 1]&.to_i
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def snapshot(started_at, gc_before)
      Snapshot.new(elapsed: now - started_at, peak_rss_kb: peak_rss_kb,
                   gc_stat: gc_delta(gc_before))
    end

    def gc_delta(before)
      after = GC.stat
      { minor_gc_count: after[:minor_gc_count] - before[:minor_gc_count],
        major_gc_count: after[:major_gc_count] - before[:major_gc_count],
        heap_live_slots: after[:heap_live_slots] }
    end

    def format_snapshot(snapshot, operations)
      [time_line(snapshot, operations), rss_line(snapshot), gc_line(snapshot)].compact
    end

    def rate(snapshot, operations) = operations.zero? ? 0 : (operations / snapshot.elapsed).round

    def time_line(snapshot, operations)
      "время: #{snapshot.elapsed.round(2)} с (#{rate(snapshot, operations)} оп/с)"
    end

    def rss_line(snapshot)
      return nil unless snapshot.peak_rss_kb

      "пиковый RSS: #{(snapshot.peak_rss_kb / 1024.0).round(1)} МБ"
    end

    def gc_line(snapshot)
      "GC: minor=#{snapshot.gc_stat[:minor_gc_count]} " \
        "major=#{snapshot.gc_stat[:major_gc_count]} " \
        "live_slots=#{snapshot.gc_stat[:heap_live_slots]}"
    end
  end
end
