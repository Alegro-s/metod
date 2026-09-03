# frozen_string_literal: true

module Integrate
  class Config
    attr_reader :data

    def self.load(spec_path:, config_path:, provider:)
      path = resolve_path(spec_path, config_path, provider)
      return new({}, source: nil) unless path && File.file?(path)

      new(load_yaml_file(path), source: path)
    end

    def self.from_text(text, provider:)
      return new({}, source: nil) if text.nil? || text.strip.empty?

      new(Util.deep_stringify(YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true) || {}), source: :inline)
    rescue Psych::SyntaxError => e
      raise ParseError, "Конфиг .spacegen.yml сломан, строка #{e.line}: #{e.problem}"
    end

    def self.resolve_path(spec_path, config_path, provider)
      return config_path if config_path && !config_path.to_s.empty? && File.file?(config_path)
      return nil unless spec_path && File.file?(spec_path)

      dir = File.dirname(spec_path)
      base = File.basename(spec_path, File.extname(spec_path))
      candidates = [
        File.join(dir, "#{base}.spacegen.yml"),
        File.join(dir, "#{provider}.spacegen.yml"),
        File.join(dir, ".spacegen.yml")
      ]
      candidates.find { |p| File.file?(p) }
    end

    def self.load_yaml_file(path)
      Util.deep_stringify(YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: true) || {})
    rescue Psych::SyntaxError => e
      raise ParseError, "Конфиг .spacegen.yml сломан, строка #{e.line}: #{e.problem}"
    end

    def initialize(data, source:)
      @data = data || {}
      @source = source
    end

    def source
      @source
    end

    def endpoint_role(method, path)
      table = @data["endpoints"]
      return nil unless table.is_a?(Hash)

      table["#{method} #{path}"] || table[path]
    end

    def status_overrides
      @data["status_map"] || {}
    end

    def field_overrides
      @data["field_map"] || {}
    end

    def gateway
      @data["gateway"] if @data["gateway"].is_a?(Hash)
    end
  end
end
