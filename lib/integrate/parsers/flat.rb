# frozen_string_literal: true

module Integrate
  module Parsers
    class Flat
      def self.parse(doc, filename:)
        new(doc, filename: filename).parse
      end

      def initialize(doc, filename:)
        @doc = doc
        @filename = filename
        @warnings = []
      end

      def parse
        {
          "format" => "flat",
          "version" => @doc["version"] || "flat",
          "title" => @doc["title"] || @doc["name"],
          "base_url" => @doc["base_url"] || @doc["baseUrl"],
          "auth" => map_auth(@doc["auth"] || {}),
          "extra_auths" => [],
          "endpoints" => Array(@doc["endpoints"]).map { |ep| map_endpoint(ep) },
          "statuses" => normalize_statuses(@doc["statuses"] || @doc["status_map"]),
          "gateway" => @doc["gateway"].is_a?(Hash) ? @doc["gateway"] : nil,
          "warnings" => @warnings
        }
      end

      private

      def map_auth(auth)
        return { "type" => "none" } if auth.nil? || auth.empty?

        type = auth["type"].to_s
        type = "api_key" if type == "apiKey"
        {
          "type" => type.empty? ? "api_key" : type,
          "in" => auth["in"] || "header",
          "name" => auth["name"] || (type == "bearer" ? "Authorization" : "X-API-Key"),
          "scheme_name" => auth["scheme_name"] || type,
          "credentials_key" => auth["credentials_key"] || (type == "bearer" ? "token" : "api_key")
        }
      end

      def map_endpoint(ep)
        ep = Util.deep_stringify(ep)
        method = ep["method"].to_s.upcase
        path = ep["path"].to_s
        fields = Array(ep["fields"] || ep.dig("request", "fields")).map { |f| normalize_field(f) }
        {
          "method" => method,
          "path" => path,
          "operation_id" => ep["operation_id"] || ep["name"],
          "tags" => Array(ep["tags"]),
          "description" => ep["description"].to_s,
          "parameters" => Array(ep["parameters"]),
          "request" => {
            "content_type" => ep.dig("request", "content_type") || "application/json",
            "fields" => fields,
            "required" => Array(ep["required"]),
            "example" => ep.dig("request", "example") || ep["example"]
          },
          "responses" => Array(ep["responses"]).map { |r| map_response(r) }
        }
      end

      def map_response(resp)
        resp = Util.deep_stringify(resp)
        {
          "http_status" => resp["http_status"] || resp["status"] || 0,
          "description" => resp["description"].to_s,
          "fields" => Array(resp["fields"]).map { |f| normalize_field(f) },
          "example" => resp["example"]
        }
      end

      def normalize_field(field)
        field = { "name" => field } if field.is_a?(String)
        field = Util.deep_stringify(field)
        {
          "name" => field["name"],
          "type" => field["type"],
          "format" => field["format"],
          "description" => field["description"].to_s,
          "minimum" => field["minimum"],
          "maximum" => field["maximum"],
          "pattern" => field["pattern"],
          "enum" => field["enum"],
          "required" => field["required"] == true,
          "example" => field["example"]
        }
      end

      def normalize_statuses(raw)
        case raw
        when Hash
          raw.keys.map(&:to_s)
        when Array
          raw.map(&:to_s)
        else
          []
        end
      end
    end
  end
end
