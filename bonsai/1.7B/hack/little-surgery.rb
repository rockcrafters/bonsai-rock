#!/usr/bin/env ruby
# frozen_string_literal: true
# inject model shards into a base rock, one oci layer per shard

require 'fileutils'
require 'tmpdir'

HERE  = File.expand_path('..', __dir__)
REPO  = File.expand_path('../..', HERE)
CACHE = File.join(REPO, '.cache')

DEST       = 'usr/share/bonsai'
DOC_DEST   = 'usr/share/doc/bonsai-1.7B'
PREFIX     = ENV['SHARD_PREFIX'] || 'model'
NSHARDS    = (ENV['NSHARDS'] || '4').to_i
MAXSIZE    = ENV['SPLIT_MAX_SIZE'] || '62M' # 62M = ~4 balanced shards (67/61/60/58M)
IMG_TAG    = 'bonsai'
SNAP_UMOCI = '/snap/rockcraft/current/bin/umoci'

def run(*args, env: {})
  system(env, *args) || abort("command failed: #{args.join(' ')}")
end

def in_path?(bin)
  ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) }
end

def skopeo
  @skopeo ||= ENV['SKOPEO'] || (in_path?('rockcraft.skopeo') ? 'rockcraft.skopeo' : 'skopeo')
end

# the rockcraft snap bundles a static umoci but exposes no app for it, hence the
# snap-path fallback.
def umoci
  @umoci ||= ENV['UMOCI'] ||
             (in_path?('umoci') && 'umoci') ||
             (File.executable?(SNAP_UMOCI) && SNAP_UMOCI) ||
             abort('umoci not found -- `apt install umoci`, or set UMOCI=<path>')
end

# --- 1. model -> shards ------------------------------------------------------

HOST_ASSETS = { 'x86_64' => 'ubuntu-x64', 'aarch64' => 'ubuntu-arm64' }.freeze

def host_asset
  arch = `uname -m`.strip
  @host_asset ||= HOST_ASSETS[arch] || abort("no llama.cpp release asset for linux/#{arch}")
end

# pin the splitter to the exact llama.cpp the rock builds, so the shard format
# can never drift from the server that reads it.
def source_tag
  File.read(File.join(HERE, 'rockcraft.yaml'))[/^\s*source-tag:.*?\b(b\d+)/, 1] ||
    abort('could not read source-tag from rockcraft.yaml')
end

def splitter(tag)
  tools = File.join(CACHE, 'tools', "#{tag}-#{host_asset}")
  found = Dir.glob(File.join(tools, '**', 'llama-gguf-split')).first
  return found if found

  tarball = "llama-#{tag}-bin-#{host_asset}.tar.gz"
  warn "fetching #{tarball}..."
  FileUtils.mkdir_p(tools)
  dest = File.join(tools, tarball)
  run('curl', '-fL', '--retry', '3', '-o', dest,
      "https://github.com/ggml-org/llama.cpp/releases/download/#{tag}/#{tarball}")
  run('tar', '-xzf', dest, '-C', tools)
  File.delete(dest)
  Dir.glob(File.join(tools, '**', 'llama-gguf-split')).first ||
    abort("llama-gguf-split not found in #{tarball}")
end

# download-model.rb also leaves the licence and NOTICE in .cache/model-docs,
# which the doc layer below picks up.
def model_path
  script = File.join(__dir__, 'download-model.rb')
  path = IO.popen([script], &:read).strip
  abort('download-model.rb failed') unless $?.success? && File.file?(path)
  path
end

# always re-splits: it is cheap next to the cached gguf and splitter, and can
# then never ship a stale set from an earlier tag or shard config.
def ensure_shards
  split_bin = splitter(source_tag)
  model = ENV['MODEL'] || model_path
  abort("model not found: #{model}") unless File.file?(model)

  shards = File.join(CACHE, 'shards')
  FileUtils.rm_rf(shards)
  FileUtils.mkdir_p(shards)
  warn "splitting #{model} (max #{MAXSIZE} per shard)..."
  libdir = File.dirname(split_bin)
  run(split_bin, '--split', '--split-max-size', MAXSIZE, model, File.join(shards, PREFIX),
      env: { 'LD_LIBRARY_PATH' => [libdir, ENV['LD_LIBRARY_PATH']].compact.join(':') })

  # the service command names shard 1 of N literally, so a different count or
  # naming would silently ship a broken command -- fail loudly instead.
  want = (1..NSHARDS).map { |i| File.join(shards, format('%s-%05d-of-%05d.gguf', PREFIX, i, NSHARDS)) }
  got = Dir.glob(File.join(shards, "#{PREFIX}-*.gguf"))
  unless got.length == NSHARDS && want.all? { |f| File.file?(f) }
    abort("expected #{NSHARDS} shards named like #{File.basename(want.first)}, got #{got.length} " \
          '-- adjust SPLIT_MAX_SIZE or NSHARDS')
  end

  Dir.glob(File.join(CACHE, 'model-docs', '*')).each { |f| FileUtils.cp(f, shards) if File.file?(f) }
  warn "wrote #{got.length} shards to #{shards}"
  shards
end

# --- 2. shards -> oci layers -------------------------------------------------

# GNU tar reproducibility flags: same tree in, same digest out.
def tar_dir(dir, out)
  run('tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner',
      '-cf', out, '-C', dir, '.')
end

def inject_layers(oci_dir, shard_dir)
  shards = Dir.glob(File.join(shard_dir, '*.gguf')).sort
  abort("no .gguf shards in #{shard_dir}") if shards.empty?
  extras = (Dir.glob(File.join(shard_dir, '*')) - shards).select { |f| File.file?(f) }.sort

  # one layer per shard, so the blobs download in parallel; docs share one.
  groups = shards.map { |s| [File.basename(s), DEST, [s]] }
  groups << ['licence + provenance', DOC_DEST, extras] unless extras.empty?
  warn ">> #{shards.length} shards + #{extras.length} licence/provenance files"

  Dir.mktmpdir('bonsai-inject') do |work|
    groups.each_with_index do |(label, dest, files), i|
      stage = File.join(work, format('stage%02d', i + 1))
      FileUtils.mkdir_p(File.join(stage, dest))
      files.each { |f| FileUtils.cp(f, File.join(stage, dest, File.basename(f))) }

      tar = File.join(work, format('layer%02d.tar', i + 1))
      tar_dir(stage, tar)

      # umoci appends, so these land on top of rockcraft's own layers. harmless:
      # oci blobs are content-addressed, so position does not affect reuse.
      run(umoci, 'raw', 'add-layer', '--image', "#{oci_dir}:#{IMG_TAG}", tar,
          '--history.created_by', "bonsai model: #{label}",
          '--history.comment', 'injected by little-surgery.rb')
      warn ">> added layer: #{label}"
    end
  end

  warn ">> appended #{groups.length} layers"
end

# --- main --------------------------------------------------------------------
# guarded so the file can be `require`d to drive inject_layers against a
# synthetic oci layout, without running the pipeline.

if $PROGRAM_NAME == __FILE__
  abort('linux only: needs GNU tar and umoci') unless RUBY_PLATFORM.include?('linux')
  abort('usage: little-surgery.rb <base-rock> [<out-rock>]') if ARGV[0].nil?
  rock = File.expand_path(ARGV[0])   # resolve against the invocation cwd first
  out  = ARGV[1] || 'bonsai_1.7B.rock'
  Dir.chdir(HERE)   # build/, rockcraft.yaml, the default out are all relative to here

  puts '== 1/4 fetch + split model =='
  shard_dir = ensure_shards

  puts '== 2/4 rock -> oci layout =='
  FileUtils.rm_rf('build/oci')
  FileUtils.mkdir_p('build/oci')   # skopeo's oci: transport needs the parent to exist
  run(skopeo, 'copy', "oci-archive:#{rock}", "oci:build/oci:#{IMG_TAG}")

  puts '== 3/4 inject model shard layers =='
  inject_layers('build/oci', shard_dir)

  puts "== 4/4 oci layout -> oci-archive (#{out}) =="
  File.delete(out) if File.exist?(out)
  run(skopeo, 'copy', "oci:build/oci:#{IMG_TAG}", "oci-archive:#{out}:#{IMG_TAG}")

  puts "\ndone -> #{out}"
end
