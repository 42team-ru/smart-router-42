# frozen_string_literal: true

require 'json'
require 'rack/test'
require 'yaml'
require 'config/loader'
require 'config/service_config'
require 'api/app'
require 'api/gateway'
require 'api/decisions_repo'

# rubocop:disable RSpec/DescribeClass -- спек про HTTP-контракт, а не про класс.
RSpec.describe 'HTTP-слой' do
  # rubocop:enable RSpec/DescribeClass
  include Rack::Test::Methods

  # Приложение собирается из настоящих config/, docs/ и dashboard/: спек ловит
  # и рассинхрон lib/ с reference/, и отвалившийся require.
  let(:app) do
    repo = Api::DecisionsRepo.new(path: ':memory:', retention_seconds: 86_400)
    Api::App.configure_with(
      gateway: Api::Gateway.new(
        service_config: service_config, routing_config: routing_config, repo: repo
      ),
      service_config: service_config
    )
    Api::App
  end

  def service_config
    Config::ServiceConfigLoader.build(
      'port' => 4567,
      'db_path' => ':memory:',
      'retention_hours' => 24,
      'swagger_path' => './public/swagger',
      'openapi_path' => './docs/openapi.yaml',
      'history_path' => './reference/data/operations_history.csv',
      'dashboard_path' => './dashboard'
    )
  end

  def routing_config = Config::Loader.load('./config/routing.yml')
  def snapshot = JSON.parse(File.read(reference_path('providers.json')))
  def config_payload = YAML.safe_load_file('./config/routing.yml', aliases: false)

  # Sinatra 4 включает host_authorization и в development пускает только
  # localhost; дефолтный для rack-test example.org получил бы 403 «Host not
  # permitted» вместо ответа приложения.
  before { header 'Host', 'localhost' }

  def body = JSON.parse(last_response.body)

  # created_at из очереди организаторов старше retention, и решения удалялись
  # бы сразу после вставки — сдвигаем очередь в текущее окно.
  def bootstrap!
    post '/bootstrap', JSON.generate('snapshot' => snapshot, 'config' => config_payload),
         'CONTENT_TYPE' => 'application/json'
    now = Time.now
    JSON.parse(File.read(reference_path('operations_queue_10.json'))).each_with_index do |op, i|
      op['created_at'] = (now - (3000 - (i * 300))).strftime('%Y-%m-%dT%H:%M:%S%:z')
      post '/operations', JSON.generate('operation' => op), 'CONTENT_TYPE' => 'application/json'
    end
  end

  describe 'GET /capabilities' do
    it 'перечисляет стратегии из реестра, а не из захардкоженного списка' do
      get '/capabilities'

      expect(body['strategies']).to eq(Routing::Strategies.known)
    end

    it 'отдаёт слои и retention даже без загруженного снапшота' do
      get '/capabilities'

      expect(body).to include('layers' => Routing::Layers.known, 'retention_hours' => 24)
    end
  end

  describe 'GET /analytics/overview' do
    it 'отвечает 409 no_snapshot, пока снапшот не загружен' do
      get '/analytics/overview'

      expect([last_response.status, body['error']]).to eq([409, 'no_snapshot'])
    end

    it 'считает исходы по всем решениям выборки' do
      bootstrap!
      get '/analytics/overview'

      expect(body['outcomes']).to eq(
        'approved' => 10, 'rejected' => 0, 'expired' => 0, 'no_provider' => 0
      )
    end

    it 'строит воронку каскада от первой попытки к последней' do
      bootstrap!
      get '/analytics/overview'

      counts = body['attempt_histogram'].map { |h| h['count'] }
      expect(counts).to eq(counts.sort.reverse)
    end

    it 'даёт ровно столько корзин, сколько попросили' do
      bootstrap!
      get '/analytics/overview?buckets=6'

      expect(body['timeline']['buckets'].size).to eq(6)
    end

    it 'раскладывает все решения по корзинам без потерь' do
      bootstrap!
      get '/analytics/overview'

      totals = body['timeline']['buckets'].sum { |b| b['total'] }
      expect(totals).to eq(body['total'])
    end

    it 'сужает выборку фильтром provider так же, как /report' do
      bootstrap!
      get '/analytics/overview?provider=vipay'
      overview = body
      get '/report?provider=vipay'

      expect(overview['total']).to eq(body['total_operations'])
    end

    it 'на пустой выборке отдаёт нули и корзины без отметок времени' do
      bootstrap!
      get '/analytics/overview?provider=no_such_provider'

      expect(body).to include(
        'total' => 0, 'approved_amount' => 0, 'avg_latency_sec' => nil
      ).and include('timeline' => hash_including('from' => nil, 'bucket_seconds' => nil))
    end
  end

  describe 'GET /analytics/decisions' do
    let(:context_fields) do
      { 'id' => 1, 'amount' => 15_000, 'bank' => 'sberbank',
        'merchant' => 'alpha_market', 'gate' => 'RUB_SBP_WITHDRAW' }
    end

    it 'добавляет к решению контекст операции' do
      bootstrap!
      get '/analytics/decisions?limit=1'

      expect(body['items'].first).to include(context_fields)
    end

    it 'отдаёт created_at в ISO 8601 с зоной' do
      bootstrap!
      get '/analytics/decisions?limit=1'

      expect(body['items'].first['created_at']).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
    end

    it 'не меняет форму attempts относительно /decisions' do
      bootstrap!
      get '/decisions?limit=3'
      plain = body['items']
      get '/analytics/decisions?limit=3'

      expect(body['items'].map { |d| d['attempts'] }).to eq(plain.map { |d| d['attempts'] })
    end

    it 'листает через next_offset' do
      bootstrap!
      get '/analytics/decisions?limit=4'

      expect(body).to include('total' => 10, 'offset' => 0, 'next_offset' => 4)
    end
  end

  describe 'GET /decisions' do
    it 'остаётся в формате routing_decisions_test.json без полей контекста' do
      bootstrap!
      get '/decisions?limit=1'

      expect(body['items'].first.keys).to eq(
        %w[operation_id selected_provider attempts simulated_result latency_sec]
      )
    end
  end

  describe 'статика консоли' do
    it 'отдаёт index.html по /console/' do
      get '/console/'

      expect([last_response.status, last_response.content_type])
        .to eq([200, 'text/html;charset=utf-8'])
    end

    it 'ведёт /console на /console/' do
      get '/console'

      expect(last_response.status).to eq(302)
    end

    it 'отдаёт ассеты с их content-type' do
      get '/console/assets/js/app.js'

      expect(last_response.content_type).to eq('application/javascript;charset=utf-8')
    end

    it 'не выпускает запрос за пределы каталога консоли' do
      get '/console/../Gemfile'

      expect(last_response.status).to eq(404)
    end
  end
end
