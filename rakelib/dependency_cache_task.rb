# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright (c) 2014 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'java_buildpack/logging/logger_factory'
require 'java_buildpack/repository/version_resolver'
require 'java_buildpack/util/configuration_utils'
require 'java_buildpack/util/cache/download_cache'
require 'java_buildpack/util/snake_case'
require 'rake/tasklib'
require 'rakelib/package'
require 'pathname'
require 'yaml'

module Package

  class DependencyCacheTask < Rake::TaskLib
    include Package

    def initialize
      return unless BUILDPACK_VERSION.offline

      JavaBuildpack::Logging::LoggerFactory.instance.setup "#{BUILD_DIR}/"

      @default_repository_root = default_repository_root
      @cache                   = cache

      configurations = component_ids.map { |component_id| configurations(configuration(component_id)) }.flatten
      uris(configurations).each { |uri| multitask PACKAGE_NAME => [cache_task(uri)] }
    end

    private

    ARCHITECTURE_PATTERN = /\{architecture\}/.freeze

    DEFAULT_REPOSITORY_ROOT_PATTERN = /\{default.repository.root\}/.freeze

    PLATFORM_PATTERN = /\{platform\}/.freeze

    private_constant :ARCHITECTURE_PATTERN, :DEFAULT_REPOSITORY_ROOT_PATTERN, :PLATFORM_PATTERN

    def augment(raw, key, pattern, candidates, &block)
      if raw.respond_to? :at
        raw.map(&block)
      else
        if raw[:uri] =~ pattern
          candidates.map do |candidate|
            dup       = raw.clone
            dup[key]  = candidate
            dup[:uri] = raw[:uri].gsub pattern, candidate

            dup
          end
        else
          raw
        end
      end
    end

    def augment_architecture(raw)
      augment(raw, :architecture, ARCHITECTURE_PATTERN, ARCHITECTURES) { |r| augment_architecture r }
    end

    def augment_path(raw)
      if raw.respond_to? :at
        raw.map { |r| augment_path r }
      else
        raw[:uri] = "#{raw[:uri].chomp('/')}/index.yml"
        raw
      end
    end

    def augment_platform(raw)
      augment(raw, :platform, PLATFORM_PATTERN, PLATFORMS) { |r| augment_platform r }
    end

    def augment_repository_root(raw)
      augment(raw, :repository_root, DEFAULT_REPOSITORY_ROOT_PATTERN, [@default_repository_root]) { |r| augment_repository_root r }
    end

    def cache
      JavaBuildpack::Util::Cache::DownloadCache.new(Pathname.new("#{STAGING_DIR}/resources/cache")).freeze
    end

    def cache_task(uri)
      task uri do |t|
        rake_output_message "Caching #{t.name}"
        cache.get(t.name) {}
      end

      uri
    end

    def component_ids
      configuration('components').values.flatten.map { |component| component.split('::').last.snake_case }
    end

    def configuration(id)
      JavaBuildpack::Util::ConfigurationUtils.load id, false
    end

    def configurations(configuration)
      configurations = []

      if repository_configuration?(configuration)
        configurations << configuration
      else
        configuration.values.each { |v| configurations << configurations(v) if v.is_a? Hash }
      end

      configurations
    end

    def default_repository_root
      configuration('repository')['default_repository_root'].chomp('/')
    end

    def index_configuration(configuration)
      [configuration['repository_root']]
      .map { |r| { uri: r } }
      .map { |r| augment_repository_root r }
      .map { |r| augment_platform r }
      .map { |r| augment_architecture r }
      .map { |r| augment_path r }.flatten
    end

    def repository_configuration?(configuration)
      configuration['version'] && configuration['repository_root']
    end

    def uris(configurations)
      uris = []

      configurations.each do |configuration|
        index_configuration(configuration).each do |index_configuration|
          multitask PACKAGE_NAME => [cache_task(index_configuration[:uri])]

          @cache.get(index_configuration[:uri]) do |f|
            index         = YAML.load f
            found_version = version(configuration, index)
            rake_output_message "Unable to resolve version '#{configuration['version']}' for platform '#{index_configuration[:platform]}'" if found_version.nil?
            uris << index[found_version.to_s] unless found_version.nil?
          end
        end
      end

      uris
    end

    def version(configuration, index)
      JavaBuildpack::Repository::VersionResolver.resolve(JavaBuildpack::Util::TokenizedVersion.new(configuration['version']), index.keys)
    end

  end

end
