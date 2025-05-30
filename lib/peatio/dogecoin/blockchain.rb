module Peatio
  module Dogecoin
    class Blockchain < Peatio::Blockchain::Abstract

      DEFAULT_FEATURES = {
        case_sensitive: true,
        cash_addr_format: false,
        witness_type: false
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

      def load_balance_of_address!(address, _currency_id)
        address_with_balance = client.json_rpc(:listaddressgroupings)
                                     .flatten(1)
                                     .select { |addr| addr[0] == address }

        if address_with_balance.empty?
          0.to_d
        else
          # Since dogecoin is a fork of bitcoin, it can have multiple entries with same address
          address_with_balance.map { |addr| addr[1].to_d }.sum
        end
      rescue Client::Error => e
        raise Peatio::Blockchain::ClientError, e
      end

      private

      def process_block(block)
        # This is a dogecoin version of block processing
        # It's similar to Bitcoin but adjusted for Dogecoin specifics
        block_hash = block.fetch('hash')
        block_txs = block.fetch('tx')
        block_time = block.fetch('time')
        block_number = block.fetch('height')
        
        transactions = []
        block_txs.each do |tx|
          tx_hash = tx.fetch('txid')
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
          
          # Build tx entries for all addresses in vout
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
        
        Peatio::Block.new(
          number: block_number,
          hash: block_hash,
          time: Time.at(block_time).to_datetime,
          transactions: transactions
        )
      end

      def client
        @client ||= Client.new(@wallet.fetch(:uri))
      end
    end
  end
end