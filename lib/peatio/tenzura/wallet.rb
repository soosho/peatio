module Tenzura
  class Wallet < Peatio::Wallet::Abstract

    DEFAULT_FEATURES = { skip_deposit_collection: false }.freeze

    def initialize(custom_features = {})
      @features = DEFAULT_FEATURES.merge(custom_features).slice(*SUPPORTED_FEATURES)
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))

      @wallet = @settings.fetch(:wallet) do
        raise Peatio::Wallet::MissingSettingError, :wallet
      end.slice(:uri, :address)

      @currency = @settings.fetch(:currency) do
        raise Peatio::Wallet::MissingSettingError, :currency
      end.slice(:id, :base_factor, :options)
    end

    def create_address!(_options = {})
      { address: client.json_rpc(:getnewaddress) }
    rescue Tenzura::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def create_transaction!(transaction, options = {})
      currency_id = @currency.fetch(:id)
      if @currency.dig(:options, :asset_name).present?
        # Asset transfer for Ravencoin-based assets
        asset_name = @currency.dig(:options, :asset_name)
        txid = client.json_rpc(:transfer,
                             [
                               asset_name,
                               transaction.amount.to_f,
                               transaction.to_address
                             ])
      else
        # Standard coin transfer
        txid = client.json_rpc(:sendtoaddress,
                             [
                               transaction.to_address,
                               transaction.amount,
                               '', # comment
                               '', # comment_to
                               options[:subtract_fee].to_s == 'true' # subtract fee from amount
                             ])
      end
      transaction.hash = txid
      transaction
    rescue Tenzura::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def load_balance!
      if @currency.dig(:options, :asset_name).present?
        # For Ravencoin-like assets
        asset_name = @currency.dig(:options, :asset_name)
        balances = client.json_rpc(:listassetbalancesbyaddress, [@wallet.fetch(:address)])
        if balances.key?(asset_name)
          return balances[asset_name].to_d
        else
          return 0.to_d
        end
      else
        # For native coin
        client.json_rpc(:getbalance).to_d
      end
    rescue Tenzura::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    private

    def client
      uri = @wallet.fetch(:uri) { raise Peatio::Wallet::MissingSettingError, :uri }
      @client ||= Client.new(uri, idle_timeout: 1)
    end
  end
end