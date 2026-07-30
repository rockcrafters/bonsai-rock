#!/usr/bin/env ruby
# frozen_string_literal: true
# download + verify the bonsai gguf into .cache/; echoes its path on stdout

require 'digest'
require 'fileutils'

REPO       = File.expand_path('../../..', __dir__)
MODEL_REPO = ENV['MODEL_REPO'] || 'prism-ml/Bonsai-1.7B-gguf'
MODEL_FILE = ENV['MODEL_FILE'] || 'Bonsai-1.7B-Q1_0.gguf'
# huggingface's LFS oid for the gguf -- read it off the repo's file listing when
# bumping the model.
EXPECT_SHA256 = ENV['EXPECT_SHA256'] ||
                '3d7c6c90dd98717a203adb22d5eacd2581850e40aa5327e144b97766cae5f7e3'
CACHE = File.join(REPO, '.cache')
DEST  = File.join(CACHE, MODEL_FILE)
DOCS  = File.join(CACHE, 'model-docs')

def resolve_url(file)
  "https://huggingface.co/#{MODEL_REPO}/resolve/main/#{file}"
end

def curl(url, dest)
  system('curl', '-fL', '--retry', '3', '-o', dest, url) || abort("download failed: #{url}")
end

def verified?(path)
  File.file?(path) && Digest::SHA256.file(path).hexdigest == EXPECT_SHA256
end

def fetch_docs
  FileUtils.mkdir_p(DOCS)
  %w[LICENSE NOTICE.txt].each do |f|
    dst = File.join(DOCS, f)
    next if File.file?(dst) && !File.zero?(dst) # zero-length == an earlier curl failed

    warn "fetching model #{f}..."
    curl(resolve_url(f), dst)
  end
  File.write(File.join(DOCS, 'PROVENANCE'), <<~PROV)
    bonsai-1.7B model provenance

    source:  https://huggingface.co/#{MODEL_REPO}
    file:    #{MODEL_FILE}
    size:    #{File.size(DEST)} bytes
    sha256:  #{EXPECT_SHA256}
    license: Apache-2.0 (see LICENSE and NOTICE.txt beside this file)

    the weights are shipped as gguf-split shards, one oci layer each.
  PROV
end

if verified?(DEST)
  warn "reusing cached model: #{DEST}"
else
  FileUtils.mkdir_p(CACHE)
  warn "downloading #{MODEL_FILE} (sha256 #{EXPECT_SHA256[0, 12]}...)..."
  curl("#{resolve_url(MODEL_FILE)}?download=true", "#{DEST}.part")
  File.rename("#{DEST}.part", DEST)
  unless verified?(DEST)
    abort("sha256 mismatch: got #{Digest::SHA256.file(DEST).hexdigest}, want #{EXPECT_SHA256}")
  end
  warn "downloaded: #{DEST}"
end

fetch_docs
puts DEST
