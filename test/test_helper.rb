# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "integrate"

module TestSupport
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")

  def example(name)
    File.join(EXAMPLES, "#{name}.yaml")
  end

  def generate_tmp(name)
    dir = Dir.mktmpdir("integrate-test")
    ir = Integrate.parse(spec_path: example(name), provider: name)
    result = Integrate.generate_from_ir(ir, output_dir: dir)
    [ir, result, dir]
  end
end
