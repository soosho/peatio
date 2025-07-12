# encoding: UTF-8
# frozen_string_literal: true

module Workers
  module Daemons
    class Blockchain < Base
      class Runner
        attr_reader :ts, :thread

        def initialize(blockchain, ts)
          @blockchain = blockchain
          @ts = ts
          @thread = nil
        end

        def start
          @thread ||= Thread.new do
            bc_service = BlockchainService.new(@blockchain)

            Rails.logger.info { "Processing #{@blockchain.name} blocks." }

            loop do
              begin
                # Reset blockchain_service state.
                bc_service.reset!

                if @blockchain.reload.height + @blockchain.min_confirmations >= bc_service.latest_block_number
                  Rails.logger.debug { "Skip synchronization. No new blocks detected, height: #{@blockchain.height}, latest_block: #{bc_service.latest_block_number}." }
                  
                  # No sleep for BSC (binance key)
                  unless @blockchain.key.to_s.downcase.include?('binance')
                    sleep(2)
                  end
                  next
                end

                from_block = @blockchain.height || 0
                to_block = bc_service.latest_block_number
                total_blocks = to_block - from_block
                
                Rails.logger.info { "Processing #{total_blocks} blocks from #{from_block} to #{to_block} for #{@blockchain.key}" }
                
                processed_count = 0
                start_time = Time.now

                (from_block..to_block).each do |block_id|
                  # No rate limiting delay for BSC (binance key) since it has 3-second block times
                  unless @blockchain.key.to_s.downcase.include?('binance')
                    # Add small delay for other blockchains to prevent overwhelming the RPC
                    sleep(0.1)
                  end
                  
                  # Process each block (this MUST be done one by one to check transactions)
                  block_json = bc_service.process_block(block_id)
                  bc_service.update_height(block_id)
                  
                  processed_count += 1
                  
                  # Log progress every 200 blocks instead of every block to reduce I/O
                  if processed_count % 200 == 0 || block_id == to_block
                    elapsed_time = Time.now - start_time
                    blocks_per_second = processed_count / elapsed_time
                    remaining_blocks = to_block - block_id
                    eta_seconds = remaining_blocks / blocks_per_second if blocks_per_second > 0
                    
                    Rails.logger.info { 
                      "#{@blockchain.key}: #{processed_count}/#{total_blocks} blocks " \
                      "(#{blocks_per_second.round(2)} blocks/sec, ETA: #{eta_seconds ? eta_seconds.round(0) : 'N/A'}s) " \
                      "Block #{block_id}"
                    }
                  end
                  
                  # Only yield to other threads occasionally to maintain speed
                  Thread.pass if processed_count % 50 == 0
                end
                
                total_time = Time.now - start_time
                Rails.logger.info { "Completed #{processed_count} blocks for #{@blockchain.key} in #{total_time.round(2)}s (#{(processed_count/total_time).round(2)} blocks/sec)" }
                
              rescue StandardError => e
                report_exception(e)
                
                # Special handling for rate limiting errors
                if e.message.include?('Too Many Requests') || e.message.include?('429')
                  Rails.logger.warn { "Rate limit hit for #{@blockchain.key}. Sleeping for 5 seconds" }
                  sleep(5)  # Longer sleep for rate limiting
                else
                  Rails.logger.warn { "Error: #{e}. Sleeping for 2 seconds" }
                  
                  # No sleep for BSC (binance key)
                  unless @blockchain.key.to_s.downcase.include?('binance')
                    sleep(2)
                  end
                end
              end
            end
          end
        end

        def stop
          @thread&.kill
        end
      end

      def run
        @runner_pool = ::Blockchain.active.each_with_object({}) do |b, pool|
          max_ts = [b.currencies.maximum(:updated_at), b.updated_at].compact.max.to_i

          logger.warn { "Creating the runner for #{b.key}" }
          pool[b.key] = Runner.new(b, max_ts).tap(&:start)
        end

        while running
          begin
            # Stop disabled blockchains runners first.
            (@runner_pool.keys - ::Blockchain.active.pluck(:key)).each do |b_key|
              logger.warn { "Stopping the runner for #{b_key} (blockchain is not active anymore)" }
              @runner_pool.delete(b_key).stop
            end

            # Recreate active blockchain runners by comparing runner &
            # maximum blockchain & currencies updated_at timestamp.
            ::Blockchain.active.each do |b|
              max_ts = [b.currencies.maximum(:updated_at), b.updated_at].compact.max.to_i

              if @runner_pool[b.key].blank?
                logger.warn { "Starting the new runner for #{b.key} (no runner found in pool)" }
                @runner_pool[b.key] = Runner.new(b, max_ts).tap(&:start)
              elsif @runner_pool[b.key].ts < max_ts
                logger.warn { "Recreating a runner for #{b.key} (#{Time.at(@runner_pool[b.key].ts)} < #{Time.at(max_ts)})" }
                @runner_pool.delete(b.key).stop
                @runner_pool[b.key] = Runner.new(b, max_ts).tap(&:start)
              else
                logger.warn { "The runner for #{b.key} is up to date (#{Time.at(@runner_pool[b.key].ts)} >= #{Time.at(max_ts)})" }
              end
            end

            logger.info { "Current runners timestamps:" }
            logger.info do
              @runner_pool.transform_values(&:ts)
            end

            # Check for blockchain config changes in 30 seconds.
            sleep 30

          rescue StandardError => e
            raise e if is_db_connection_error?(e)

            report_exception(e)
            Rails.logger.warn { "Error: #{e}. Sleeping for 10 seconds" }
            sleep(10)
          end
        end
      end

      def stop
        @running = false
        @runner_pool.each { |_bc_key, runner| runner.stop }
      end
    end
  end
end
