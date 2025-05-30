module Peatio
  module Tenzura
    class Blockchain < Peatio::Blockchain::Abstract

      DEFAULT_FEATURES = {
        case_sensitive: true,
        cash_addr_format: false,
        witness_type: false,
        supports_assets: true  # Specific to Ravencoin-based chains
      }.freeze

      def initialize(custom_features = {})
        @features = DEFAULT_FEATURES.merge(custom_features)
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
      rescue Client::Error => e
        raise Peatio::Blockchain::ClientError, e
      end

      def fetch_block_by_hash!(block_hash)
        block = client.json_rpc(:getblock, [block_hash, 2])
        process_block(block)
      rescue Client::Error => e
        raise Peatio::Blockchain::ClientError, e
      end

      def latest_block_number
        client.json_rpc(:getblockcount)
      rescue Client::Error => e
        raise Peatio::Blockchain::ClientError, e
      end

      def load_balance_of_address!(address, currency_id)
        if @currency.dig(:options, :asset_name).present?
          # Get balance of specific asset for this address
          asset_name = @currency.dig(:options, :asset_name)
          
          # Query asset balances for this address
          balances = client.json_rpc(:listassetbalancesbyaddress, [address])
          
          # Find the specific asset balance
          if balances.key?(asset_name)
            return balances[asset_name].to_d
          else
            return 0.to_d
          end
        else
          # For native TZR, use the same approach as Bitcoin forks
          address_with_balance = client.json_rpc(:listaddressgroupings)
                                       .flatten(1)
                                       .select { |addr| addr[0] == address }

          if address_with_balance.empty?
            0.to_d
          else
            address_with_balance.map { |addr| addr[1].to_d }.sum
          end
        end
      rescue Client::Error => e
        raise Peatio::Blockchain::ClientError, e
      end

      private

      def process_block(block)
        # This is a Tenzura version of block processing
        block_hash = block.fetch('hash')
        block_txs = block.fetch('tx')
        block_time = block.fetch('time')
        block_number = block.fetch('height')
        
        transactions = []
        block_txs.each do |tx|
          # Handle both normal and asset transactions
          if @currency.dig(:options, :asset_name).present?
            # For Tenzura assets, we need to look for asset transfer operations
            process_asset_transaction(tx, block_number, transactions)
          else
            # For native TZR coin, use the standard Bitcoin-like processing
            process_coin_transaction(tx, block_number, transactions)
          end
        end
        
        Peatio::Block.new(
          number: block_number,
          hash: block_hash,
          time: Time.at(block_time).to_datetime,
          transactions: transactions
        )
      end
      
      def process_coin_transaction(tx, block_number, transactions)
        tx_hash = tx.fetch('txid')
        
        # Process outputs (vout)
        tx['vout'].each_with_index do |v, idx|
          next if v.fetch('value').to_d <= 0.0
          next if v['scriptPubKey'].blank? || v['scriptPubKey']['addresses'].blank?
          
          v['scriptPubKey']['addresses'].each do |address|
            transaction = Peatio::Transaction.new(
              hash: tx_hash,
              txout: idx,
              amount: v.fetch('value'),
              to_address: address,
              block_number: block_number,
              status: :success,
              currency_id: @currency.fetch(:id)
            )
            
            transactions << transaction
          end
        end
        
        # Process inputs (vin)
        tx['vin'].each do |input|
          next if input['coinbase'].present?
          next unless input['txid'].present? && input['vout'].present?
          
          # Skip if we can't find the previous transaction
          prev_tx = client.json_rpc(:getrawtransaction, [input['txid'], true]) rescue nil
          next if prev_tx.blank?
          
          prev_vout = prev_tx.fetch('vout')[input['vout']] rescue nil
          next if prev_vout.blank? || prev_vout['scriptPubKey'].blank? || prev_vout['scriptPubKey']['addresses'].blank?
          
          from_addresses = prev_vout['scriptPubKey']['addresses']
          from_addresses.each do |address|
            transaction = Peatio::Transaction.new(
              hash: tx_hash,
              txout: input['vout'],
              amount: prev_vout.fetch('value'),
              from_address: address,
              block_number: block_number,
              status: :success,
              currency_id: @currency.fetch(:id)
            )
            
            transactions << transaction
          end
        end
      end
      
      def process_asset_transaction(tx, block_number, transactions)
        tx_hash = tx.fetch('txid')
        asset_name = @currency.dig(:options, :asset_name)

        # For Ravencoin forks like Tenzura, we need to inspect transaction details
        # to find asset transfers
        begin
          # Get detailed transaction info that includes asset operations
          tx_details = client.json_rpc(:getrawtransaction, [tx_hash, true]) rescue nil
          return if tx_details.blank?
          
          # Look for asset operations in the transaction
          tx_details['vout'].each_with_index do |v, idx|
            # Skip if there are no asset operations
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
        rescue => e
          Rails.logger.error { "Failed to process asset transaction: #{e.message}" }
        end
      end

      def client
        @client ||= Client.new(@wallet.fetch(:uri))
      end
    end
  end
end