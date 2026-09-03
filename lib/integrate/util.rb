# frozen_string_literal: true

module Integrate
  module Util
    module_function

    def provider_meta(name)
      key = name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      key = "provider" if key.empty?
      {
        "name" => key,
        "class_name" => "#{key.split('_').map(&:capitalize).join}Service",
        "base_url_env" => "#{key.upcase}_BASE_URL"
      }
    end

    def deep_stringify(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array
        obj.map { |v| deep_stringify(v) }
      else
        obj
      end
    end

    def symbolize_names(hash)
      deep_stringify(hash)
    end

    def compact_blank(hash)
      hash.reject { |_, v| v.nil? || v == "" || v == [] }
    end

    def present?(value)
      !value.nil? && value != "" && value != [] && value != {}
    end

    def look_like_money_minor?(field)
      blob = [field["description"], field["format"], field["name"], field["title"]].compact.join(" ").downcase
      return true if blob.match?(/kopeck|kopek|cent\b|minor unit|minor_unit|в копейк/)
      return true if field["type"] == "integer" && field["format"].to_s == "int64" && field["type"] != "number"
      false
    end

    def decimal_amount?(field)
      %w[number float double].include?(field["type"].to_s) || field["format"].to_s.match?(/decimal|float|double/)
    end

    def nest_hash(pairs)
      root = {}
      pairs.each do |path, value|
        parts = path.to_s.split(".")
        cursor = root
        parts.each_with_index do |part, idx|
          if idx == parts.length - 1
            cursor[part] = value
          else
            cursor[part] ||= {}
            cursor = cursor[part]
          end
        end
      end
      root
    end
  end
end
