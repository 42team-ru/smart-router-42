# frozen_string_literal: true

require 'tmpdir'
require 'config/loader'

RSpec.describe Config::Loader do
  describe 'ключ history_path' do
    def load_config(body)
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, 'routing.yml')
        File.write(path, "strategy: count_share\nfallback_provider: spacepayments\n#{body}")
        described_class.load(path)
      end
    end

    it 'по умолчанию указывает на снапшот истории организаторов' do
      expect(load_config('').history_path).to eq('reference/data/operations_history.csv')
    end

    it 'перекрывается значением из конфига' do
      config = load_config("history_path: data/my_history.csv\n")

      expect(config.history_path).to eq('data/my_history.csv')
    end

    it 'боевой конфиг грузится и даёт путь к существующему файлу' do
      config = described_class.load('config/routing.yml')

      expect(File.exist?(config.history_path)).to be(true)
    end
  end
end
