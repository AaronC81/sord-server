require_relative '../app/app'
require 'rspec'
require 'rack/test'
require 'sord'

describe Sinatra::Application do
  include Rack::Test::Methods
  let(:app) { Sinatra::Application.new }

  def run(body)
    post("/run", body.to_json)
  end

  context 'validation' do
    it 'rejects requests missing \'code\'' do
      run({ options: { mode: "rbi" } })
      expect(last_response.status).to eq 400
    end

    it 'rejects requests missing \'options\'' do
      run({ code: 'def x; end' })
      expect(last_response.status).to eq 400
    end
  end

  it 'can do a simple Sord run' do
    run({
      code: <<~RUBY,
        class X
          # @return [String]
          def foo; end
        end
      RUBY
      options: {
        mode: :rbs,
        break_params: 4,
        replace_errors_with_untyped: true,
        replaced_unresolved_with_untyped: true,
        comments: false,
      }
    })

    expect(last_response.status).to eq 200
    response = JSON.parse(last_response.body, symbolize_names: true)
    expect(response).to eq({
      info: {
        version: Sord::VERSION,
      },
      code: <<~RUBY.strip,
        class X
          def foo: () -> String
        end
      RUBY
      yard_log: <<~YARD,
        Files:           1
        Modules:         0 (    0 undocumented)
        Classes:         1 (    1 undocumented)
        Constants:       0 (    0 undocumented)
        Attributes:      0 (    0 undocumented)
        Methods:         1 (    0 undocumented)
         50.00% documented
      YARD
      sord_log: <<~SORD,
        \e[32m[DONE ]\e[0m Processed 2 objects (1 namespaces and 1 methods)
      SORD
    })
  end
end
