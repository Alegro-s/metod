# frozen_string_literal: true

module Integrate
  module Parsers
    class OpenAPI
      COMPOSITE = %w[oneOf anyOf allOf].freeze

      def self.parse(doc, filename:)
        new(doc, filename: filename).parse
      end

      def initialize(doc, filename:)
        @doc = doc
        @filename = filename
        @warnings = []
        @ref_cache = {}
      end

      def parse
        {
          "format" => "openapi",
          "version" => @doc["openapi"].to_s,
          "title" => dig("info", "title"),
          "base_url" => base_url,
          "auth" => primary_auth,
          "extra_auths" => extra_auths,
          "endpoints" => endpoints,
          "statuses" => [],
          "gateway" => extension_gateway,
          "warnings" => @warnings
        }
      end

      private

      def base_url
        servers = @doc["servers"]
        return nil unless servers.is_a?(Array) && servers.first.is_a?(Hash)

        servers.first["url"]
      end

      def security_schemes
        @security_schemes ||= begin
          schemes = dig("components", "securitySchemes") || {}
          schemes.is_a?(Hash) ? schemes : {}
        end
      end

      def used_scheme_names
        names = []
        Array(@doc["security"]).each { |item| names.concat(item.keys) if item.is_a?(Hash) }
        (@doc["paths"] || {}).each_value do |path_item|
          next unless path_item.is_a?(Hash)

          path_item.each_value do |op|
            next unless op.is_a?(Hash)

            Array(op["security"]).each { |item| names.concat(item.keys) if item.is_a?(Hash) }
          end
        end
        names.uniq
      end

      def mapped_auths
        @mapped_auths ||= begin
          names = used_scheme_names
          names = security_schemes.keys if names.empty?
          names.filter_map do |name|
            scheme = security_schemes[name]
            next unless scheme.is_a?(Hash)

            map_scheme(name, scheme)
          end
        end
      end

      def primary_auth
        mapped_auths.first || { "type" => "none" }
      end

      def extra_auths
        mapped_auths.drop(1)
      end

      def map_scheme(name, scheme)
        type = scheme["type"].to_s
        if type == "apiKey"
          {
            "type" => "api_key",
            "in" => scheme["in"].to_s,
            "name" => scheme["name"].to_s,
            "scheme_name" => name,
            "credentials_key" => "api_key"
          }
        elsif type == "http" && scheme["scheme"].to_s.downcase == "bearer"
          {
            "type" => "bearer",
            "in" => "header",
            "name" => "Authorization",
            "scheme_name" => name,
            "credentials_key" => "token"
          }
        elsif type == "oauth2"
          @warnings << warning("oauth_as_bearer", "OAuth2 схема #{name}: в прототипе генерируется Bearer, токен получают снаружи")
          {
            "type" => "oauth2",
            "in" => "header",
            "name" => "Authorization",
            "scheme_name" => name,
            "credentials_key" => "token"
          }
        else
          @warnings << warning("unsupported_auth", "Схема авторизации #{name} (#{type}) не поддерживается")
          nil
        end
      end

      def endpoints
        paths = @doc["paths"]
        raise ParseError, "В OpenAPI нет ключа paths." unless paths.is_a?(Hash)

        verbs = %w[get post put patch delete]
        list = []
        paths.each do |path, item|
          next unless item.is_a?(Hash)

          item = resolve(item)
          verbs.each do |verb|
            op = item[verb]
            next unless op.is_a?(Hash)

            list << build_endpoint(verb.upcase, path, item, op)
          end
        end
        list
      end

      def build_endpoint(method, path, path_item, op)
        params = Array(path_item["parameters"]) + Array(op["parameters"])
        params = params.map { |p| resolve(p) }.select { |p| p.is_a?(Hash) }
        request = extract_request(op)
        responses = extract_responses(op)
        {
          "method" => method,
          "path" => path,
          "operation_id" => op["operationId"],
          "tags" => Array(op["tags"]),
          "description" => [op["summary"], op["description"]].compact.join(" "),
          "parameters" => params.map { |p| normalize_param(p) },
          "request" => request,
          "responses" => responses
        }
      end

      def normalize_param(param)
        {
          "name" => param["name"],
          "in" => param["in"],
          "required" => param["required"] == true,
          "description" => param["description"].to_s,
          "schema" => resolve(param["schema"] || {})
        }
      end

      def extract_request(op)
        body = op["requestBody"]
        return empty_request unless body.is_a?(Hash)

        body = resolve(body)
        content = body["content"]
        return empty_request unless content.is_a?(Hash)

        content_type, media = pick_json_media(content)
        schema = resolve(media["schema"] || {})
        note_composites(schema, "requestBody")
        {
          "content_type" => content_type,
          "fields" => Schema.fields(schema, resolver: self),
          "required" => Array(schema["required"]),
          "example" => first_example(media, schema)
        }
      end

      def empty_request
        { "content_type" => nil, "fields" => [], "required" => [], "example" => nil }
      end

      def extract_responses(op)
        responses = op["responses"]
        return [] unless responses.is_a?(Hash)

        responses.filter_map do |code, resp|
          resp = resolve(resp)
          next unless resp.is_a?(Hash)

          content = resp["content"]
          media = content.is_a?(Hash) ? (pick_json_media(content)[1] || {}) : {}
          schema = resolve(media["schema"] || {})
          note_composites(schema, "response #{code}")
          {
            "http_status" => normalize_status(code),
            "description" => resp["description"].to_s,
            "fields" => Schema.fields(schema, resolver: self),
            "example" => first_example(media, schema)
          }
        end
      end

      def pick_json_media(content)
        preferred = content.find { |ct, _| ct.to_s.include?("json") }
        preferred || content.first
      end

      def first_example(media, schema)
        return nil unless media.is_a?(Hash)

        if media["example"]
          media["example"]
        elsif media["examples"].is_a?(Hash)
          first = media["examples"].values.first
          first.is_a?(Hash) ? first["value"] : first
        else
          schema["example"]
        end
      end

      def normalize_status(code)
        return code.to_i if code.to_s.match?(/\A\d+\z/)

        0
      end

      def note_composites(schema, where)
        return unless schema.is_a?(Hash)

        COMPOSITE.each do |key|
          next unless schema[key]

          @warnings << warning("composite_schema", "#{where}: #{key} не разбирается полностью, берём первый конкретный вариант")
        end
      end

      def extension_gateway
        info = @doc["info"] if @doc["info"].is_a?(Hash)
        ext = info && (info["x-space-gateway"] || info["x_gateway"])
        ext.is_a?(Hash) ? Util.deep_stringify(ext) : nil
      end

      def resolve(node)
        return node unless node.is_a?(Hash)
        return node unless node["$ref"]

        ref = node["$ref"].to_s
        return @ref_cache[ref] if @ref_cache.key?(ref)

        unless ref.start_with?("#/")
          @warnings << warning("external_ref", "Внешний $ref не поддержан: #{ref}")
          return node.except("$ref")
        end

        cursor = @doc
        ref.sub(%r{\A#/}, "").split("/").each do |part|
          part = part.gsub("~1", "/").gsub("~0", "~")
          cursor = cursor.is_a?(Hash) ? cursor[part] : nil
        end
        unless cursor
          @warnings << warning("broken_ref", "Не найден $ref #{ref}")
          return {}
        end

        @ref_cache[ref] = {}
        resolved = resolve(cursor)
        @ref_cache[ref] = resolved
        extras = node.reject { |k, _| k == "$ref" }
        extras.empty? ? resolved : extras.merge(resolved)
      end

      def dig(*keys)
        keys.reduce(@doc) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
      end

      def warning(code, message, path = nil)
        { "code" => code, "message" => message, "path" => path }
      end

      public :resolve
    end

    module Schema
      module_function

      def fields(schema, resolver:, prefix: "")
        schema = resolver.resolve(schema || {})
        return [] unless schema.is_a?(Hash)

        schema = unwrap_composite(schema, resolver)
        props = schema["properties"]
        if props.is_a?(Hash)
          required = Array(schema["required"])
          props.flat_map do |name, sub|
            sub = resolver.resolve(sub)
            path = prefix.empty? ? name.to_s : "#{prefix}.#{name}"
            sub = unwrap_composite(sub, resolver)
            if object?(sub)
              fields(sub, resolver: resolver, prefix: path)
            else
              [field_entry(path, sub, required.include?(name))]
            end
          end
        elsif !prefix.empty?
          [field_entry(prefix, schema, false)]
        else
          []
        end
      end

      def unwrap_composite(schema, resolver)
        if schema["allOf"].is_a?(Array)
          merged = { "properties" => {}, "required" => [] }
          schema["allOf"].each do |part|
            part = resolver.resolve(part)
            part = unwrap_composite(part, resolver)
            merged["properties"].merge!(part["properties"] || {})
            merged["required"] |= Array(part["required"])
            %w[type description example].each { |k| merged[k] ||= part[k] }
          end
          return merged
        end
        alt = schema["oneOf"] || schema["anyOf"]
        if alt.is_a?(Array) && alt.any?
          resolver.resolve(alt.first)
        else
          schema
        end
      end

      def object?(schema)
        schema.is_a?(Hash) && (schema["type"] == "object" || schema["properties"].is_a?(Hash))
      end

      def field_entry(path, schema, required)
        {
          "name" => path,
          "type" => schema["type"],
          "format" => schema["format"],
          "description" => schema["description"].to_s,
          "minimum" => schema["minimum"] || schema["exclusiveMinimum"],
          "maximum" => schema["maximum"] || schema["exclusiveMaximum"],
          "pattern" => schema["pattern"],
          "enum" => schema["enum"],
          "required" => required,
          "example" => schema["example"]
        }
      end
    end
  end
end
