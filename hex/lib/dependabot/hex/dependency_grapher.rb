# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/dependency_graphers"
require "dependabot/dependency_graphers/base"
require "dependabot/hex/file_parser"
require "dependabot/shared_helpers"

module Dependabot
  module Hex
    class DependencyGrapher < Dependabot::DependencyGraphers::Base
      extend T::Sig

      GraphEntry = T.type_alias do
        T::Hash[String, T.any(String, T::Boolean, T::Array[String])]
      end

      sig { override.returns(Dependabot::DependencyFile) }
      def relevant_dependency_file
        lockfile || T.must(mixfile)
      end

      sig { override.returns(T::Hash[String, Dependabot::DependencyGraphers::ResolvedDependency]) }
      def resolved_dependencies
        graph_data.to_h do |entry|
          purl = T.cast(entry.fetch("purl"), String)
          dependencies = T.cast(entry.fetch("dependencies"), T::Array[String])

          [purl, Dependabot::DependencyGraphers::ResolvedDependency.new(
            package_url: purl,
            direct: T.cast(entry.fetch("direct"), T::Boolean),
            runtime: T.cast(entry.fetch("runtime"), T::Boolean),
            dependencies: dependencies
          )]
        end
      end

      sig { override.params(dependency: Dependabot::Dependency).returns(String) }
      def purl_pkg_for(_dependency)
        "hex"
      end

      sig { override.params(dependency: Dependabot::Dependency).returns(T::Array[String]) }
      def fetch_subdependencies(dependency)
        entry = graph_data.find { |candidate| candidate["purl"] == build_purl(dependency) }
        return [] unless entry

        T.cast(entry.fetch("dependencies"), T::Array[String]).map do |purl|
          purl.delete_prefix("pkg:hex/").split("@", 2).first
        end
      end

      private

      sig { returns(T::Array[GraphEntry]) }
      def graph_data
        @graph_data ||= T.let(fetch_graph_data, T.nilable(T::Array[GraphEntry]))
      end

      sig { returns(T::Array[GraphEntry]) }
      def fetch_graph_data
        SharedHelpers.in_a_temporary_directory do
          write_sanitized_mixfiles
          File.write("mix.lock", T.must(lockfile).content) if lockfile

          SharedHelpers.run_helper_subprocess(
            env: {
              "MIX_BUILD_PATH" => File.join(NativeHelpers.hex_helpers_dir, "_build"),
              "MIX_DEPS_PATH" => File.join(NativeHelpers.hex_helpers_dir, "deps"),
              "MIX_EXS" => File.join(NativeHelpers.hex_helpers_dir, "dependency_grapher_mix.exs"),
              "MIX_QUIET" => "1"
            },
            command: "mix run #{elixir_helper_path}",
            function: "dependency_graph",
            args: [Dir.pwd]
          )
        end
      end

      sig { void }
      def write_sanitized_mixfiles
        hex_parser = T.cast(file_parser, Dependabot::Hex::FileParser)
        hex_parser.send(:mixfiles).each do |file|
          path = file.name
          FileUtils.mkdir_p(Pathname.new(path).dirname)
          File.write(path, hex_parser.send(:sanitize_mixfile, T.must(file.content)))
        end
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def lockfile
        @lockfile ||= T.let(
          dependency_files.find { |f| f.name == "mix.lock" },
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(T.nilable(Dependabot::DependencyFile)) }
      def mixfile
        @mixfile ||= T.let(
          dependency_files.find { |f| f.name.end_with?("mix.exs") },
          T.nilable(Dependabot::DependencyFile)
        )
      end

      sig { returns(String) }
      def elixir_helper_path
        File.join(NativeHelpers.hex_helpers_dir, "lib/run.exs")
      end
    end
  end
end

Dependabot::DependencyGraphers.register("hex", Dependabot::Hex::DependencyGrapher)
