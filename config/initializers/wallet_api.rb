# Smart Geth wallet that detects Infura and uses BSC params
class SmartGethWallet
  def initialize
    @actual_wallet = nil
    Rails.logger.info "🚀 SmartGethWallet initialized!"
  end
  
  def configure(settings = {})
    server = settings.dig(:wallet, :uri) || ''
    
    # If using Infura, use BSC params, otherwise use ETH params
    if server.include?('infura.io')
      Rails.logger.info "💰 SmartGethWallet: Detected Infura URL (#{server}), using BSC wallet for BNB native currency"
      @actual_wallet = Ethereum::Bsc::Wallet.new
    else
      Rails.logger.info "💰 SmartGethWallet: Using standard ETH wallet for ETH native currency (#{server})"
      @actual_wallet = Ethereum::Eth::Wallet.new
    end
    
    @actual_wallet.configure(settings)
  end
  
  def method_missing(method, *args, &block)
    @actual_wallet.send(method, *args, &block)
  end
  
  def respond_to_missing?(method, include_private = false)
    @actual_wallet.respond_to?(method, include_private) || super
  end
end

require 'peatio/custom_ethereum'

Peatio::Wallet.registry[:bitcoind] = Bitcoin::Wallet
Peatio::Wallet.registry[:geth] = SmartGethWallet
Peatio::Wallet.registry[:parity] = Ethereum::Eth::Wallet
Peatio::Wallet.registry[:gnosis] = Gnosis::Wallet
Peatio::Wallet.registry[:"ow-hdwallet-eth"] = OWHDWallet::WalletETH
Peatio::Wallet.registry[:"ow-hdwallet-bsc"] = OWHDWallet::WalletBSC
Peatio::Wallet.registry[:"ow-hdwallet-heco"] = OWHDWallet::WalletHECO
Peatio::Wallet.registry[:opendax_cloud] = OpendaxCloud::Wallet
Peatio::Wallet.registry[:open_eth] = Ethereum::OpenEth::Wallet
Peatio::Wallet.registry[:custom_ethereum] = Peatio::CustomEthereum::Wallet
