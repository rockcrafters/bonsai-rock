#!/usr/bin/env ruby
# frozen_string_literal: true
#
# inject-layers.rb -- insert each gguf shard as its own oci layer, *just below*
# the topmost (app content) layer of an oci-layout image.
#
# the shards come from hack/split-model.sh (real gguf-split output, so llama.cpp
# loads the whole set when pointed at shard 1 -- nothing reassembles them at
# runtime). one layer per shard gives parallel blob downloads and keeps the
# model layers stable across app rebuilds.
#
# why direct oci surgery and not `umoci raw add-layer`: umoci only appends layers
# on TOP. we want the model layers BELOW the app layer, which means editing the
# manifest + config layer/diff_id ordering by hand. skopeo still does the
# oci-archive <-> oci-layout transport in inject.sh; this script is pure surgery.
#
# ruby rather than shell because this is the one piece with real logic: splicing
# json arrays and tracking digests. stdlib only (json/digest/zlib), so no jq and
# no gems.
#
# usage: inject-layers.rb <oci-layout-dir> <ref-tag> <shard-dir> <dest-dir-in-image>
#   e.g. inject-layers.rb build/oci bonsai ../../.cache/shards usr/share/bonsai

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'zlib'

MEDIA_TYPE = 'application/vnd.oci.image.layer.v1.tar+gzip'

def die(msg)
  warn(msg)
  exit 1
end

# GNU tar (the linux build box) gets reproducibility flags; bsdtar (macos dev)
# falls back to a plain tar -- fine for validation, the rock is built on linux.
def gnu_tar?(tar)
  `#{tar} --version 2>/dev/null`.downcase.include?('gnu tar')
rescue StandardError
  false
end

def tar_dir(tar, dir, out)
  args = [tar]
  args += ['--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner'] if gnu_tar?(tar)
  args += ['-cf', out, '-C', dir, '.']
  system(*args) || die("tar failed for #{dir}")
end

# deterministic gzip: no original filename, no timestamp (as `gzip -n`)
def gzip_file(src, dst)
  File.open(dst, 'wb') do |out|
    gz = Zlib::GzipWriter.new(out)
    gz.mtime = 0
    File.open(src, 'rb') { |input| IO.copy_stream(input, gz) }
    gz.close
  end
end

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def read_json(path)
  JSON.parse(File.read(path))
end

# write compact json and return [digest, size]
def write_blob(blobs, obj)
  body = JSON.generate(obj)
  digest = Digest::SHA256.hexdigest(body)
  File.binwrite(File.join(blobs, digest), body)
  [digest, body.bytesize]
end

oci_dir, tag, shard_dir, dest = ARGV
die('usage: inject-layers.rb <oci-layout-dir> <ref-tag> <shard-dir> <dest-dir-in-image>') if
  oci_dir.nil? || tag.nil? || shard_dir.nil?
dest ||= 'usr/share/bonsai'

blobs = File.join(oci_dir, 'blobs', 'sha256')
die("not an oci layout: #{oci_dir}") unless File.directory?(blobs)

shards = Dir.glob(File.join(shard_dir, '*.gguf')).sort
die("no .gguf shards in #{shard_dir}") if shards.empty?
puts ">> #{shards.length} shards from #{shard_dir}"

# --- resolve current manifest + config from the oci layout -------------------
index = read_json(File.join(oci_dir, 'index.json'))
manifest_digest = index['manifests'][0]['digest'].sub(/^sha256:/, '')
manifest_path = File.join(blobs, manifest_digest)
manifest = read_json(manifest_path)

config_digest = manifest['config']['digest'].sub(/^sha256:/, '')
config_path = File.join(blobs, config_digest)
config = read_json(config_path)

layers = manifest['layers']
diff_ids = config['rootfs']['diff_ids']
history = config['history'] || []

tar = ENV['TARBIN'] || 'tar'

# --- build one layer per shard ----------------------------------------------
Dir.mktmpdir('bonsai-inject') do |work|
  shards.each_with_index do |shard, i|
    name = File.basename(shard)
    stage = File.join(work, format('stage%02d', i + 1))
    FileUtils.mkdir_p(File.join(stage, dest))
    FileUtils.cp(shard, File.join(stage, dest, name))

    raw = File.join(work, format('layer%02d.tar', i + 1))
    tar_dir(tar, stage, raw)
    diff_id = sha256(raw)          # diff_id = sha256(uncompressed tar)

    gz = "#{raw}.gz"
    gzip_file(raw, gz)
    digest = sha256(gz)            # blob digest = sha256(gzip)
    size = File.size(gz)

    FileUtils.cp(gz, File.join(blobs, digest))   # store the blob
    puts format('>> %s: diffid=%s digest=%s size=%d', name, diff_id[0, 12], digest[0, 12], size)

    # splice this shard BEFORE the last element (the app content layer)
    layers.insert(-2, { 'mediaType' => MEDIA_TYPE, 'digest' => "sha256:#{digest}", 'size' => size })
    diff_ids.insert(-2, "sha256:#{diff_id}")
    history.insert(-2, { 'created_by' => "bonsai model shard #{name}",
                         'comment' => 'injected by inject-layers.rb' })
  end
end

# --- write updated config blob ----------------------------------------------
config['rootfs']['diff_ids'] = diff_ids
config['history'] = history
new_config_digest, new_config_size = write_blob(blobs, config)

# --- write updated manifest blob (new layers + new config ref) --------------
manifest['layers'] = layers
manifest['config']['digest'] = "sha256:#{new_config_digest}"
manifest['config']['size'] = new_config_size
new_manifest_digest, new_manifest_size = write_blob(blobs, manifest)

# --- point index.json at the new manifest -----------------------------------
index['manifests'][0]['digest'] = "sha256:#{new_manifest_digest}"
index['manifests'][0]['size'] = new_manifest_size
File.write(File.join(oci_dir, 'index.json'), JSON.generate(index))

puts ">> done. new manifest sha256:#{new_manifest_digest[0, 12]}, ref=#{tag}"
puts ">> layer order now: [<base layers>] [#{shards.length}x model shard] [app content]"
