#!/usr/bin/env ruby
# frozen_string_literal: true

# Собирает docs/openapi.yaml в JS-файл, который Swagger UI подхватывает через
# window.OPENAPI_SPEC. Нужно, потому что file:// не может XHR-ить соседний YAML
# в Chrome/Chromium (CORS). При http://<host>/ Sinatra отдаёт /openapi.yaml
# нормально, и этот файл там не нужен — но безобиден.

require 'yaml'
require 'json'
require 'fileutils'

repo    = File.expand_path('..', __dir__)
in_path = File.join(repo, 'docs', 'openapi.yaml')
out_dir = File.join(repo, 'public', 'swagger')
out     = File.join(out_dir, 'openapi-spec.js')

raise "not found: #{in_path}" unless File.exist?(in_path)

FileUtils.mkdir_p(out_dir)

spec = YAML.load_file(in_path)
body = "window.OPENAPI_SPEC = #{JSON.pretty_generate(spec)};\n"
File.write(out, body)

puts "wrote #{out.sub("#{repo}/", '')} (#{File.size(out)} bytes)"
