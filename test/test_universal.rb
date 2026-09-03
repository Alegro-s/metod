# frozen_string_literal: true

require_relative "test_helper"

class TestPayflow < Minitest::Test
  include TestSupport

  def setup
    @ir, @result, @dir = generate_tmp("payflow")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def test_bearer_and_roles
    assert_equal "bearer", @ir.dig("auth", "type")
    roles = @ir["endpoints"].map { |ep| [ep["path"], ep["role"]] }.to_h
    assert_equal "create", roles["/transfers"]
    assert_equal "fetch", roles["/transfers/{transferId}"]
    assert_equal "webhook", roles["/hooks/transfer"]
  end

  def test_no_minor_units_on_decimal
    amount = @ir["field_map"].find { |f| f["target"] == "value" }
    assert amount
    refute_equal "to_minor_units", amount["transform"]
  end

  def test_status_synonyms
    assert_equal "in_progress", @ir["status_map"]["queued"]
    assert_equal "approved", @ir["status_map"]["ok"]
    assert_equal "rejected", @ir["status_map"]["error"]
  end

  def test_service_uses_bearer
    assert @result.syntax_ok, @result.syntax_error
    source = File.read(File.join(@dir, "payflow_service.rb"))
    assert_match(/Bearer/, source)
    assert_match(/\/transfers/, source)
    refute_match(/\* 100/, source)
  end
end

class TestWalletFlat < Minitest::Test
  include TestSupport

  def setup
    @ir, @result, @dir = generate_tmp("wallet")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def test_flat_format
    assert_equal "flat", @ir["format"]
    roles = @ir["endpoints"].map { |ep| [ep["path"], ep["role"]] }.to_h
    assert_equal "create", roles["/out"]
    assert_equal "fetch", roles["/out/{id}"]
    assert_equal "webhook", roles["/notify"]
  end

  def test_status_from_flat_table
    assert_equal "in_progress", @ir["status_map"]["created"]
    assert_equal "approved", @ir["status_map"]["paid"]
    assert_equal "rejected", @ir["status_map"]["declined"]
  end

  def test_syntax
    assert @result.syntax_ok, @result.syntax_error
  end
end

class TestErrors < Minitest::Test
  include TestSupport

  def test_unknown_format
    error = assert_raises(Integrate::ParseError) do
      Integrate.parse_text(spec_text: "foo: 1\n", provider: "x")
    end
    assert_match(/Неизвестный формат/, error.message)
  end

  def test_broken_yaml
    error = assert_raises(Integrate::ParseError) do
      Integrate.parse_text(spec_text: ":\n  -", provider: "x")
    end
    assert_match(/YAML сломан/, error.message)
  end
end
