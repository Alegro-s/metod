# frozen_string_literal: true

require "date"
require "json"
require "yaml"
require "erb"
require "fileutils"
require "pathname"
require "openssl"
require "stringio"
require "tempfile"

require_relative "integrate/error"
require_relative "integrate/util"
require_relative "integrate/config"
require_relative "integrate/parser"
require_relative "integrate/rules"
require_relative "integrate/generator"
require_relative "integrate/cli"

module Integrate
  ROOT = File.expand_path("..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")
  EXAMPLES = File.join(ROOT, "examples")

  def self.parse(spec_path:, provider:, config_path: nil)
    raw = Parser.load(spec_path)
    config = Config.load(spec_path: spec_path, config_path: config_path, provider: provider)
    Rules.apply(raw, provider: provider, config: config)
  end

  def self.parse_text(spec_text:, provider:, config_text: nil, filename: "provider_api.yaml")
    raw = Parser.load_text(spec_text, filename: filename)
    config = Config.from_text(config_text, provider: provider)
    Rules.apply(raw, provider: provider, config: config)
  end

  def self.generate(spec_path:, provider:, output_dir:, config_path: nil, lang: "ruby")
    ir = parse(spec_path: spec_path, provider: provider, config_path: config_path)
    Generator.new(ir, output_dir: output_dir, lang: lang).write!
  end

  def self.generate_from_ir(ir, output_dir:, lang: "ruby")
    Generator.new(ir, output_dir: output_dir, lang: lang).write!
  end
end
