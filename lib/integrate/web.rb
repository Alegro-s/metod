# frozen_string_literal: true

require "webrick"
require "cgi"

module Integrate
  class Web
    def self.start(port:)
      new(port: port).start
    end

    def initialize(port:)
      @port = port
    end

    def start
      server = WEBrick::HTTPServer.new(
        Port: @port,
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO),
        AccessLog: []
      )
      server.mount_proc("/") { |req, res| route(req, res) }
      trap("INT") { server.shutdown }
      trap("TERM") { server.shutdown }
      $stderr.puts "integrate UI: http://127.0.0.1:#{@port}"
      server.start
      0
    end

    def route(req, res)
      case [req.request_method, req.path]
      when ["GET", "/"], ["GET", "/index.html"]
        html(res, File.read(File.join(Integrate::TEMPLATES, "ui.html")))
      when ["GET", "/api/examples"]
        json(res, example_index)
      when ["GET", "/api/examples/novapay"], ["GET", "/api/examples/payflow"], ["GET", "/api/examples/wallet"]
        name = req.path.split("/").last
        json(res, load_example(name))
      when ["POST", "/api/parse"]
        json(res, handle_parse(read_json(req)))
      when ["POST", "/api/generate"]
        json(res, handle_generate(read_json(req)))
      else
        res.status = 404
        json(res, { "error" => "not found" })
      end
    rescue ParseError, Error => e
      res.status = 422
      json(res, { "error" => e.message })
    rescue StandardError => e
      res.status = 500
      json(res, { "error" => e.message })
    end

    private

    def example_index
      {
        "examples" => [
          { "id" => "novapay", "title" => "NovaPay · OpenAPI · API Key · SBP", "provider" => "novapay" },
          { "id" => "payflow", "title" => "Payflow · OpenAPI · Bearer · transfers", "provider" => "payflow" },
          { "id" => "wallet", "title" => "Wallet · плоский YAML", "provider" => "wallet" }
        ]
      }
    end

    def load_example(name)
      spec = File.join(Integrate::EXAMPLES, "#{name}.yaml")
      cfg = File.join(Integrate::EXAMPLES, "#{name}.spacegen.yml")
      raise ParseError, "Пример #{name} не найден" unless File.file?(spec)

      {
        "id" => name,
        "provider" => name,
        "spec" => File.read(spec),
        "config" => File.file?(cfg) ? File.read(cfg) : ""
      }
    end

    def handle_parse(body)
      ir = Integrate.parse_text(
        spec_text: body["spec"].to_s,
        provider: body["provider"].to_s,
        config_text: body["config"]
      )
      { "ir" => ir }
    end

    def handle_generate(body)
      ir = Integrate.parse_text(
        spec_text: body["spec"].to_s,
        provider: body["provider"].to_s,
        config_text: body["config"]
      )
      dir = Dir.mktmpdir("integrate-ui")
      result = Integrate.generate_from_ir(ir, output_dir: dir)
      name = ir.dig("provider", "name")
      {
        "ir" => ir,
        "syntax_ok" => result.syntax_ok,
        "syntax_error" => result.syntax_error,
        "missing_methods" => result.missing_methods,
        "files" => {
          "#{name}_service.rb" => File.read(File.join(dir, "#{name}_service.rb")),
          "INTEGRATION.md" => File.read(File.join(dir, "INTEGRATION.md")),
          "fixtures.json" => File.read(File.join(dir, "fixtures.json")),
          "ir.json" => File.read(File.join(dir, "ir.json"))
        }
      }
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    def read_json(req)
      raw = req.body.to_s
      raise ParseError, "Пустое тело запроса" if raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      raise ParseError, "Ожидается JSON { spec, provider, config }"
    end

    def json(res, payload)
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.pretty_generate(payload)
    end

    def html(res, body)
      res["Content-Type"] = "text/html; charset=utf-8"
      res.body = body
    end
  end
end
