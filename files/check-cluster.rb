#!/usr/bin/env ruby
#
# Check Cluster
#

require 'socket'
require 'net/http'

require 'rubygems'
require 'sensu'
require 'sensu/settings'
require 'sensu/redis'
require 'sensu-plugin/check/cli'
require 'json'

class CheckCluster < Sensu::Plugin::Check::CLI
  option :cluster_name,
    :short => "-N NAME",
    :long => "--cluster-name NAME",
    :description => "Name of the cluster to use in the source of the alerts",
    :required => true

  option :config_dir,
    :short => "-D DIR",
    :long => "--config-dir DIR",
    :description => "Sensu server config directory",
    :default => "/etc/sensu/conf.d"

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

private

  EXIT_CODES = Sensu::Plugin::EXIT_CODES

  def check_aggregate
    path   = "/aggregates/#{config[:check]}"
    issued = api_request(path, :age => 30)

    return EXIT_CODES['WARNING'], "No aggregates for #{config[:check]}" if issued.empty?
    time = issued.sort.last

    return EXIT_CODES['WARNING'], "No aggregates older than #{config[:age]} seconds" unless time

    aggregate = api_request("#{path}/#{time}")
    check_thresholds(aggregate) { |status, msg| return status, msg }
    # check_pattern(aggregate) { |status, msg| return status, msg }

    return EXIT_CODES['OK'], "Aggregate looks GOOD"
  end

  # yielding means end of checking and sending payload to sensu
  def check_thresholds(aggregate)
    nz_pct  = ((1 - aggregate["ok"].to_f / aggregate["total"].to_f) * 100).to_i
    message = "Number of non-zero results exceeds threshold (#{nz_pct}% non-zero)"

    if config[:critical] && percent_non_zero >= config[:critical]
      yield EXIT_CODES['CRITICAL'], message
    elsif config[:warning] && percent_non_zero >= config[:warning]
      yield EXIT_CODES['CRITICAL'], message
    end
  end

  def api_request(path, opts={})
    api = sensu_settings[:api]
    uri = URI("http://#{api[:host]}:#{api[:port]}#{path}")
    uri.query = URI.encode_www_form(opts)

    req = Net::HTTP::Get.new(uri)
    req.basic_auth api[:user], api[:password]

    res = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    if res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    else
      raise "Error querying sensu api: #{res.code} '#{res.body}'"
    end
  end

  def locked_run
    # TODO: pyramid of doom! i'm horrible with EM
    EM::run do
      begin
        redis.setnx(lock_key, Time.now.to_i) do |created|
          if created
            redis.expire(lock_key, lock_interval) do |result|
              yield
              EM::stop
            end
          else
            redis.get(lock_key) do |age|
              ttl = Time.now.to_i - age.to_i
              if ttl > lock_interval
                redis.expire(lock_key, 0) do
                  EM::stop
                  warning "was locked for #{ttl} seconds, expired immediately"
                end
              else
                EM::stop
                ok "lock expires in #{lock_interval - ttl} seconds"
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

  # assume convention for naming aggregate checks as <cluster_name>_<check_name>
  # default to aggregated check interval or 300 seconds
  def lock_interval
    check = sensu_settings[:checks][:"#{config[:cluster]}_#{config[:check]}"]
    check ||= sensu_settings[:checks][config[:check]]
    check[:interval] || 300
  end

  def redis
    @redis ||= Sensu::Redis.connect(sensu_settings[:redis])
  end

  def sensu_settings
    @sensu_settings ||=
      Sensu::Settings.get(:config_dirs => [config[:config_dir]])
  end

  def send_payload(status, output)
    payload =
      sensu_settings[:checks][config[:check]].merge(
        :status => status,
        :output => output,
        :source => config[:cluster_name],
        :name   => config[:check])
    payload.delete :command

    sock = TCPSocket.new('localhost', 3030)
    sock.puts payload.to_json
    sock.close
  end
end
