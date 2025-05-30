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
        
        # Default to Ethereum mainnet
        Rails.logger.warn { "Using default chain ID 1 (Ethereum mainnet)" }
        1
      end
      
      # Get gas parameters automatically based on network
      def get_gas_params(options)
        # First, check if we should use EIP-1559
        # Auto-detect based on network capabilities
        supports_eip1559 = detect_eip1559_support
        
        if supports_eip1559
          # EIP-1559 is supported, use the new fee model
          Rails.logger.info { "Network supports EIP-1559, using dynamic fee model" }
          return get_eip1559_fees
        else
          # Use legacy gas price for networks without EIP-1559
          Rails.logger.info { "Using legacy fee model" }
          return get_legacy_gas_price(options)
        end
      end
      
      # Detect if the network supports EIP-1559
      def detect_eip1559_support
        # Manual override if specified in wallet settings
        if @wallet.dig(:settings, :use_eip1559).present?
          return @wallet.dig(:settings, :use_eip1559).to_s.downcase == 'true'
        end
        
        # Known networks that support EIP-1559
        eip1559_networks = [1, 5, 11155111] # ETH mainnet, Goerli, Sepolia
        current_chain = chain_id
        
        if eip1559_networks.include?(current_chain)
          return true
        end
        
        # Try to detect by checking if eth_feeHistory is available
        begin
          client.json_rpc(:eth_feeHistory, [1, 'latest', []])
          return true
        rescue => e
          Rails.logger.info { "Network does not support EIP-1559 fee history: #{e.message}" }
          return false
        end
      end
      
      # Get appropriate gas fees for EIP-1559 networks
      def get_eip1559_fees
        # If manually specified in wallet settings, use those values
        if @wallet.dig(:settings, :max_fee_per_gas).present? && @wallet.dig(:settings, :max_priority_fee_per_gas).present?
          max_fee = @wallet.dig(:settings, :max_fee_per_gas).to_i
          priority_fee = @wallet.dig(:settings, :max_priority_fee_per_gas).to_i
          
          Rails.logger.info { "Using manual EIP-1559 settings: max_fee=#{max_fee}, priority_fee=#{priority_fee}" }
          return {
            max_fee_per_gas: max_fee,
            max_priority_fee_per_gas: priority_fee,
            eip1559: true
          }
        end
        
        # Try to calculate appropriate values from the network
        begin
          # Get fee history from the node
          fee_history = client.json_rpc(:eth_feeHistory, [4, 'latest', [10, 50, 90]])
          
          # Get base fee from the latest block
          base_fee = fee_history['baseFeePerGas'].last.hex
          
          # Get a reasonable priority fee (tip) - 50th percentile
          priority_fee = fee_history['reward'][0][1].hex
          
          # Ensure minimum values
          priority_fee = 1_500_000_000 if priority_fee < 1_000_000_000 # Minimum 1 Gwei
          
          # Max fee should be base fee + priority fee with some buffer for base fee increases
          max_fee = (base_fee * 2) + priority_fee
          
          Rails.logger.info { "Calculated EIP-1559 fees: base_fee=#{base_fee}, priority_fee=#{priority_fee}, max_fee=#{max_fee}" }
          
          return {
            max_fee_per_gas: max_fee,
            max_priority_fee_per_gas: priority_fee,
            eip1559: true
          }
        rescue => e
          # If fee calculation fails, use safe defaults
          Rails.logger.warn { "Error calculating EIP-1559 fees: #{e.message}. Using default values." }
          
          # Default values that are generally safe for most networks
          return {
            max_fee_per_gas: 50_000_000_000, # 50 Gwei
            max_priority_fee_per_gas: 1_500_000_000, # 1.5 Gwei
            eip1559: true
          }
        end
      end
      
      # Get appropriate gas price for legacy networks
      def get_legacy_gas_price(options)
        # If manually specified in wallet settings, use that value
        if @wallet.dig(:settings, :gas_price).present?
          gas_price = @wallet.dig(:settings, :gas_price).to_i
          
          Rails.logger.info { "Using manual gas price: #{gas_price}" }
          return {
            gas_price: gas_price,
            eip1559: false
          }
        end
        
        # If specified in options, use that
        if options[:gas_price].present? && options[:gas_price].to_i > 0
          return {
            gas_price: options[:gas_price].to_i,
            eip1559: false
          }
        end
        
        # Otherwise calculate from the network
        begin
          # Get current gas price from the network
          gas_price = client.json_rpc(:eth_gasPrice).hex
          
          # Apply multiplier based on network
          current_chain = chain_id
          
          multiplier = case current_chain
                      when 56, 97 # BSC mainnet, testnet
                        1.1 # BSC typically needs only small increase
                      else
                        1.2 # Default 20% increase for most networks
                      end
          
          # Apply the multiplier to ensure transaction goes through
          gas_price = (gas_price * multiplier).to_i
          
          Rails.logger.info { "Calculated gas price: #{gas_price} (#{gas_price / 1_000_000_000.0} Gwei)" }
          
          return {
            gas_price: gas_price,
            eip1559: false
          }
        rescue => e
          # If gas price calculation fails, use safe defaults
          Rails.logger.warn { "Error calculating gas price: #{e.message}. Using default values." }
          
          # Default values based on network
          current_chain = chain_id
          default_gas_price = case current_chain
                             when 56, 97 # BSC
                               5_000_000_000 # 5 Gwei
                             else
                               30_000_000_000 # 30 Gwei for other networks
                             end
          
          return {
            gas_price: default_gas_price,
            eip1559: false
          }
        end
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

        # Get gas parameters automatically
        gas_params = get_gas_params(options)

        # Subtract fees from initial deposit amount in case of deposit collection
        if options.dig(:subtract_fee)
          # Calculate fee based on the fee model
          gas_limit = options.fetch(:gas_limit).to_i
          fee_amount = if gas_params[:eip1559]
                        gas_limit * gas_params[:max_fee_per_gas]
                      else
                        gas_limit * gas_params[:gas_price]
                      end
                      
          amount -= fee_amount
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
        
        # Get chain ID for this transaction
        current_chain_id = chain_id
        
        # Prepare transaction data
        tx_data = {
          from: wallet_address,
          to: normalize_address(transaction.to_address),
          value: amount,
          gas_limit: options.fetch(:gas_limit).to_i,
          nonce: client.json_rpc(:eth_getTransactionCount, [wallet_address, 'pending']).hex
        }
        
        # Sign the transaction based on the fee model
        if gas_params[:eip1559]
          # EIP-1559 transaction (type 2)
          raw_tx = Eth::Tx.new({
            value: tx_data[:value],
            data: '',
            gas_limit: tx_data[:gas_limit],
            max_fee_per_gas: gas_params[:max_fee_per_gas],
            max_priority_fee_per_gas: gas_params[:max_priority_fee_per_gas],
            nonce: tx_data[:nonce],
            to: tx_data[:to],
            chain_id: current_chain_id,
            type: '0x02' # EIP-1559 transaction type
          })
          
          Rails.logger.info { "Creating EIP-1559 transaction with max_fee=#{gas_params[:max_fee_per_gas]}, " \
                             "priority_fee=#{gas_params[:max_priority_fee_per_gas]} " \
                             "to #{transaction.to_address} with amount #{amount}" }
        else
          # Legacy transaction
          raw_tx = Eth::Tx.new({
            value: tx_data[:value],
            data: '',
            gas_limit: tx_data[:gas_limit],
            gas_price: gas_params[:gas_price],
            nonce: tx_data[:nonce],
            to: tx_data[:to],
            chain_id: current_chain_id
          })
          
          Rails.logger.info { "Creating legacy transaction with gas_price=#{gas_params[:gas_price]} " \
                             "to #{transaction.to_address} with amount #{amount}" }
        end
        
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

        # Get gas parameters automatically
        gas_params = get_gas_params(options)

        # Get the wallet private key
        wallet_address = normalize_address(@wallet.fetch(:address))
        private_key = @wallet.fetch(:secret)
        
        # Create an Ethereum key using the private key
        key = Eth::Key.new(priv: private_key)
        
        # Make sure the key corresponds to the wallet address
        unless normalize_address(key.address.to_s) == wallet_address
          raise Peatio::Wallet::ClientError, "Private key doesn't match the wallet address"
        end
        
        # Get chain ID for this transaction
        current_chain_id = chain_id
        
        # Prepare transaction data for ERC20 transfer
        tx_data = {
          from: wallet_address,
          to: options.fetch(contract_address_option),
          value: 0,
          gas_limit: options.fetch(:gas_limit).to_i,
          data: data,
          nonce: client.json_rpc(:eth_getTransactionCount, [wallet_address, 'pending']).hex
        }
        
        # Sign the transaction based on the fee model
        if gas_params[:eip1559]
          # EIP-1559 transaction (type 2)
          raw_tx = Eth::Tx.new({
            value: tx_data[:value],
            data: tx_data[:data],
            gas_limit: tx_data[:gas_limit],
            max_fee_per_gas: gas_params[:max_fee_per_gas],
            max_priority_fee_per_gas: gas_params[:max_priority_fee_per_gas],
            nonce: tx_data[:nonce],
            to: tx_data[:to],
            chain_id: current_chain_id,
            type: '0x02' # EIP-1559 transaction type
          })
          
          Rails.logger.info { "Creating EIP-1559 ERC20 transaction with max_fee=#{gas_params[:max_fee_per_gas]}, " \
                             "priority_fee=#{gas_params[:max_priority_fee_per_gas]} for token transfer" }
        else
          # Legacy transaction
          raw_tx = Eth::Tx.new({
            value: tx_data[:value],
            data: tx_data[:data],
            gas_limit: tx_data[:gas_limit],
            gas_price: gas_params[:gas_price],
            nonce: tx_data[:nonce],
            to: tx_data[:to],
            chain_id: current_chain_id
          })
          
          Rails.logger.info { "Creating legacy ERC20 transaction with gas_price=#{gas_params[:gas_price]} for token transfer" }
        end
        
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