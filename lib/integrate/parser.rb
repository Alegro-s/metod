# frozen_string_literal: true

require_relative "parsers/openapi"
require_relative "parsers/flat"

module Integrate
  module Parser
    module_function

    def load(path)
      raise ParseError, "Файл спецификации не найден: #{path}" unless File.file?(path)

      load_text(File.read(path), filename: File.basename(path))
    end

    def load_text(text, filename: "provider_api.yaml")
      raw = YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true)
      raise ParseError, "Файл #{filename} пустой." if raw.nil?
      unless raw.is_a?(Hash)
        raise ParseError, "Ожидается YAML-объект в корне файла #{filename}."
      end

      data = Util.deep_stringify(raw)
      if data["openapi"].to_s.start_with?("3.")
        Parsers::OpenAPI.parse(data, filename: filename)
      elsif data.key?("base_url") || data.key?("endpoints")
        Parsers::Flat.parse(data, filename: filename)
      else
        raise ParseError, <<~MSG.strip
          Неизвестный формат spec.
          Ожидается OpenAPI 3.x (ключ openapi) или плоский YAML (ключи base_url, endpoints).
        MSG
      end
    rescue Psych::SyntaxError => e
      raise ParseError, "YAML сломан, строка #{e.line}: #{e.problem}"
    end
  end
end
