# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'generator'

module Synthetic
  # Пишет три файла уровня на диск. Очередь всегда стримится построчно —
  # даже для :array-режима (JSON-массив по-прежнему валиден: перевод строки
  # внутри массива JSON не запрещён) — чтобы Queue#each ни для одного уровня
  # не заставлял писателя держать операции целиком в памяти. providers.json и
  # expectation.json малы (O(providers)) и пишутся обычным JSON.pretty_generate.
  module Writer
    PROVIDERS_FILENAME = 'providers.json'
    EXPECTATION_FILENAME = 'expectation.json'

    module_function

    def queue_filename(level) = level.mode == :jsonl ? 'queue.jsonl' : 'queue.json'

    def write(level_name:, seed:, out_dir:)
      bundle = Generator.prepare(level_name: level_name, seed: seed)
      FileUtils.mkdir_p(out_dir)

      queue_path = File.join(out_dir, queue_filename(bundle.level))
      write_queue(queue_path, bundle)
      providers_path = write_providers(out_dir, bundle)
      expectation_path = write_expectation(out_dir, bundle)

      { providers_path: providers_path, queue_path: queue_path,
        expectation_path: expectation_path, bundle: bundle }
    end

    def write_queue(path, bundle)
      File.open(path, 'w') do |file|
        write_queue_body(file, bundle)
      end
    end

    def write_queue_body(file, bundle)
      array_mode = bundle.level.mode != :jsonl
      file.write("[\n") if array_mode
      first = true
      Generator.each_operation(bundle) do |operation|
        file.write(",\n") if array_mode && !first
        file.write(JSON.generate(operation))
        file.write("\n") unless array_mode
        first = false
      end
      file.write("\n]\n") if array_mode
    end
    private_class_method :write_queue_body

    def write_providers(out_dir, bundle)
      path = File.join(out_dir, PROVIDERS_FILENAME)
      payload = {
        'snapshot_at' => '2026-07-30T09:00:00+03:00', 'gateway' => 'RUB_SBP_WITHDRAW',
        'merchant' => "synthetic_#{bundle.level.name}",
        'providers' => bundle.provider_set.raw_providers
      }
      File.write(path, "#{JSON.pretty_generate(payload)}\n")
      path
    end
    private_class_method :write_providers

    # Раз queue пишется отдельно и первой, expectation.to_h корректен только
    # сейчас: коридоры (distribution_pp/delivered) Queue#each досчитывает в
    # самом конце прохода (queue.rb#finalize_expectation).
    def write_expectation(out_dir, bundle)
      path = File.join(out_dir, EXPECTATION_FILENAME)
      File.write(path, "#{JSON.pretty_generate(bundle.expectation.to_h)}\n")
      path
    end
    private_class_method :write_expectation
  end
end
