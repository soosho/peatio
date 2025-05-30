require 'eth'

module Peatio
  module CustomEthereum
    class Wallet < ::Ethereum::WalletAbstract
      include ::Ethereum::Eth::Params

      # Override create_address! to generate addresses locally without using personal_newAccount
      def create_address!(_options = {})
        # Generate a random private key
        private_key = SecureRandom.hex(32)
        
        # Create an Ethereum key using the eth gem
        key = Eth::Key.new(priv: private_key)
        
        # Return both the address and private key
        # Convert address to string before normalizing
        { address: normalize_address(key.address.to_s), secret: private_key }
      rescue StandardError => e
        raise Peatio::Wallet::ClientError, e
      end

      # Get chain ID from wallet settings or other sources
      def chain_id
        # Try to get chain ID from wallet settings
        if @wallet.dig(:settings, :chain_id).present?
          chain_id_value = @wallet.dig(:settings, :chain_id).to_i
          Rails.logger.info { "Using chain ID #{chain_id_value} from wallet settings" }
          return chain_id_value
        end
        
        # Try to get chain ID from currency options (fallback)
        if @currency.dig(:options, :chain_id).present?
          chain_id_value = @currency.dig(:options, :chain_id).to_i
          Rails.logger.info { "Using chain ID #{chain_id_value} from currency options" }
          return chain_id_value
        end
        
        # Try to query the node
        begin
          chain_id_value = client.json_rpc(:eth_chainId).hex
          Rails.logger.info { "Using chain ID #{chain_id_value} from node" }
          return chain_id_value if chain_id_value > 0
        rescue => e
          Rails.logger.warn { "Failed to get chain ID from node: #{e.message}" }
        end
        
        # Fallback based on blockchain_key
        if @wallet[:blockchain_key].present?
          case @wallet[:blockchain_key].to_s
          when /sepolia/
            Rails.logger.info { "Using chain ID 11155111 (Sepolia) based on blockchain key" }
            return 11155111
          when /goerli/
            Rails.logger.info { "Using chain ID 5 (Goerli) based on blockchain key" }
            return 5
          when /bsc/
            Rails.logger.info { "Using chain ID 56 (BSC) based on blockchain key" }
            return 56
          when /bsc-testnet/
            Rails.logger.info { "Using chain ID 97 (BSC Testnet) based on blockchain key" }
            return 97
          # Add other networks as needed
          end
        end
        
        # Default to Ethereum mainnet
        Rails.logger.warn { "Using default chain ID 1 (Ethereum mainnet)" }
        1
      end

      # Override create_transaction! to handle both ETH and ERC20 token transfers
      def create_transaction!(transaction, options = {})
        if @currency.dig(:options, contract_address_option).present?
          create_erc20_transaction!(transaction, options)
        elsif @currency[:id] == native_currency_id
          create_eth_transaction!(transaction, options)
        else
          raise Peatio::Wallet::ClientError.new("Currency #{@currency[:id]} doesn't have option #{contract_address_option}")
        end
      rescue Ethereum::Client::Error => e
        raise Peatio::Wallet::ClientError, e
      end

      protected

      # Send ETH using local signing
      def create_eth_transaction!(transaction, options = {})
        currency_options = @currency.fetch(:options).slice(:gas_limit, :gas_price)
        options.merge!(DEFAULT_ETH_FEE, currency_options)

        amount = convert_to_base_unit(transaction.amount)

        if transaction.options.present?
          options[:gas_price] = transaction.options[:gas_price]
        else
          options[:gas_price] = calculate_gas_price(options)
        end

        # Subtract fees from initial deposit amount in case of deposit collection
        amount -= options.fetch(:gas_limit).to_i * options.fetch(:gas_price).to_i if options.dig(:subtract_fee)

        # Get the wallet private key
        wallet_address = normalize_address(@wallet.fetch(:address))
        private_key = @wallet.fetch(:secret)
        
        # Create an Ethereum key using the private key
        key = Eth::Key.new(priv: private_key)
        
        # Make sure the key corresponds to the wallet address
        unless normalize_address(key.address.to_s) == wallet_address
          raise Peatio::Wallet::ClientError, "Private key doesn't match the wallet address"
        end
        
        # Prepare transaction data
        tx_data = {
          from: wallet_address,
          to: normalize_address(transaction.to_address),
          value: amount,
          gas_limit: options.fetch(:gas_limit).to_i,
          gas_price: options.fetch(:gas_price).to_i,
          nonce: client.json_rpc(:eth_getTransactionCount, [wallet_address, 'pending']).hex
        }
        
        # Get chain ID for this transaction
        current_chain_id = chain_id
        
        # Sign the transaction locally with chain ID
        raw_tx = Eth::Tx.new({
          value: tx_data[:value],
          data: '',
          gas_limit: tx_data[:gas_limit],
          gas_price: tx_data[:gas_price],
          nonce: tx_data[:nonce],
          to: tx_data[:to],
          chain_id: current_chain_id
        })
        raw_tx.sign(key)
        
        # Send the raw transaction
        txid = client.json_rpc(:eth_sendRawTransaction, ["0x#{raw_tx.hex}"])

        unless valid_txid?(normalize_txid(txid))
          raise Ethereum::Client::Error, \
                "Withdrawal from #{wallet_address} to #{transaction.to_address} failed."
        end
        
        # Make sure that we return currency_id
        transaction.currency_id = 'eth' if transaction.currency_id.blank?
        transaction.amount = convert_from_base_unit(amount)
        transaction.hash = normalize_txid(txid)
        transaction.options = options
        transaction
      end

      # Send ERC20 tokens using local signing
      def create_erc20_transaction!(transaction, options = {})
        currency_options = @currency.fetch(:options).slice(:gas_limit, :gas_price, contract_address_option)
        options.merge!(DEFAULT_ERC20_FEE, currency_options)

        amount = convert_to_base_unit(transaction.amount)
        data = abi_encode('transfer(address,uint256)',
                          normalize_address(transaction.to_address),
                          '0x' + amount.to_s(16))

        if transaction.options.present?
          options[:gas_price] = transaction.options[:gas_price]
        else
          options[:gas_price] = calculate_gas_price(options)
        end

        # Get the wallet private key
        wallet_address = normalize_address(@wallet.fetch(:address))
        private_key = @wallet.fetch(:secret)
        
        # Create an Ethereum key using the private key
        key = Eth::Key.new(priv: private_key)
        
        # Make sure the key corresponds to the wallet address
        unless normalize_address(key.address.to_s) == wallet_address
          raise Peatio::Wallet::ClientError, "Private key doesn't match the wallet address"
        end
        
        # Prepare transaction data for ERC20 transfer
        tx_data = {
          from: wallet_address,
          to: options.fetch(contract_address_option),
          value: 0,
          gas_limit: options.fetch(:gas_limit).to_i,
          gas_price: options.fetch(:gas_price).to_i,
          data: data,
          nonce: client.json_rpc(:eth_getTransactionCount, [wallet_address, 'pending']).hex
        }
        
        # Get chain ID for this transaction
        current_chain_id = chain_id
        
        # Sign the transaction locally with chain ID
        raw_tx = Eth::Tx.new({
          value: tx_data[:value],
          data: tx_data[:data],
          gas_limit: tx_data[:gas_limit],
          gas_price: tx_data[:gas_price],
          nonce: tx_data[:nonce],
          to: tx_data[:to],
          chain_id: current_chain_id
        })
        raw_tx.sign(key)
        
        # Send the raw transaction
        txid = client.json_rpc(:eth_sendRawTransaction, ["0x#{raw_tx.hex}"])

        unless valid_txid?(normalize_txid(txid))
          raise Ethereum::Client::Error, \
                "Withdrawal from #{wallet_address} to #{transaction.to_address} failed."
        end
        
        transaction.hash = normalize_txid(txid)
        transaction.options = options
        transaction
      end
    end
  end
end