require 'logger'
require 'json'
require 'timeout'
require 'digest/sha1'
require 'set'

require 'nerve/version'
require 'nerve/utils'
require 'nerve/log'
require 'nerve/ring_buffer'
require 'nerve/reporter'
require 'nerve/service_watcher'
require 'nerve/server.rb'

module Nerve
  class Nerve
    include Logging

    def initialize(opts={})
      log.info 'nerve: starting up!'

      # required options
      log.debug 'nerve: checking for required inputs'
      %w{instance_id services}.each do |required|
        raise ArgumentError, "you need to specify required argument #{required}" unless opts[required]
      end

      @instance_id = opts['instance_id']

      # create service watcher objects
      log.debug 'nerve: creating service watchers'
      @service_watchers={}
      add_services(opts)

      @ephemeral_service_watchers={}

      @port = opts['listen_port'] || 1025
      @port = @port.to_i

      @expiry = opts['ephemeral_service_expiry'] || 60
      @expiry = @expiry.to_i

      log.debug 'nerve: completed init'
    end

    def run
      log.info 'nerve: starting run'
      begin
        log.debug 'nerve: initializing service checks'
        @service_watchers.each do |name,watcher|
          watcher.init
        end

        log.debug 'nerve: main initialization done'

        EventMachine.run do
          EM.add_periodic_timer(0.5) {
            @service_watchers.each do |name,watcher|
              next if watcher.expires and Time.now.to_i > watcher.expires_at
              watcher.run
            end
          }
          log.info "nerve: listening on port #{@port} for services"
          EventMachine.start_server("127.0.0.1", @port, Server, self)
        end

        @service_watchers.each do |name,watcher|
          watcher.close!
        end
      rescue => e
        $stdout.puts $!.inspect, $@
        $stderr.puts $!.inspect, $@
      ensure
        EventMachine.stop
      end
      log.info 'nerve: exiting'
    end

    def add_watcher(key, params, ephemeral)
      if @service_watchers.has_key? key
        if @service_watchers[key].sha1 != sha1
          # We found a service watcher with the same key already, but it has
          # a different configuration.  We'll remove the old one first, and
          # replace it wih the new one.
          # TODO(brenden): Consider having a policy for whether to permit
          # ephemeral services to replace static ones?
          log.info "replacing existing service watcher for #{key} with a new one"
          remove_watcher(key)
        elsif ephemeral
          @service_watchers[key].expires_at = Time.now.to_i + @expiry
        end
      end

      if not @service_watchers.has_key? key
        begin
          log.info "adding new#{ephmeral ? ' ephemeral ' : ' '}service watcher for #{key}"
          s = ServiceWatcher.new(params)
          s.expires = ephemeral
          s.expires_at = Time.now.to_i + @expiry
          s.init
          @service_watchers[key] = s
        rescue ArgumentError => e
          log.info e
        end
      end
    end

    def remove_watcher(key)
      if @service_watchers.has_key? key
      log.info "removing service watcher for #{key} because it has expired"
      @service_watchers[key].close!
      @service_watchers.delete key
      else
        log.warn "can't remove service watcher for #{key} because it's not present"
      end
    end

    def add_services(json, ephemeral=false)
      return nil unless json.has_key? 'services'
      services = Set.new
      json['services'].each do |name,params|
        sha1 = Digest::SHA1.hexdigest params.to_s
        params = params.merge({'instance_id' => @instance_id, 'name' => name, 'sha1' => sha1})
        port = params['port']
        key = "#{name}_#{params['port']}"

        add_watcher(key, params, ephemeral)
        services.add(key)
      end
      services.to_a
    end
  end
end
