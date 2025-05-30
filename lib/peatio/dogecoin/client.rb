module Peatio
  module Dogecoin
    class Client
      Error = Class.new(StandardError)

      def initialize(endpoint, idle_timeout: 5)
        @endpoint = URI.parse(endpoint)
        @idle_timeout = idle_timeout
        @connection = Faraday.new(url: @endpoint) do |f|
          f.adapter :net_http_persistent, pool_size: 5, idle_timeout: @idle_timeout
        end
      end

      def json_rpc(method, params = [])
        response = connection.post do |req|
          req.url '/'
          req.headers['Accept'] = 'application/json'
          req.headers['Content-Type'] = 'application/json'
          req.headers['Authorization'] = "Basic " + Base64.strict_encode64(@endpoint.user + ":" + @endpoint.password)
          req.body = {jsonrpc: '1.0', method: method, params: params}.to_json
        end

        response.assert_success!
        response = JSON.parse(response.body)

        if response['error'].present?
          raise Error, response['error']
        end

        response.fetch('result')
      rescue StandardError => e
        raise Error, e.message
      end

      private

      attr_reader :connection
    end
  end
end