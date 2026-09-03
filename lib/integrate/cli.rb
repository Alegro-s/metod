# frozen_string_literal: true

require "optparse"

module Integrate
  class CLI
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = %w[parse generate ui].include?(@argv.first) ? @argv.shift : "generate"
      options = defaults
      parser = option_parser(options)
      parser.parse!(@argv)

      case command
      when "ui"
        require_relative "web"
        Web.start(port: options[:port])
      when "parse"
        run_parse(options)
      else
        run_generate(options)
      end
    rescue ParseError, Error => e
      warn(e.message)
      1
    end

    private

    def defaults
      {
        spec: nil,
        provider: "provider",
        lang: "ruby",
        output: File.join(Dir.pwd, "output"),
        config: nil,
        port: 4567
      }
    end

    def option_parser(options)
      OptionParser.new do |opts|
        opts.banner = "Usage: integrate [parse|generate|ui] --spec FILE --provider NAME [--lang ruby]"
        opts.on("--spec FILE", "Path to provider_api.yaml") { |v| options[:spec] = v }
        opts.on("--provider NAME", "Provider name (e.g. novapay)") { |v| options[:provider] = v }
        opts.on("--lang LANG", "Output language (only ruby)") { |v| options[:lang] = v }
        opts.on("--output DIR", "Output directory") { |v| options[:output] = v }
        opts.on("--config FILE", "Override .spacegen.yml") { |v| options[:config] = v }
        opts.on("--port N", Integer, "UI port") { |v| options[:port] = v }
        opts.on("-h", "--help", "Help") do
          puts opts
          exit 0
        end
      end
    end

    def run_parse(options)
      require_spec!(options)
      ir = Integrate.parse(spec_path: options[:spec], provider: options[:provider], config_path: options[:config])
      FileUtils.mkdir_p(options[:output])
      path = File.join(options[:output], "ir.json")
      File.write(path, JSON.pretty_generate(ir))
      puts JSON.pretty_generate(ir)
      warn "Wrote #{path}"
      0
    end

    def run_generate(options)
      require_spec!(options)
      if options[:lang] && options[:lang] != "ruby"
        warn "only ruby is supported"
      end

      puts "Parsing spec..."
      ir = Integrate.parse(spec_path: options[:spec], provider: options[:provider], config_path: options[:config])
      print_understanding(ir)

      puts "Generating service..."
      puts "Generating integration guide..."
      puts "Generating test fixtures..."
      result = Integrate.generate_from_ir(ir, output_dir: options[:output], lang: "ruby")
      puts result.syntax_ok ? "ruby -c: OK" : "ruby -c: FAIL"
      warn result.syntax_error if result.syntax_error
      unless result.missing_methods.empty?
        warn "missing methods: #{result.missing_methods.join(', ')}"
      end
      puts "Output:"
      result.paths.each { |path| puts "  #{path}" }
      0
    end

    def print_understanding(ir)
      puts "Format: #{format_label(ir)}"
      eps = Array(ir["endpoints"])
      list = eps.map { |ep| "#{ep['method']} #{ep['path']}" }.join(", ")
      puts "Found #{eps.size} endpoints: #{list}"
      auth = ir["auth"] || {}
      puts "Auth: #{auth_line(auth)}"
      webhook = ir["webhook"]
      if webhook && webhook["header"]
        puts "Webhook signature: #{webhook['header']} (#{webhook['algorithm']})"
      end
      warns = Array(ir["warnings"])
      return if warns.empty?

      puts "Warnings:"
      warns.each do |w|
        loc = w["path"] ? "#{w['path']}: " : ""
        puts "  - #{loc}#{w['code']}"
      end
    end

    def format_label(ir)
      ir["format"] == "openapi" ? "OpenAPI #{ir['version']}" : "flat YAML"
    end

    def auth_line(auth)
      name = auth["scheme_name"] || auth["type"]
      case auth["type"]
      when "api_key"
        "#{name} (#{auth['in']}: #{auth['name']})"
      when "bearer"
        "#{name} (Bearer)"
      when "oauth2"
        "#{name} (OAuth2 → Bearer)"
      else
        auth["type"].to_s
      end
    end

    def require_spec!(options)
      raise ParseError, "Укажите --spec provider_api.yaml" if options[:spec].to_s.empty?
    end
  end
end
