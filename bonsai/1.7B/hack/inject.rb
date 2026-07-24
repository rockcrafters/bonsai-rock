#!/usr/bin/env ruby
# frozen_string_literal: true
# inject model shards into a base rock

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'zlib'

HERE  = File.expand_path('..', __dir__)
REPO  = File.expand_path('../..', HERE)
CACHE = File.join(REPO, '.cache')

DEST       = 'usr/share/bonsai'
DOC_DEST   = 'usr/share/doc/bonsai-1.7B'
PREFIX     = ENV['SHARD_PREFIX'] || 'model'
NSHARDS    = (ENV['NSHARDS'] || '4').to_i
MAXSIZE    = ENV['SPLIT_MAX_SIZE'] || '62M' # 62M = ~4 balanced shards (67/61/60/58M)
IMG_TAG    = 'bonsai'
MEDIA_TYPE = 'application/vnd.oci.image.layer.v1.tar+gzip'

def die(msg)
  warn(msg)
  exit 1
end

def run(*args, env: {})
  system(env, *args) || die("command failed: #{args.join(' ')}")
end

def in_path?(bin)
  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) }
end

def skopeo
  @skopeo ||= ENV['SKOPEO'] || (in_path?('rockcraft.skopeo') ? 'rockcraft.skopeo' : 'skopeo')
end

# model -> shards

# pin the splitter to the exact llama.cpp the rock builds, so the shard format
# can never drift from the server that reads it.
def source_tag
  line = File.readlines(File.join(HERE, 'rockcraft.yaml')).grep(/^\s*source-tag:/).first
  tag = line&.slice(/\bb\d+/)
  tag || die('could not read source-tag from rockcraft.yaml')
end

def host_asset
  os = `uname -s`.strip
  cpu = `uname -m`.strip
  case "#{os}:#{cpu}"
  when 'Linux:x86_64'  then 'ubuntu-x64'
  when 'Linux:aarch64' then 'ubuntu-arm64'
  when 'Darwin:arm64'  then 'macos-arm64'
  when 'Darwin:x86_64' then 'macos-x64'
  else die("no llama.cpp release asset for #{os}/#{cpu}")
  end
end

# download + cache the pinned llama-gguf-split; return its path.
def splitter(tag)
  tools = File.join(CACHE, 'tools', "#{tag}-#{host_asset}")
  found = Dir.glob(File.join(tools, '**', 'llama-gguf-split')).first
  return found if found

  tarball = "llama-#{tag}-bin-#{host_asset}.tar.gz"
  url = "https://github.com/ggml-org/llama.cpp/releases/download/#{tag}/#{tarball}"
  warn "fetching #{tarball}..."
  FileUtils.mkdir_p(tools)
  dest = File.join(tools, tarball)
  run('curl', '-fL', '--retry', '3', '-o', dest, url)
  run('tar', '-xzf', dest, '-C', tools)
  File.delete(dest)
  Dir.glob(File.join(tools, '**', 'llama-gguf-split')).first ||
    die("llama-gguf-split not found in #{tarball}")
end

# download-model.rb fetches the gguf + its licence/NOTICE; it echoes the path.
def model_path
  script = File.join(__dir__, 'download-model.rb')
  path = IO.popen([script], &:read).strip
  die('download-model.rb failed') unless $?.success? && File.file?(path)
  path
end

def shard_paths(dir)
  (1..NSHARDS).map { |i| File.join(dir, format('%s-%05d-of-%05d.gguf', PREFIX, i, NSHARDS)) }
end

def copy_docs(shards)
  docs = File.join(CACHE, 'model-docs')
  return unless File.directory?(docs)

  Dir.glob(File.join(docs, '*')).each { |f| FileUtils.cp(f, shards) if File.file?(f) }
end

# (re)produce the shards under .cache/shards. always re-splits: the split is
# cheap (the slow bits -- the gguf and the splitter -- are cached separately),
# and re-splitting can never ship a stale set from an earlier tag/config.
def ensure_shards
  tag = source_tag
  shards = File.join(CACHE, 'shards')
  split_bin = splitter(tag)
  model = ENV['MODEL'] || model_path
  die("model not found: #{model}") unless File.file?(model)

  FileUtils.rm_rf(shards)
  FileUtils.mkdir_p(shards)
  warn "splitting #{model} (max #{MAXSIZE} per shard)..."
  libdir = File.dirname(split_bin)
  env = {
    'LD_LIBRARY_PATH' => [libdir, ENV['LD_LIBRARY_PATH']].compact.join(':'),
    'DYLD_LIBRARY_PATH' => [libdir, ENV['DYLD_LIBRARY_PATH']].compact.join(':')
  }
  run(split_bin, '--split', '--split-max-size', MAXSIZE, model, File.join(shards, PREFIX), env: env)

  # the service command names shard 1 of N literally, so a different count would
  # silently ship a broken command -- fail loudly instead.
  got = Dir.glob(File.join(shards, "#{PREFIX}-*.gguf")).length
  die("expected #{NSHARDS} shards, got #{got} -- adjust SPLIT_MAX_SIZE or NSHARDS") if got != NSHARDS
  shard_paths(shards).all? { |f| File.file?(f) } ||
    die("shard naming is not #{PREFIX}-00001-of-#{format('%05d', NSHARDS)}.gguf")

  copy_docs(shards)
  warn "wrote #{got} shards to #{shards}"
  shards
end

# --- 2/4. skopeo transport ---------------------------------------------------

def rock_to_oci(rock, oci_dir)
  FileUtils.rm_rf(oci_dir)
  FileUtils.mkdir_p(oci_dir)          # skopeo oci: transport needs the parent to exist
  run(skopeo, 'copy', "oci-archive:#{rock}", "oci:#{oci_dir}:#{IMG_TAG}")
end

def oci_to_rock(oci_dir, out)
  File.delete(out) if File.exist?(out)
  run(skopeo, 'copy', "oci:#{oci_dir}:#{IMG_TAG}", "oci-archive:#{out}:#{IMG_TAG}")
end

# --- 3. the oci surgery ------------------------------------------------------

def gnu_tar?(tar)
  `#{tar} --version 2>/dev/null`.downcase.include?('gnu tar')
rescue StandardError
  false
end

# deterministic tar of a staged tree; GNU tar (the linux build box) gets repro
# flags, bsdtar (macos dev) falls back to plain tar.
def tar_dir(tar, dir, out)
  args = [tar]
  args += ['--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner'] if gnu_tar?(tar)
  args += ['-cf', out, '-C', dir, '.']
  run(*args)
end

def gzip_file(src, dst)
  File.open(dst, 'wb') do |out|
    gz = Zlib::GzipWriter.new(out)
    gz.mtime = 0                      # no timestamp -> reproducible (as `gzip -n`)
    File.open(src, 'rb') { |input| IO.copy_stream(input, gz) }
    gz.close
  end
end

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def write_blob(blobs, obj)
  body = JSON.generate(obj)
  digest = Digest::SHA256.hexdigest(body)
  File.binwrite(File.join(blobs, digest), body)
  [digest, body.bytesize]
end

def inject_layers(oci_dir, shard_dir)
  blobs = File.join(oci_dir, 'blobs', 'sha256')
  die("not an oci layout: #{oci_dir}") unless File.directory?(blobs)

  shards = Dir.glob(File.join(shard_dir, '*.gguf')).sort
  die("no .gguf shards in #{shard_dir}") if shards.empty?
  extras = (Dir.glob(File.join(shard_dir, '*')) - shards).select { |f| File.file?(f) }.sort

  # each shard is its own layer (parallel blob downloads); the docs share one,
  # under DOC_DEST rather than beside the weights.
  groups = shards.map { |s| { files: [s], dest: DEST, label: File.basename(s) } }
  groups << { files: extras, dest: DOC_DEST, label: 'licence + provenance' } unless extras.empty?
  warn ">> #{shards.length} shards + #{extras.length} licence/provenance files"

  index = JSON.parse(File.read(File.join(oci_dir, 'index.json')))
  manifest_path = File.join(blobs, index['manifests'][0]['digest'].sub(/^sha256:/, ''))
  manifest = JSON.parse(File.read(manifest_path))
  config_path = File.join(blobs, manifest['config']['digest'].sub(/^sha256:/, ''))
  config = JSON.parse(File.read(config_path))

  layers = manifest['layers']
  diff_ids = config['rootfs']['diff_ids']
  history = config['history'] || []
  tar = ENV['TARBIN'] || 'tar'

  Dir.mktmpdir('bonsai-inject') do |work|
    groups.each_with_index do |group, i|
      stage = File.join(work, format('stage%02d', i + 1))
      FileUtils.mkdir_p(File.join(stage, group[:dest]))
      group[:files].each { |f| FileUtils.cp(f, File.join(stage, group[:dest], File.basename(f))) }

      raw = File.join(work, format('layer%02d.tar', i + 1))
      tar_dir(tar, stage, raw)
      diff_id = sha256(raw)                    # diff_id = sha256(uncompressed tar)

      gz = "#{raw}.gz"
      gzip_file(raw, gz)
      digest = sha256(gz)                      # blob digest = sha256(gzip)
      size = File.size(gz)
      FileUtils.cp(gz, File.join(blobs, digest))
      warn format('>> %s: diffid=%s digest=%s size=%d', group[:label], diff_id[0, 12], digest[0, 12], size)

      # splice BEFORE the last element (the app content layer)
      layers.insert(-2, { 'mediaType' => MEDIA_TYPE, 'digest' => "sha256:#{digest}", 'size' => size })
      diff_ids.insert(-2, "sha256:#{diff_id}")
      history.insert(-2, { 'created_by' => "bonsai model: #{group[:label]}",
                           'comment' => 'injected by inject.rb' })
    end
  end

  config['rootfs']['diff_ids'] = diff_ids
  config['history'] = history
  new_config_digest, new_config_size = write_blob(blobs, config)

  manifest['layers'] = layers
  manifest['config']['digest'] = "sha256:#{new_config_digest}"
  manifest['config']['size'] = new_config_size
  new_manifest_digest, new_manifest_size = write_blob(blobs, manifest)

  index['manifests'][0]['digest'] = "sha256:#{new_manifest_digest}"
  index['manifests'][0]['size'] = new_manifest_size
  File.write(File.join(oci_dir, 'index.json'), JSON.generate(index))

  warn ">> layer order now: [<base layers>] [#{groups.length}x model] [app content]"
end

# --- main --------------------------------------------------------------------
# guarded so the file can be `require`d (e.g. by the test harness, which drives
# inject_layers against a synthetic oci layout) without running the pipeline.

if $PROGRAM_NAME == __FILE__
  die('usage: inject.rb <base-rock> [<out-rock>]') if ARGV[0].nil?
  rock = File.expand_path(ARGV[0])   # resolve against the invocation cwd first
  out  = ARGV[1] || 'bonsai_1.7B.rock'
  Dir.chdir(HERE)   # build/, rockcraft.yaml, the default out are all relative to here

  puts '== 1/4 fetch + split model =='
  shard_dir = ensure_shards

  puts '== 2/4 rock -> oci layout =='
  rock_to_oci(rock, 'build/oci')

  puts '== 3/4 inject model shard layers =='
  inject_layers('build/oci', shard_dir)

  puts "== 4/4 oci layout -> oci-archive (#{out}) =="
  oci_to_rock('build/oci', out)

  puts "\ndone -> #{out}"
end
