module Peatio
  module Tenzura
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
        # Create a Tenzura address via RPC
        client.json_rpc(:getnewaddress)
              .yield_self { |address| { address: address, secret: nil } }
      rescue Peatio::Tenzura::Client::Error => e
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
          # For Tenzura (Ravencoin fork) - check if it's an asset transfer
          if @currency.dig(:options, :asset_name).present?
            # Handle asset transfer if needed
            asset_name = @currency.dig(:options, :asset_name)
            
            Rails.logger.info { "Sending Tenzura asset #{asset_name} to #{destination_address}" }
            txid = client.json_rpc(:transfer,
                                 [asset_name,    # Asset name
                                  amount.to_f,   # Amount
                                  destination_address])
          else
            # Standard coin transfer for native TENZ
            Rails.logger.info { "Sending Tenzura (TENZ) to #{destination_address}" }
            txid = client.json_rpc(:sendtoaddress,
                                 [destination_address,
                                  amount.to_f,
                                  "",  # comment
                                  "",  # comment_to
                                  false])  # subtract fee from amount
          end
        rescue Peatio::Tenzura::Client::Error => e
          handle_send_error(e, transaction, destination_address)
        end

        transaction.hash = txid
        transaction.amount = amount
        transaction.status = :pending
        transaction
      end

      def load_balance!
        if @currency.dig(:options, :asset_name).present?
          # For Tenzura asset
          asset_name = @currency.dig(:options, :asset_name)
          
          # Get asset balance
          balances = client.json_rpc(:listassetbalancesbyaddress, [@wallet.fetch(:address)])
          
          # Find the specific asset balance
          if balances.key?(asset_name)
            return balances[asset_name].to_d
          else
            return 0.to_d
          end
        else
          # For native TENZ
          client.json_rpc(:getbalance).to_d
        end
      rescue Peatio::Tenzura::Client::Error => e
        raise Peatio::Wallet::ClientError, e
      end

      private

      def normalize_address(address)
        address
      end

      def native_currency_id
        'tzr' # Use the ticker symbol for Tenzura
      end

      def client_from_settings
        @client = Peatio::Tenzura::Client.new(
          @wallet.fetch(:uri),
          idle_timeout: 5
        )
      end

      def fee(transaction)
        # Default fee is 0.001 TZR (adjust based on Tenzura's requirements)
        fee_amount = if @currency.dig(:options, :fee_amount).present?
                       @currency.dig(:options, :fee_amount).to_d
                     elsif @wallet.dig(:settings, :fee_amount).present?
                       @wallet.dig(:settings, :fee_amount).to_d
                     else
                       0.001.to_d  # Default fee for Tenzura
                     end
        fee_amount
      end

      def handle_send_error(e, transaction, destination_address)
        Rails.logger.error { "Tenzura send error: #{e.inspect}" }
        
        case e.message
        when /Insufficient funds/
          Rails.logger.error { "Insufficient funds in Tenzura wallet" }
          raise Peatio::Wallet::InsufficientFunds, e.message
        when /Invalid address/
          Rails.logger.error { "Invalid Tenzura address: #{destination_address}" }
          raise Peatio::Wallet::ClientError, "Invalid address: #{destination_address}"
        else
          raise Peatio::Wallet::ClientError, "Error sending Tenzura to #{destination_address}: #{e.message}"
        end
      end
    end
  end
end