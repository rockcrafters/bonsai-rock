#!/usr/bin/env ruby
# frozen_string_literal: true
#
# download-model.rb -- ensure the bonsai gguf is present under the repo's
# .cache/ and print its path on stdout. idempotent: reuses an existing copy (in
# .cache/ or at the repo root) when the byte size matches; only hits the network
# when nothing local is usable. diagnostics go to stderr so stdout stays a bare
# path (callable as `model = IO.popen(['download-model.rb'], &:read).strip`).
#
# the model is Apache-2.0: section 4 requires the licence and the NOTICE be
# redistributed with the weights, so they are fetched alongside into
# .cache/model-docs (with a PROVENANCE note), and inject.rb ships them.

require 'digest'
require 'fileutils'

REPO       = File.expand_path('../../..', __dir__)
MODEL_REPO = ENV['MODEL_REPO'] || 'prism-ml/Bonsai-1.7B-gguf'
MODEL_FILE = ENV['MODEL_FILE'] || 'Bonsai-1.7B-Q1_0.gguf'
EXPECT_SIZE = (ENV['EXPECT_SIZE'] || '248302272').to_i   # bytes of the original gguf
CACHE = File.join(REPO, '.cache')
DEST  = File.join(CACHE, MODEL_FILE)
DOCS  = File.join(CACHE, 'model-docs')

def die(msg)
  warn(msg)
  exit 1
end

def resolve_url(file)
  "https://huggingface.co/#{MODEL_REPO}/resolve/main/#{file}"
end

def curl(url, dest)
  system('curl', '-fL', '--retry', '3', '-o', dest, url) || die("download failed: #{url}")
end

def right_size?(path)
  File.file?(path) && File.size(path) == EXPECT_SIZE
end

# fetch the licence + notice and write a provenance note. no timestamps, so the
# build stays reproducible.
def fetch_docs
  FileUtils.mkdir_p(DOCS)
  %w[LICENSE NOTICE.txt].each do |f|
    dst = File.join(DOCS, f)
    next if File.file?(dst) && !File.zero?(dst)

    warn "fetching model #{f}..."
    curl(resolve_url(f), dst)
  end
  File.write(File.join(DOCS, 'PROVENANCE'), <<~PROV)
    bonsai-1.7B model provenance

    source:  https://huggingface.co/#{MODEL_REPO}
    file:    #{MODEL_FILE}
    size:    #{File.size(DEST)} bytes
    sha256:  #{Digest::SHA256.file(DEST).hexdigest}
    license: Apache-2.0 (see LICENSE and NOTICE.txt beside this file)

    the weights are shipped as gguf-split shards, one oci layer each.
  PROV
end

# already cached at the right size -> done
if right_size?(DEST)
  warn "reusing cached model: #{DEST}"
  fetch_docs
  puts DEST
  exit 0
end

FileUtils.mkdir_p(CACHE)

# a good copy sitting at the repo root (the dev-box layout) -> link it in
root_copy = File.join(REPO, MODEL_FILE)
if right_size?(root_copy)
  warn "linking model from repo root: #{root_copy}"
  begin
    FileUtils.ln(root_copy, DEST, force: true)
  rescue StandardError
    FileUtils.cp(root_copy, DEST)
  end
  fetch_docs
  puts DEST
  exit 0
end

warn "downloading #{MODEL_FILE} from huggingface (#{EXPECT_SIZE} bytes)..."
curl("#{resolve_url(MODEL_FILE)}?download=true", "#{DEST}.part")
File.rename("#{DEST}.part", DEST)
die("size mismatch: got #{File.size(DEST)}, expected #{EXPECT_SIZE}") unless right_size?(DEST)

fetch_docs
warn "downloaded: #{DEST}"
puts DEST
