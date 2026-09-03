# frozen_string_literal: true

module Integrate
  class Generator
    REQUIRED_METHODS = %w[create_request fetch_status process_callback check_conditions].freeze

    attr_reader :ir, :files, :syntax_ok, :syntax_error, :missing_methods

    def initialize(ir, output_dir:, lang: "ruby")
      @ir = ir
      @output_dir = output_dir
      @lang = lang
      @files = {}
      @syntax_ok = nil
      @syntax_error = nil
      @missing_methods = []
    end

    def write!
      raise Error, "only ruby is supported" if @lang && @lang != "ruby" && @lang != ""

      FileUtils.mkdir_p(@output_dir)
      name = @ir.dig("provider", "name")
      @files = {
        "#{name}_service.rb" => render("service.rb.erb"),
        "INTEGRATION.md" => render("integration.md.erb"),
        "fixtures.json" => render("fixtures.json.erb"),
        "ir.json" => JSON.pretty_generate(@ir)
      }
      @files.each do |filename, content|
        File.write(File.join(@output_dir, filename), content)
      end
      check_service!(@files["#{name}_service.rb"])
      self
    end

    def service_filename
      "#{@ir.dig('provider', 'name')}_service.rb"
    end

    def paths
      @files.keys.map { |name| File.join(@output_dir, name) }
    end

    private

    def render(template_name)
      path = File.join(Integrate::TEMPLATES, template_name)
      erb = ERB.new(File.read(path), trim_mode: "-")
      erb.filename = path
      Context.new(@ir).render(erb)
    end

    def check_service!(source)
      Tempfile.create(["service", ".rb"]) do |file|
        file.write(source)
        file.flush
        out = `ruby -c #{file.path} 2>&1`
        @syntax_ok = $?.success?
        @syntax_error = @syntax_ok ? nil : out.strip
      end
      @missing_methods = REQUIRED_METHODS.reject { |m| source.match?(/def #{m}\b/) }
    end

    class Context
      def initialize(ir)
        @ir = ir
      end

      def render(erb)
        erb.result(binding)
      end

      def ir
        @ir
      end

      def provider
        @ir["provider"] || {}
      end

      def auth
        @ir["auth"] || {}
      end

      def endpoints
        Array(@ir["endpoints"])
      end

      def endpoint(role)
        endpoints.find { |ep| ep["role"] == role }
      end

      def field_map
        Array(@ir["field_map"])
      end

      def status_map
        @ir["status_map"] || {}
      end

      def error_map
        Array(@ir["error_map"])
      end

      def webhook
        @ir["webhook"]
      end

      def conditions
        Array(@ir["conditions"])
      end

      def gateway
        @ir["gateway"]
      end

      def warnings
        Array(@ir["warnings"])
      end

      def ruby_hash(value, indent: 2)
        JSON.pretty_generate(value).gsub(/"([A-Za-z_][A-Za-z0-9_]*)":/, '\1:').gsub(/"$/, "").gsub(/^/, " " * indent).sub(/\A\s+/, " " * indent)
      end

      def ruby_string_hash(hash)
        lines = hash.map { |k, v| "    #{k.inspect} => #{v.inspect}" }
        "{\n#{lines.join(",\n")}\n  }.freeze"
      end

      def ruby_error_hash
        lines = error_map.map { |row| "    #{row['http']} => #{row['internal'].inspect}" }
        "{\n#{lines.join(",\n")}\n  }.freeze"
      end

      def source_expr(source, transform)
        expr =
          case source
          when /\Aliteral:(.*)\z/
            $1.inspect
          when /\Aoperation\.payout_requisite\.sbp\.(.+)\z/
            "operation.payout_requisite.dig('sbp', '#{$1}')"
          when /\Aoperation\.payout_requisite\.(.+)\z/
            "operation.payout_requisite['#{$1}']"
          when "operation.amount"
            "operation.amount"
          when "operation.id"
            "operation.id"
          when "operation.currency"
            "operation.currency"
          when "operation.provider_operation_id"
            "operation.provider_operation_id"
          else
            source.to_s
          end
        expr = "(#{expr} * 100).to_i" if transform == "to_minor_units"
        expr
      end

      def payload_ruby
        required = field_map.select { |f| f["required"] != false }
        optional = field_map.select { |f| f["required"] == false }
        nested = Util.nest_hash(required.map { |f| [f["target"], :placeholder] })
        assign_placeholders(nested, required)
        lines = []
        lines << "payload = #{ruby_literal(nested, 2).lstrip}"
        optional.each do |field|
          var = field["target"].tr(".", "_")
          expr = source_expr(field["source"], field["transform"])
          path = field["target"].split(".")
          lines << "#{var} = #{expr}"
          setter = payload_set_expr(path)
          lines << "#{setter} = #{var} unless #{var}.nil? || #{var} == ''"
        end
        lines << "payload"
        lines.map { |l| l }.join("\n    ")
      end

      def assign_placeholders(node, fields)
        fields.each do |field|
          parts = field["target"].split(".")
          cursor = node
          parts.each_with_index do |part, idx|
            if idx == parts.length - 1
              cursor[part] = source_expr(field["source"], field["transform"])
            else
              cursor = cursor[part]
            end
          end
        end
      end

      def ruby_literal(node, indent)
        case node
        when Hash
          return "{}" if node.empty?

          inner = node.map do |k, v|
            val = v.is_a?(String) && v.match?(/\Aoperation\.|ENV\.|\(.*\* 100|\A['"]/) ? v : ruby_literal(v, indent + 2)
            val = v if v.is_a?(String) && (v.start_with?("operation.") || v.start_with?("(") || v.start_with?("'") || v.start_with?("\""))
            val = ruby_literal(v, indent + 2) if v.is_a?(Hash)
            "#{' ' * (indent + 2)}#{k}: #{val}"
          end
          "{\n#{inner.join(",\n")}\n#{' ' * indent}}"
        when String
          node
        else
          node.inspect
        end
      end

      def payload_set_expr(parts)
        if parts.length == 1
          "payload[:#{parts.first}]"
        else
          root = parts.first
          rest = parts[1..]
          "payload[:#{root}][:#{rest.last}]"
        end
      end

      def interpolated_path(path)
        path.gsub(/\{[^}]+\}/, '#{operation.provider_operation_id}')
      end

      def auth_header_ruby
        case auth["type"]
        when "api_key"
          if auth["in"] == "query"
            "{}"
          else
            "{ #{auth['name'].inspect} => ENV.fetch('#{provider['name'].upcase}_API_KEY') }"
          end
        when "bearer", "oauth2"
          "{ 'Authorization' => \"Bearer \#{ENV.fetch('#{provider['name'].upcase}_TOKEN')}\" }"
        else
          "{}"
        end
      end

      def fixture_request
        pairs = field_map.map do |field|
          [field["target"], fixture_value(field)]
        end
        Util.nest_hash(pairs)
      end

      def fixture_value(field)
        case field["source"]
        when /\Aliteral:(.*)\z/
          $1
        when "operation.amount"
          field["transform"] == "to_minor_units" ? 1_500_000 : 1500.0
        when "operation.id"
          "op_abc123"
        when /phone/
          "79001234567"
        when /bank_code/
          "044525225"
        when /bank_name/
          "Sberbank"
        else
          "example"
        end
      end

      def create_success_example
        from_endpoint = example_from(endpoint("create"), 201) || example_from(endpoint("create"), 200)
        from_endpoint || { "id" => "np_7f3a9b2c", "status" => first_status_for("in_progress") }
      end

      def create_error_example
        from_endpoint = example_from(endpoint("create"), 422) || example_from(endpoint("create"), 400)
        from_endpoint || { "error" => { "code" => "validation_error", "message" => "Amount is too low" } }
      end

      def fetch_example
        example_from(endpoint("fetch"), 200) || { "id" => "np_7f3a9b2c", "status" => first_status_for("approved") }
      end

      def example_from(ep, status)
        return nil unless ep

        resp = Array(ep["responses"]).find { |r| r["http_status"].to_i == status }
        resp && resp["example"]
      end

      def first_status_for(internal)
        found = status_map.find { |_, v| v == internal }
        found ? found[0] : internal
      end

      def callback_payload(action)
        ev = Array(webhook && webhook["events"]).find { |e| e["action"] == action }
        event_name = ev ? ev["provider_event"] : action
        id_field = ev ? ev["id_field"] : "id"
        field = webhook && webhook["event_field"] || "event"
        payload = { field => event_name, id_field => "np_7f3a9b2c" }
        payload["status"] = action == "approve" ? first_status_for("approved") : first_status_for("rejected")
        if action == "reject"
          payload["error"] = { "code" => "recipient_not_found" }
        end
        payload
      end

      def purpose_for(ep)
        {
          "create" => "Создание выплаты",
          "fetch" => "Статус",
          "cancel" => "Отмена",
          "webhook" => "Callback",
          "unknown" => ep["description"].to_s.empty? ? "Не сопоставлено с контрактом" : ep["description"]
        }[ep["role"]] || "Другое"
      end

      def idempotency_cell(ep)
        header = ep.dig("idempotency", "header")
        return header if header
        return webhook["header"].to_s if ep["role"] == "webhook" && webhook && webhook["header"]

        "-"
      end

      def auth_title
        case auth["type"]
        when "api_key" then "API Key"
        when "bearer" then "Bearer"
        when "oauth2" then "OAuth2 (Bearer token)"
        else auth["type"].to_s
        end
      end
    end
  end
end
