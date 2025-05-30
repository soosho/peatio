module Tenzura
  class Client
    Error = Class.new(StandardError)

    class ConnectionError < Error; end

    class ResponseError < Error
      def initialize(code, msg)
        @code = code
        @msg = msg
        super("#{msg} (#{code})")
      end

      attr_reader :code
      attr_reader :msg
    end

    extend Memoist

    def initialize(endpoint, idle_timeout: 5)
      @endpoint = URI.parse(endpoint)
      @idle_timeout = idle_timeout
    end

    def json_rpc(method, params = [])
      request = { jsonrpc: '1.0', method: method, params: params }.to_json
      
      response = connection.post do |req|
        req.url '/'
        req.headers['Accept'] = 'application/json'
        req.headers['Content-Type'] = 'application/json'
        req.headers['Authorization'] = "Basic " + Base64.strict_encode64(@endpoint.user + ":" + @endpoint.password)
        req.body = request
      end

      response = JSON.parse(response.body)
      
      if response['error']
        raise ResponseError.new(response['error']['code'], response['error']['message'])
      end

      response.fetch('result')
    rescue Faraday::Error => e
      raise ConnectionError, e
    rescue StandardError => e
      raise Error, e
    end

    private

    def connection
      @connection ||= Faraday.new(url: @endpoint) do |f|
        f.adapter :net_http_persistent, pool_size: 5, idle_timeout: @idle_timeout
      end
    end
  end
  memoize :connection
end