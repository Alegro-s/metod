# frozen_string_literal: true

module Integrate
  class Rules
    STATUS_IN_PROGRESS = %w[pending processing created accepted in_progress queued new initiated].freeze
    STATUS_APPROVED = %w[completed success succeeded approved done paid ok].freeze
    STATUS_REJECTED = %w[failed error rejected declined cancelled canceled expired].freeze

    ERROR_BY_HTTP = {
      400 => %w[validation_error reject],
      401 => %w[invalid_credentials alert_ops],
      403 => %w[invalid_credentials alert_ops],
      402 => %w[insufficient_balance retry],
      404 => %w[not_found reject],
      409 => %w[validation_error reject],
      422 => %w[validation_error reject],
      429 => %w[rate_limit retry_backoff],
      500 => %w[internal_error retry],
      502 => %w[internal_error retry],
      503 => %w[internal_error retry]
    }.freeze

    AMOUNT_NAMES = %w[amount sum value].freeze
    CURRENCY_NAMES = %w[currency ccy].freeze
    EXTERNAL_ID_NAMES = %w[external_id order_id merchant_id idempotency_key].freeze
    RECIPIENT_ROOTS = %w[recipient destination payee sbp].freeze
    ID_EVENT_FIELDS = %w[payout_id payment_id transfer_id operation_id id].freeze

    def self.apply(raw, provider:, config:)
      new(raw, provider: provider, config: config).apply
    end

    def initialize(raw, provider:, config:)
      @raw = raw
      @provider = provider
      @config = config
      @warnings = Array(raw["warnings"]).map { |w| Util.deep_stringify(w) }
    end

    def apply
      meta = Util.provider_meta(@provider)
      endpoints = Array(@raw["endpoints"]).map { |ep| classify(ep) }
      add_missing_role_warnings(endpoints)
      endpoints.each { |ep| warn_unknown(ep) }

      create = by_role(endpoints, "create")
      fetch = by_role(endpoints, "fetch")
      webhook_ep = by_role(endpoints, "webhook")

      field_map = build_field_map(create)
      status_map = build_status_map(endpoints)
      error_map = build_error_map(endpoints)
      webhook = build_webhook(webhook_ep)
      conditions = build_conditions(create, field_map)
      gateway = build_gateway
      auth = build_auth

      {
        "provider" => meta.merge("base_url" => @raw["base_url"]),
        "format" => @raw["format"],
        "version" => @raw["version"],
        "title" => @raw["title"],
        "auth" => auth,
        "endpoints" => endpoints.map { |ep| public_endpoint(ep) },
        "field_map" => field_map,
        "status_map" => status_map,
        "error_map" => error_map,
        "webhook" => webhook,
        "conditions" => conditions,
        "gateway" => gateway,
        "warnings" => @warnings.uniq { |w| [w["code"], w["message"], w["path"]] }
      }
    end

    private

    def classify(ep)
      ep = Util.deep_stringify(ep)
      method = ep["method"].to_s.upcase
      path = ep["path"].to_s
      override = @config.endpoint_role(method, path)
      role = override || structural_role(ep) || lexical_role(ep) || "unknown"
      ep.merge("role" => role.to_s, "idempotency" => detect_idempotency(ep))
    end

    def structural_role(ep)
      method = ep["method"].to_s.upcase
      path = ep["path"].to_s
      blob = path.downcase
      return "webhook" if blob.match?(/webhook|callback|notify|\/hooks?(?:\/|\z)/)
      return "cancel" if method.match?(/POST|PATCH|PUT/) && blob.match?(%r{/(cancel|refund|reverse)(/|$|\z)})
      return "fetch" if method == "GET" && path.include?("{")
      return "create" if method == "POST" && !path.include?("{") && !blob.match?(/webhook|callback|notify|\/hooks?(?:\/|\z)/)

      nil
    end

    def lexical_role(ep)
      method = ep["method"].to_s.upcase
      text = [ep["operation_id"], *Array(ep["tags"]), ep["description"]].compact.join(" ")
      return "webhook" if text.match?(/webhook|callback|notify/i)
      return "cancel" if text.match?(/cancel|refund|reverse/i)
      return "fetch" if method == "GET" && text.match?(/status|get_payout|get_payment|getpayout|getpayment/i)
      return "create" if method != "GET" && text.match?(/create|payout|payment|deposit|transfer/i)

      nil
    end

    def detect_idempotency(ep)
      Array(ep["parameters"]).each do |param|
        name = param.is_a?(Hash) ? param["name"].to_s : param.to_s
        next unless name.match?(/idempotency/i)

        return { "header" => name }
      end
      nil
    end

    def public_endpoint(ep)
      {
        "role" => ep["role"],
        "method" => ep["method"],
        "path" => ep["path"],
        "operation_id" => ep["operation_id"],
        "idempotency" => ep["idempotency"],
        "description" => ep["description"],
        "path_params" => Array(ep["parameters"]).select { |p| p.is_a?(Hash) && p["in"] == "path" },
        "query_params" => Array(ep["parameters"]).select { |p| p.is_a?(Hash) && p["in"] == "query" },
        "request" => ep["request"],
        "responses" => ep["responses"]
      }
    end

    def by_role(endpoints, role)
      endpoints.find { |ep| ep["role"] == role }
    end

    def warn_unknown(ep)
      return unless ep["role"] == "unknown"

      @warnings << w("unmapped_endpoint",
                     "#{ep['method']} #{ep['path']} не сопоставлен с контрактом BaseService и пропущен в сервисе",
                     ep["path"])
    end

    def add_missing_role_warnings(endpoints)
      %w[create fetch webhook].each do |role|
        next if endpoints.any? { |ep| ep["role"] == role }

        @warnings << w("missing_role", "Не найден эндпоинт роли #{role}. В сервисе будет заглушка not_inferred.")
      end
    end

    def build_auth
      auth = Util.deep_stringify(@raw["auth"] || { "type" => "none" })
      Array(@raw["extra_auths"]).each do |extra|
        @warnings << w("extra_auth", "Дополнительная схема авторизации #{extra['scheme_name'] || extra['type']} пропущена")
      end
      auth
    end

    def build_field_map(create)
      overrides = @config.field_overrides
      fields = create ? Array(create.dig("request", "fields")) : []
      map = []

      amount = find_field(fields, AMOUNT_NAMES)
      if amount
        transform = amount_transform(amount)
        map << merge_override(overrides, {
          "target" => amount["name"],
          "source" => "operation.amount",
          "transform" => transform,
          "required" => amount["required"] != false
        })
      end

      currency = find_field(fields, CURRENCY_NAMES)
      if currency
        enums = Array(currency["enum"]).compact
        source = enums.length == 1 ? "literal:#{enums.first}" : "operation.currency"
        map << merge_override(overrides, {
          "target" => currency["name"],
          "source" => source,
          "transform" => nil,
          "required" => currency["required"] != false
        })
      end

      ext = find_field(fields, EXTERNAL_ID_NAMES)
      if ext
        map << merge_override(overrides, {
          "target" => ext["name"],
          "source" => "operation.id",
          "transform" => nil,
          "required" => ext["required"] != false
        })
      end

      recipient_fields = fields.select { |f| recipient_field?(f["name"]) }
      sbp = sbp?(fields, recipient_fields)
      recipient_fields.each do |field|
        leaf = field["name"].split(".").last
        next if leaf == "amount"

        source =
          if leaf == "type" && sbp
            enums = Array(field["enum"]).compact
            enums.length == 1 ? "literal:#{enums.first}" : "literal:sbp"
          elsif sbp && %w[phone bank_code bank_name].include?(leaf)
            "operation.payout_requisite.sbp.#{leaf}"
          else
            @warnings << w("requisite_shape_guessed", "Реквизит #{field['name']} взят как плоский payout_requisite") unless sbp
            "operation.payout_requisite.#{leaf}"
          end
        map << merge_override(overrides, {
          "target" => field["name"],
          "source" => source,
          "transform" => nil,
          "required" => field["required"] == true
        })
      end

      map.uniq { |row| row["target"] }
    end

    def merge_override(overrides, row)
      extra = overrides[row["target"]]
      extra = overrides[row["target"].split(".").last] if extra.nil?
      return row unless extra.is_a?(Hash)

      row.merge(Util.deep_stringify(extra))
    end

    def find_field(fields, names)
      fields.find { |f| names.include?(f["name"].to_s.split(".").last) }
    end

    def recipient_field?(name)
      root = name.to_s.split(".").first
      RECIPIENT_ROOTS.include?(root)
    end

    def sbp?(all_fields, recipient_fields)
      blob = (all_fields + recipient_fields).map { |f| [f["name"], f["description"], Array(f["enum"]).join].join(" ") }.join(" ").downcase
      return true if blob.include?("sbp")

      leaves = recipient_fields.map { |f| f["name"].split(".").last }
      (%w[phone bank_code] - leaves).empty?
    end

    def amount_transform(field)
      return "to_minor_units" if Util.look_like_money_minor?(field)
      if Util.decimal_amount?(field)
        nil
      else
        @warnings << w("amount_unit_unresolved", "Единицы amount не ясны, умножение на 100 не применяем", field["name"])
        nil
      end
    end

    def build_status_map(endpoints)
      values = []
      values.concat(Array(@raw["statuses"]))
      %w[create fetch].each do |role|
        ep = by_role(endpoints, role)
        next unless ep

        success = Array(ep["responses"]).select { |r| (200..299).cover?(r["http_status"].to_i) }
        success.each do |resp|
          status_field = Array(resp["fields"]).find { |f| f["name"].to_s.split(".").last == "status" }
          values.concat(Array(status_field && status_field["enum"]))
          example = resp["example"]
          values << example["status"] if example.is_a?(Hash) && example["status"]
        end
      end

      webhook_ep = by_role(endpoints, "webhook")
      if webhook_ep
        req_fields = Array(webhook_ep.dig("request", "fields"))
        event_field = req_fields.find { |f| %w[event type status].include?(f["name"].to_s.split(".").last) }
        Array(event_field && event_field["enum"]).each do |ev|
          values << ev.to_s.split(".").last
        end
        example = webhook_ep.dig("request", "example")
        values << example["status"] if example.is_a?(Hash) && example["status"]
      end

      map = {}
      values.map(&:to_s).reject(&:empty?).uniq.each do |status|
        mapped = @config.status_overrides[status] || synonym(status)
        if mapped.nil?
          mapped = "in_progress"
          @warnings << w("unknown_status", "Статус #{status} неизвестен, маппим в in_progress", status)
        end
        map[status] = mapped
      end

      @config.status_overrides.each { |k, v| map[k.to_s] = v.to_s }
      map
    end

    def synonym(status)
      key = status.to_s.downcase
      return "in_progress" if STATUS_IN_PROGRESS.include?(key)
      return "approved" if STATUS_APPROVED.include?(key)
      return "rejected" if STATUS_REJECTED.include?(key)

      nil
    end

    def build_error_map(endpoints)
      rows = []
      %w[create fetch].each do |role|
        ep = by_role(endpoints, role)
        next unless ep

        Array(ep["responses"]).each do |resp|
          code = resp["http_status"].to_i
          next unless code >= 400

          internal, action = ERROR_BY_HTTP[code]
          unless internal
            if code >= 500
              internal, action = %w[internal_error retry]
            else
              internal, action = %w[validation_error reject]
            end
          end
          provider_code = provider_error_code(resp) || internal
          rows << {
            "http" => code,
            "provider_code" => provider_code,
            "internal" => internal,
            "action" => action
          }
        end
      end
      rows.uniq { |r| [r["http"], r["provider_code"]] }
    end

    def provider_error_code(resp)
      example = resp["example"]
      if example.is_a?(Hash)
        code = example.dig("error", "code") || example["code"]
        return code if code
      end
      field = Array(resp["fields"]).find { |f| f["name"].to_s.match?(/error\.code|\Acode\z/) }
      enums = field && Array(field["enum"])
      enums&.first
    end

    def build_webhook(ep)
      return nil unless ep

      header, algo_hint = signature_from(ep)
      algo = algo_hint || "HMAC-SHA256"
      unless algo_hint
        @warnings << w("signature_algo_defaulted", "Алгоритм подписи не указан, используем HMAC-SHA256", ep["path"])
      end
      encoding = signature_encoding(ep)
      events = webhook_events(ep)
      id_field = detect_id_field(ep)
      events.each { |ev| ev["id_field"] ||= id_field }

      {
        "path" => ep["path"],
        "header" => header,
        "algorithm" => algo,
        "encoding" => encoding,
        "event_field" => detect_event_field(ep),
        "events" => events
      }
    end

    def signature_from(ep)
      params = Array(ep["parameters"]) + header_fields_from_request(ep)
      param = params.find do |p|
        name = p.is_a?(Hash) ? p["name"].to_s : p.to_s
        name.match?(/signature/i)
      end
      return [nil, nil] unless param

      name = param["name"]
      blob = [param["description"], param.dig("schema", "description")].compact.join(" ")
      algo = blob[/(HMAC-SHA256|SHA256|sha256)/i]
      algo = "HMAC-SHA256" if algo.to_s.casecmp("sha256").zero? || algo.to_s.casecmp("HMAC-SHA256").zero?
      [name, algo]
    end

    def header_fields_from_request(_ep)
      []
    end

    def signature_encoding(ep)
      blob = [ep["description"], *Array(ep["parameters"]).map { |p| p["description"] }].compact.join(" ")
      blob.match?(/base64/i) ? "base64" : "hex"
    end

    def webhook_events(ep)
      fields = Array(ep.dig("request", "fields"))
      event_field = fields.find { |f| %w[event type].include?(f["name"].to_s.split(".").last) }
      enums = Array(event_field && event_field["enum"]).map(&:to_s)
      example = ep.dig("request", "example")
      enums << example["event"].to_s if example.is_a?(Hash) && example["event"]
      enums << example["type"].to_s if example.is_a?(Hash) && example["type"]
      enums = enums.reject(&:empty?).uniq
      if enums.empty?
        [
          { "provider_event" => "completed", "action" => "approve", "id_field" => "id" },
          { "provider_event" => "failed", "action" => "reject", "id_field" => "id" }
        ]
      else
        enums.map do |ev|
          leaf = ev.split(".").last
          action =
            if STATUS_APPROVED.include?(leaf.downcase) || ev.downcase.include?("complet") || ev.downcase.include?("success")
              "approve"
            elsif STATUS_REJECTED.include?(leaf.downcase) || ev.downcase.include?("fail")
              "reject"
            else
              "ignore"
            end
          { "provider_event" => ev, "action" => action, "id_field" => detect_id_field(ep) }
        end
      end
    end

    def detect_event_field(ep)
      fields = Array(ep.dig("request", "fields"))
      found = fields.find { |f| %w[event type].include?(f["name"].to_s.split(".").last) }
      found ? found["name"] : "event"
    end

    def detect_id_field(ep)
      fields = Array(ep.dig("request", "fields"))
      names = fields.map { |f| f["name"].to_s.split(".").last }
      ID_EVENT_FIELDS.find { |cand| names.include?(cand) } || "id"
    end

    def build_conditions(create, field_map)
      return [] unless create

      amount_field = Array(create.dig("request", "fields")).find { |f| AMOUNT_NAMES.include?(f["name"].to_s.split(".").last) }
      return [] unless amount_field && amount_field["minimum"]

      min = amount_field["minimum"].to_f
      row = field_map.find { |f| f["target"] == amount_field["name"] }
      if row && row["transform"] == "to_minor_units" && min >= 100
        min = (min / 100.0)
        min = min.to_i if min == min.to_i
      end
      [{ "field" => "operation.amount", "op" => ">=", "value" => min, "error" => "amount_too_low" }]
    end

    def build_gateway
      gw = @config.gateway || @raw["gateway"]
      unless gw
        @warnings << w("gateway_unresolved", "ProviderGateway не задан в spec/конфиге — в INTEGRATION.md будет TODO")
        return nil
      end
      {
        "external_method" => gw["external_method"] || gw["externalMethod"],
        "gateway" => gw["gateway"]
      }
    end

    def w(code, message, path = nil)
      { "code" => code, "message" => message, "path" => path }
    end
  end
end
