module Peatio
  module Dogecoin
    class Wallet < Peatio::Wallet::Abstract

      DEFAULT_FEATURES = { skip_deposit_collection: false }.freeze

      def initialize(settings = {})
        @settings = settings
        @client = client_from_settings
      end

      def configure(settings = {})
        # Configure wallet with given settings.
        @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))

        @wallet = @settings.fetch(:wallet) do
          raise Peatio::Wallet::MissingSettingError, :wallet
        end.slice(:uri, :address, :secret)

        @currency = @settings.fetch(:currency) do
          raise Peatio::Wallet::MissingSettingError, :currency
        end.slice(:id, :base_factor, :options)
      end

      def create_address!(options = {})
        # Create a Dogecoin address via RPC
        client.json_rpc(:getnewaddress)
              .yield_self { |address| { address: address, secret: nil } }
      rescue Peatio::Dogecoin::Client::Error => e
        raise Peatio::Wallet::ClientError, e
      end

      def create_transaction!(transaction, options = {})
        currency_id = @currency.fetch(:id)
        tx_options = transaction.options.deep_symbolize_keys
        options.merge!(tx_options.slice(:subtract_fee))

        amount = transaction.amount.to_d

        # If subtract fees enabled, deduct fees from amount
        if options.dig(:subtract_fee)
          amount = amount - fee(transaction)
          # Prevent negative amount
          amount = 0 if amount < 0
        end

        destination_address = normalize_address(transaction.to_address)
        
        begin
          txid = client.json_rpc(:sendtoaddress,
                               [destination_address,
                                amount.to_f,
                                "",  # comment
                                "",  # comment_to
                                false])  # subtract fee from amount
        rescue Peatio::Dogecoin::Client::Error => e
          handle_send_error(e, transaction, destination_address)
        end

        transaction.hash = txid
        transaction.amount = amount
        transaction.status = :pending
        transaction
      end

      def load_balance!
        client.json_rpc(:getbalance).to_d
      rescue Peatio::Dogecoin::Client::Error => e
        raise Peatio::Wallet::ClientError, e
      end

      private

      def normalize_address(address)
        address
      end

      def native_currency_id
        'doge'
      end

      def client_from_settings
        @client = Peatio::Dogecoin::Client.new(
          @wallet.fetch(:uri),
          idle_timeout: 5
        )
      end

      def fee(transaction)
        # Default fee is 1 DOGE
        # Can be customized in currency options or wallet settings
        fee_amount = if @currency.dig(:options, :fee_amount).present?
                       @currency.dig(:options, :fee_amount).to_d
                     elsif @wallet.dig(:setting, :fee_amount).present?
                       @wallet.dig(:setting, :fee_amount).to_d
                     else
                       1.to_d
                     end
        fee_amount
      end

      def handle_send_error(e, transaction, destination_address)
        Rails.logger.error { "Dogecoin send error: #{e.inspect}" }
        
        case e.message
        when /Insufficient funds/
          Rails.logger.error { "Insufficient funds in Dogecoin wallet" }
          raise Peatio::Wallet::InsufficientFunds, e.message
        else
          raise Peatio::Wallet::ClientError, "Error sending Dogecoin to #{destination_address}: #{e.message}"
        end
      end
    end
  end
end