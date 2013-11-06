require 'eventmachine'

module Nerver
  class Server < EM::Connection
    include Logging
    @@connected_clients = Array.new
    def initialize(nerve)
      @nerve = nerve
      @services = Set.new
    end
    def unbind
      @@connected_clients.delete(self)
      log.info "TCP client disconnected"
      @services.each do |key|
        @nerve.remove_watcher key
      end
    end
    def receive_data(data)
      # Attempt to parse as JSON
      begin
        json = JSON.parse(data)
        @services.merge(@nerve.add_services(json, true))
      rescue JSON::ParserError => e
        # nope!
        log.warn "received malformed data"
        log.debug "Got:", data.to_s
        close_connection
      rescue => e
        log.warn "error on input:", $!.inspect, $@
        log.warn "closing socket"
        close_connection
      end
    end
  end
end
