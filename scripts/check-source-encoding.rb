#!/usr/bin/env ruby
# frozen_string_literal: true

# Reject source files that are valid UTF-8 but visibly mojibaked because UTF-8
# text was decoded as GB18030 and then saved again. Swift compiles those strings,
# so this must run before packaging rather than relying on the compiler.

root = File.expand_path("..", __dir__)
files = Dir.glob(File.join(root, "Sources", "**", "*.swift"))
errors = []

# These characters are exceptionally unlikely in this product's Chinese copy,
# but are common results of interpreting UTF-8 bytes as GB18030.
mojibake = /[璇鍙淇鎵褰妗绯鍊欏閫锛銆鈥€掳卤]/

files.each do |file|
  bytes = File.binread(file)
  errors << "#{file}: UTF-8 BOM is not allowed" if bytes.start_with?("\xEF\xBB\xBF".b)

  text = bytes.force_encoding(Encoding::UTF_8)
  unless text.valid_encoding?
    errors << "#{file}: invalid UTF-8"
    next
  end

  text.each_line.with_index(1) do |line, number|
    errors << "#{file}:#{number}: probable UTF-8/GB18030 mojibake" if line.match?(mojibake)
  end
end

if errors.empty?
  puts "Source encoding check passed (#{files.length} Swift files)."
  exit 0
end

warn errors.join("\n")
exit 1
