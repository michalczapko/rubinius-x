# All the tasks to manage building the Rubinius kernel--which is essentially
# the Ruby core library plus Rubinius-specific files. The kernel bootstraps
# a Ruby environment to the point that user code can be loaded and executed.
#
# The basic rule is that any generated file should be specified as a file
# task, not hidden inside some arbitrary task. Generated files are created by
# rule (e.g. the rule for compiling a .rb file into a .rbc file) or by a block
# attached to the file task for that particular file.
#
# The only tasks should be those names needed by the user to invoke specific
# parts of the build (including the top-level build task for generating the
# entire kernel).

# drake does not allow invoke to be called inside tasks
def kernel_clean
  rm_rf Dir["**/*.rbc",
           "**/.*.rbc",
           "kernel/**/signature.rb",
           "spec/capi/ext/*.{o,sig,#{$dlext}}",
          ],
    :verbose => $verbose
end

# TODO: Build this functionality into the compiler
class KernelCompiler
  def self.compile(file, output, line, transforms)
    compiler = Rubinius::ToolSet::Build::Compiler.new :file, :compiled_file

    parser = compiler.parser
    parser.root Rubinius::ToolSet::Build::AST::Script

    if transforms.kind_of? Array
      transforms.each { |t| parser.enable_category t }
    else
      parser.enable_category transforms
    end

    parser.input file, line

    generator = compiler.generator
    generator.processor Rubinius::ToolSet::Build::Generator

    writer = compiler.writer
    writer.version = BUILD_CONFIG[:libversion].sub(/\D/, "")
    writer.name = output

    compiler.run
  end
end

# The rule for compiling all kernel Ruby files
rule ".rbc" do |t|
  source = t.prerequisites.first
  puts "RBC #{source}"
  KernelCompiler.compile source, t.name, 1, [:default, :kernel]
end

# Collection of all files in the kernel runtime. Modified by
# various tasks below.
runtime_files = FileList["runtime/platform.conf"]

# Names of subdirectories of the language directories.
dir_names = %w[
  bootstrap
  platform
  common
  delta
]

# Generate file tasks for all kernel and load_order files.
def file_task(re, runtime_files, signature, rb, rbc)
  rbc ||= ((rb.sub(re, "runtime") if re) || rb) + "c"

  file rbc => [rb, signature]
  runtime_files << rbc
end

def kernel_file_task(runtime_files, signature, rb, rbc=nil)
  file_task(/^kernel/, runtime_files, signature, rb, rbc)
end

# Generate a digest of the Rubinius runtime files
signature_file = "kernel/signature.rb"

bootstrap_files = FileList[
  "library/rbconfig.rb",
  "library/rubinius/build_config.rb",
]

runtime_gems_dir = BUILD_CONFIG[:runtime_gems_dir]
bootstrap_gems_dir = BUILD_CONFIG[:bootstrap_gems_dir]

ffi_files = FileList[
  "#{bootstrap_gems_dir}/**/*.ffi"
].each { |f| f.gsub!(/.ffi\z/, '') }

runtime_gem_files = FileList[
  "#{runtime_gems_dir}/**/*.rb"
].exclude("#{runtime_gems_dir}/**/spec/**/*.rb",
          "#{runtime_gems_dir}/**/test/**/*.rb")

bootstrap_gem_files = FileList[
  "#{bootstrap_gems_dir}/**/*.rb"
].exclude("#{bootstrap_gems_dir}/**/spec/**/*.rb",
          "#{bootstrap_gems_dir}/**/test/**/*.rb")

ext_files = FileList[
  "#{bootstrap_gems_dir}/**/*.{c,h}pp",
  "#{bootstrap_gems_dir}/**/grammar.y",
  "#{bootstrap_gems_dir}/**/lex.c.*"
]

kernel_files = FileList[
  "kernel/**/*.txt",
  "kernel/**/*.rb"
].exclude(signature_file)

config_files = FileList[
  "Rakefile",
  "config.rb",
  "rakelib/*.rb",
  "rakelib/*.rake"
]

signature_files = kernel_files + config_files + runtime_gem_files + ext_files - ffi_files

file signature_file => signature_files do
  require 'digest/sha1'
  digest = Digest::SHA1.new

  signature_files.each do |name|
    File.open name, "r" do |file|
      while chunk = file.read(1024)
        digest << chunk
      end
    end
  end

  # Collapse the digest to a 64bit quantity
  hd = digest.hexdigest
  SIGNATURE_HASH = hd[0, 16].to_i(16) ^ hd[16,16].to_i(16) ^ hd[32,8].to_i(16)

  File.open signature_file, "wb" do |file|
    file.puts "# This file is generated by rakelib/kernel.rake. The signature"
    file.puts "# is used to ensure that the runtime files and VM are in sync."
    file.puts "#"
    file.puts "Rubinius::Signature = #{SIGNATURE_HASH}"
  end
end

signature_header = "vm/gen/signature.h"

file signature_header => signature_file do |t|
  File.open t.name, "wb" do |file|
    file.puts "#define RBX_SIGNATURE          #{SIGNATURE_HASH}ULL"
  end
end

# Index files for loading a particular version of the kernel.
directory(runtime_base_dir = "runtime")
runtime_files << runtime_base_dir

runtime_index = "#{runtime_base_dir}/index"
runtime_files << runtime_index

file runtime_index => runtime_base_dir do |t|
  File.open t.name, "wb" do |file|
    file.puts dir_names
  end
end

signature = "runtime/signature"
file signature => signature_file do |t|
  File.open t.name, "wb" do |file|
    puts "GEN #{t.name}"
    file.puts Rubinius::Signature
  end
end
runtime_files << signature

# All the kernel files
dir_names.each do |dir|
  directory(runtime_dir = "runtime/#{dir}")
  runtime_files << runtime_dir

  load_order = "runtime/#{dir}/load_order.txt"
  runtime_files << load_order

  kernel_load_order = "kernel/#{dir}/load_order.txt"

  file load_order => [kernel_load_order, signature] do |t|
    cp t.prerequisites.first, t.name, :verbose => $verbose
  end

  kernel_dir  = "kernel/#{dir}/"
  runtime_dir = "runtime/#{dir}/"

  IO.foreach kernel_load_order do |name|
    rbc = runtime_dir + name.chomp!
    rb  = kernel_dir + name.chop
    kernel_file_task runtime_files, signature_file, rb, rbc
  end
end

[ signature_file,
  "kernel/alpha.rb",
  "kernel/loader.rb",
  "kernel/delta/converter_paths.rb"
].each do |name|
  kernel_file_task runtime_files, signature_file, name
end

# Build the bootstrap files
bootstrap_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

# Build the gem files
runtime_gem_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

# Build the bootstrap gem files
bootstrap_gem_files.each do |name|
  file_task nil, runtime_files, signature_file, name, nil
end

namespace :compiler do

  task :load => ['compiler:generate'] do
    require "rubinius/bridge"
    require "rubinius/toolset"

    Rubinius::ToolSet.start
    require "rubinius/melbourne"
    require "rubinius/processor"
    require "rubinius/compiler"
    require "rubinius/ast"
    Rubinius::ToolSet.finish :build

    require File.expand_path("../../kernel/signature", __FILE__)
  end

  task :generate => [signature_file]
end

desc "Build all kernel files (alias for kernel:build)"
task :kernel => 'kernel:build'

namespace :kernel do
  desc "Build all kernel files"
  task :build => ['compiler:load'] + runtime_files

  desc "Delete all .rbc files"
  task :clean do
    kernel_clean
  end
end