#!/usr/bin/env ruby
#
# Check Cluster
#

require 'rubygems'
require 'sensu'
require 'sensu/settings'
require 'sensu/transport'
require 'sensu/redis'
require 'sensu-plugin/check/cli'
require 'json'
require 'socket'

class CheckCluster < Sensu::Plugin::Check::CLI
  option :cluster_name,
    :short => "-N NAME",
    :long => "--cluster-name NAME",
    :description => "Name of the cluster to use in the source of the alerts (cluster_name + check_name)",
    :required => true

  option :config_dir,
    :short => "-D DIR",
    :long => "--config-dir DIR",
    :description => "Sensu server config directory",
    :default => "/etc/sensu/conf.d"

  option :lock_timeout,
    :short => "-L SECONDS",
    :long => "--lock-timeout SECONDS",
    :description => "TTL on redis lock, usually same as check interval",
    :default => 60

  option :socket,
    :short => "-S HOST:PORT",
    :long => "--socket SECONDS",
    :description => "TCP socket to send payload to",
    :default => "localhost:3030"

  # Passed into check-aggregate as is

  option :check,
    :short => "-c CHECK",
    :long => "--check CHECK",
    :description => "Aggregate CHECK name",
    :required => true

  option :warning,
    :short => "-W PERCENT",
    :long => "--warning PERCENT",
    :description => "PERCENT non-ok before warning",
    :proc => proc {|a| a.to_i }

  option :critical,
    :short => "-C PERCENT",
    :long => "--critical PERCENT",
    :description => "PERCENT non-ok before critical",
    :proc => proc {|a| a.to_i }

  def run
    locked_run do
      status, output = check_aggregate
      send_payload status, output
      ok "Check executed successfully"
    end
  end

  def check_aggregate
    # TODO: do not hardcode this?
    api  = sensu_settings[:api]
    args = ARGV.join(' ').
             gsub(/(-L|--lock-timeout)\s*[^\s]+/, '').
             gsub(/(-D|--config-dir)\s*[^\s]+/, '').
             gsub(/(-N|--cluster-name)\s*[^\s]+/, '').
             gsub(/(-S|--socket)\s*[^\s]+/, '')
    args << " -u #{api[:user]}" <<
            " -p #{api[:password]}" <<
            " -a http://#{api[:host]}:#{api[:port]}"
    cmd = "/usr/share/sensu-community-plugins/plugins/sensu/check-aggregate.rb #{args}"
    out = `#{cmd}`
    return $?.exitstatus, out
  end

private

  def locked_run
    # TODO: pyramid of doom! i'm horrible with EM
    EM::run do
      begin
        redis.setnx(lock_key, Time.now.to_i) do |created|
          puts "lock acquired: " << created.inspect
          if created
            redis.expire(lock_key, config[:lock_timeout]) do |result|
              puts "locked: " << result.inspect
              yield
              EM::stop
            end
          else
            redis.get(lock_key) do |age|
              ttl = Time.now.to_i - age.to_i
              if ttl > config[:lock_timeout].to_i
                redis.expire(lock_key, 0) do
                  EM::stop
                  warning "was locked for #{ttl} seconds, expired immediately"
                end
              else
                EM::stop
                ok "lock expires in #{config[:lock_timeout] - ttl} seconds"
              end
            end
          end
        end
      rescue Exception => e
        EM::stop
        critical "#{e.message} (#{e.class})\n#{e.backtrace.join "\n"}"
      end
    end
  end

  def lock_key
    "lock:#{config[:cluster_name]}:#{config[:check]}"
  end

  def redis
    @redis ||= Sensu::Redis.connect(sensu_settings[:redis])
  end

  def sensu_settings
    @sensu_settings ||=
      Sensu::Settings.get(:config_dirs => [config[:config_dir]])
  end

  def send_payload(status, output)
    payload = {
      :client => sensu_settings[:client],
      :occurrences => 1,
      :action => :create,
      :check  => sensu_settings[:checks][config[:check]].merge(
        :status => status,
        :output => output,
        :source => "#{config[:cluster_name]}_#{config[:check]}")
    }

    sock = TCPSocket.new(*config[:socket].split(':'))
    sock.write payload.to_json
    sock.close
  end
end
