module Tenzura
  # Implementation for Ravencoin-based blockchains like Tenzura
  class Blockchain < Peatio::Blockchain::Abstract

    DEFAULT_FEATURES = {
      case_sensitive: true,
      cash_addr_format: false,
      witness_type: false,
      supports_assets: true
    }.freeze

    def initialize(custom_features = {})
      @features = DEFAULT_FEATURES.merge(custom_features).slice(*SUPPORTED_FEATURES)
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))

      @wallet = @settings.fetch(:wallet) do
        raise Peatio::Blockchain::MissingSettingError, :wallet
      end.slice(:uri, :address)

      @currency = @settings.fetch(:currency) do
        raise Peatio::Blockchain::MissingSettingError, :currency
      end.slice(:id, :base_factor, :options)
    end

    def fetch_block!(block_number)
      block_hash = client.json_rpc(:getblockhash, [block_number])
      block = client.json_rpc(:getblock, [block_hash, 2])
      process_block(block)
    rescue Tenzura::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    def fetch_block_by_hash!(block_hash)
      block = client.json_rpc(:getblock, [block_hash, 2])
      process_block(block)
    rescue Tenzura::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    def latest_block_number
      client.json_rpc(:getblockcount)
    rescue Tenzura::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    def load_balance_of_address!(address, _currency_id)
      if @currency.dig(:options, :asset_name).present?
        asset_name = @currency.dig(:options, :asset_name)
        balances = client.json_rpc(:listassetbalancesbyaddress, [address])
        if balances.key?(asset_name)
          balances[asset_name].to_d
        else
          0.to_d
        end
      else
        # For native coin
        address_with_balance = client.json_rpc(:listaddressgroupings)
                                     .flatten(1)
                                     .select { |addr| addr[0] == address }
        
        if address_with_balance.blank?
          0.to_d
        else
          address_with_balance.sum { |addr| addr[1].to_d }
        end
      end
    rescue Tenzura::Client::Error => e
      raise Peatio::Blockchain::ClientError, e
    end

    private

    def process_block(block_data)
      block_number = block_data.fetch('height')
      block_hash = block_data.fetch('hash')
      timestamp = block_data.fetch('time')
      transactions = []

      block_data.fetch('tx').each do |tx|
        if @currency.dig(:options, :asset_name).present?
          # Process asset transactions for Ravencoin-based chains
          parse_asset_tx(tx, block_number, transactions)
        else
          # Process regular transactions
          parse_tx(tx, block_number, transactions)
        end
      end

      Peatio::Block.new(
        block_number,
        block_hash,
        timestamp,
        transactions
      )
    end

    def parse_tx(tx, block_number, transactions)
      tx_id = tx.fetch('txid')
      tx_hash = tx.fetch('hash')

      # Parse outputs for receiving transactions
      tx.fetch('vout').each_with_index do |vout, txout|
        next unless vout.fetch('scriptPubKey').has_key?('addresses')
        
        vout.fetch('scriptPubKey').fetch('addresses').each do |address|
          next unless valid_address?(address)
          transaction = build_transaction(tx_id, txout, 'receive', address, vout.fetch('value'), block_number)
          transactions << transaction
        end
      end

      # Parse inputs for sending transactions
      tx.fetch('vin').each_with_index do |vin, index|
        next if vin.has_key?('coinbase')
        next unless vin.has_key?('txid')
        
        # Need to request raw tx for input details
        prev_tx = client.json_rpc(:getrawtransaction, [vin.fetch('txid'), true]) rescue nil
        next if prev_tx.blank?

        prev_vout = prev_tx.fetch('vout')[vin.fetch('vout')] rescue nil
        next if prev_vout.blank?
        next unless prev_vout.fetch('scriptPubKey').has_key?('addresses')

        prev_vout.fetch('scriptPubKey').fetch('addresses').each do |address|
          next unless valid_address?(address)
          transaction = build_transaction(tx_id, vin.fetch('vout'), 'send', address, prev_vout.fetch('value'), block_number)
          transactions << transaction
        end
      end
    end

    def parse_asset_tx(tx, block_number, transactions)
      asset_name = @currency.dig(:options, :asset_name)
      tx_hash = tx.fetch('txid')

      # For Ravencoin forks, we need to check for asset operations
      tx_details = client.json_rpc(:getrawtransaction, [tx_hash, true]) rescue nil
      return if tx_details.blank?
      
      tx_details['vout'].each_with_index do |v, idx|
        # Skip if not an asset transaction for our asset
        next unless v['scriptPubKey'].present? && 
                  v['scriptPubKey']['asset'].present? &&
                  v['scriptPubKey']['asset']['name'] == asset_name
        
        # Found our asset transfer
        amount = v['scriptPubKey']['asset']['amount'].to_d
        
        # Get destination address
        to_address = v['scriptPubKey']['addresses'].first if v['scriptPubKey']['addresses'].present?
        
        # Skip if no valid destination
        next if to_address.blank?
        
        # Create transaction record
        transaction = Peatio::Transaction.new(
          hash: tx_hash,
          txout: idx,
          amount: amount,
          to_address: to_address,
          block_number: block_number,
          status: :success,
          currency_id: @currency.fetch(:id)
        )
        
        transactions << transaction
      end
    end

    def build_transaction(tx_hash, txout, type, address, amount, block_number)
      Peatio::Transaction.new(
        hash: tx_hash,
        txout: txout,
        to_address: type == 'receive' ? address : nil,
        amount: amount,
        block_number: block_number,
        currency_id: @currency.fetch(:id),
        from_address: type == 'send' ? address : nil,
        status: :success
      )
    end

    def client
      @client ||= Client.new(@wallet.fetch(:uri))
    end

    def valid_address?(address)
      address.to_s.match?(/\A[A-Za-z0-9]{26,35}\z/)
    end
  end
end