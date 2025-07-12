# Smart Geth client that detects Infura and uses BSC params
class SmartGethBlockchain
  def initialize
    @actual_blockchain = nil
  end
  
  def configure(settings = {})
    server = settings[:server] || ''
    
    # If using Infura, use BSC params, otherwise use ETH params
    if server.include?('infura.io')
      Rails.logger.info "🔗 SmartGethBlockchain: Detected Infura URL (#{server}), using BSC blockchain for BNB native currency"
      @actual_blockchain = Ethereum::Bsc::Blockchain.new
    else
      Rails.logger.info "🔗 SmartGethBlockchain: Using standard ETH blockchain for ETH native currency (#{server})"
      @actual_blockchain = Ethereum::Eth::Blockchain.new
    end
    
    @actual_blockchain.configure(settings)
  end
  
  def method_missing(method, *args, &block)
    @actual_blockchain.send(method, *args, &block)
  end
  
  def respond_to_missing?(method, include_private = false)
    @actual_blockchain.respond_to?(method, include_private) || super
  end
end

Peatio::Blockchain.registry[:bitcoin] = Bitcoin::Blockchain
Peatio::Blockchain.registry[:geth] = SmartGethBlockchain
Peatio::Blockchain.registry[:parity] = Ethereum::Eth::Blockchain
Peatio::Blockchain.registry[:"geth-bsc"] = Ethereum::Bsc::Blockchain
Peatio::Blockchain.registry[:"geth-heco"] = Ethereum::Heco::Blockchain