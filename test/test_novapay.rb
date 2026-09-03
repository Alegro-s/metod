# frozen_string_literal: true

require_relative "test_helper"

class TestNovapay < Minitest::Test
  include TestSupport

  def setup
    @ir, @result, @dir = generate_tmp("novapay")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def test_parse_format_and_auth
    assert_equal "openapi", @ir["format"]
    assert_equal "api_key", @ir.dig("auth", "type")
    assert_equal "X-API-Key", @ir.dig("auth", "name")
  end

  def test_roles
    roles = @ir["endpoints"].to_h { |ep| [ep["path"], ep["role"]] }
    assert_equal "create", roles["/payouts"]
    assert_equal "fetch", roles["/payouts/{id}"]
    assert_equal "cancel", roles["/payouts/{id}/cancel"]
    assert_equal "webhook", roles["/webhooks/payout"]
    assert_equal "unknown", roles["/balance"]
  end

  def test_unknown_balance_warning
    assert @ir["warnings"].any? { |w| w["code"] == "unmapped_endpoint" && w["path"] == "/balance" }
  end

  def test_status_and_errors
    assert_equal "in_progress", @ir["status_map"]["pending"]
    assert_equal "approved", @ir["status_map"]["completed"]
    assert_equal "rejected", @ir["status_map"]["failed"]
    codes = @ir["error_map"].map { |r| r["http"] }
    assert_includes codes, 429
    assert_includes codes, 401
  end

  def test_field_map_minor_units_and_sbp
    amount = @ir["field_map"].find { |f| f["target"] == "amount" }
    assert_equal "to_minor_units", amount["transform"]
    phone = @ir["field_map"].find { |f| f["target"] == "recipient.phone" }
    assert_equal "operation.payout_requisite.sbp.phone", phone["source"]
    currency = @ir["field_map"].find { |f| f["target"] == "currency" }
    assert_equal "literal:RUB", currency["source"]
  end

  def test_conditions_use_major_units
    cond = @ir["conditions"].first
    assert_equal 1000, cond["value"]
  end

  def test_webhook
    assert_equal "X-NovaPay-Signature", @ir.dig("webhook", "header")
    assert_equal "HMAC-SHA256", @ir.dig("webhook", "algorithm")
    events = @ir.dig("webhook", "events").map { |e| e["provider_event"] }
    assert_includes events, "payout.completed"
    assert_includes events, "payout.failed"
  end

  def test_gateway_from_extension
    assert_equal "RUB_SBP_WITHDRAW", @ir.dig("gateway", "gateway")
  end

  def test_generated_service_syntax_and_contract
    assert @result.syntax_ok, @result.syntax_error
    assert_empty @result.missing_methods
    source = File.read(File.join(@dir, "novapay_service.rb"))
    assert_match(/class NovapayService < BaseService/, source)
    assert_match(/NOVAPAY_BASE_URL/, source)
    assert_match(/\(operation\.amount \* 100\)\.to_i/, source)
    assert_match(/operation\.payout_requisite\.dig\('sbp', 'phone'\)/, source)
    assert_match(/Idempotency-Key/, source)
    assert_match(/X-NovaPay-Signature/, source)
    assert_match(/payout\.completed/, source)
    refute_match(/def get_balance/, source)
  end

  def test_integration_md_sections
    md = File.read(File.join(@dir, "INTEGRATION.md"))
    %w[Авторизация Методы Маппинг статусов Обработка ошибок ProviderGateway Webhook].each do |h|
      assert_includes md, h
    end
    assert_includes md, "X-API-Key"
    assert_includes md, "RUB_SBP_WITHDRAW"
  end

  def test_fixtures_scenarios
    fx = JSON.parse(File.read(File.join(@dir, "fixtures.json")))
    assert fx.dig("create_request", "request", "amount")
    assert fx.dig("create_request", "response_201")
    assert fx.dig("create_request", "response_422")
    assert fx.dig("fetch_status", "response_200")
    assert_equal "approved", fx.dig("callback", "expected_operation_status")
    assert_equal "rejected", fx.dig("callback_failed", "expected_operation_status")
  end
end
