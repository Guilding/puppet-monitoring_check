#!/opt/sensu/embedded/bin/ruby
#
# Check Cluster
#

require 'socket'
require 'net/http'

if !defined?(IN_RSPEC)
  require 'rubygems'
  require 'sensu'
  require 'sensu/settings'
  require 'sensu-plugin/check/cli'
  require 'json'
end

class CheckCluster < Sensu::Plugin::Check::CLI
  option :cluster_name,
    :short => "-N NAME",
    :long => "--cluster-name NAME",
    :description => "Name of the cluster to use in the source of the alerts",
    :required => true

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
    lock_key      = "lock:#{config[:cluster_name]}:#{config[:check]}"
    lock_interval = (cluster_check || target_check || {})[:interval] || 300

    locker(self, redis, lock_key, lock_interval, Time.now.to_i, logger).run do
      status, output = check_aggregate
      logger.puts output
      send_payload status, output
      ok "Check executed successfully"
    end

    unknown "Check didn't report status"
  rescue RuntimeError => e
    critical "#{e.message} (#{e.class}): #{e.backtrace.inspect}"
  end

private

  EXIT_CODES = Sensu::Plugin::EXIT_CODES

  def logger
    $stdout
  end

  def locker(*args)
    RedisLocker.new(*args)
  end

  def redis
    redis_config = sensu_settings[:redis] or raise "Redis config not available"
    TinyRedisClient.new(redis_config[:host], redis_config[:port])
  end

  def check_aggregate
    path   = "/aggregates/#{config[:check]}"
    issued = api_request(path, :age => 30)
    time   = issued.sort.last

    return EXIT_CODES['WARNING'], "No aggregates older than #{config[:age]} seconds" unless time

    aggregate = api_request("#{path}/#{time}")
    check_thresholds(aggregate) { |status, msg| return status, msg }
    # check_pattern(aggregate) { |status, msg| return status, msg }

    return EXIT_CODES['OK'], "Aggregate looks GOOD"
  end

  # yielding means end of checking and sending payload to sensu
  def check_thresholds(aggregate)
    ok, total = aggregate.values_at("ok", "total")
    nz_pct    = ((1 - ok.to_f / total.to_f) * 100).to_i
    message   = "Number of non-zero results exceeds threshold (#{nz_pct}% non-zero)"

    if config[:critical] && nz_pct >= config[:critical]
      yield EXIT_CODES['CRITICAL'], message
    elsif config[:warning] && nz_pct >= config[:warning]
      yield EXIT_CODES['WARNING'], message
    else
      logger.puts "Number of non-zero results: #{ok}/#{total} #{nz_pct}% - OK"
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

  def sensu_settings
    @sensu_settings ||=
      Sensu::Settings.get(:config_dirs => ["/etc/sensu/conf.d"]) or
      raise "Sensu settings not available"
  end

  def send_payload(status, output)
    payload = target_check.merge(
      :status => status,
      :output => output,
      :source => config[:cluster_name],
      :name   => config[:check])

    payload[:runbook] = cluster_check[:runbook] if cluster_check[:runbook] != '-'
    payload[:tip]     = cluster_check[:tip] if cluster_check[:tip] != '-'
    payload.delete :command

    sock = TCPSocket.new('localhost', 3030)
    sock.puts payload.to_json
    sock.close
  end

  def cluster_check
    return {} if ENV['DEBUG']
    return JSON.parse(ENV['DEBUG_CC']) if ENV['DEBUG_CC']

    sensu_settings[:checks][:"#{config[:cluster_name]}_#{config[:check]}"] or
      raise "#{config[:cluster_name]}_#{config[:check]} not found in sensu settings"
  end

  def target_check
    sensu_settings[:checks][config[:check]] or
      raise "#{config[:check]} not found in sensu settings"
  end
end

class RedisLocker
  attr_reader :status, :redis, :key, :interval, :now, :logger

  def initialize(status, redis, key, interval, now = Time.now.to_i, logger = $stdout)
    raise "Redis connection check failed" unless "hello" == redis.echo("hello")

    @status   = status
    @redis    = redis
    @key      = key
    @interval = interval.to_i
    @now      = now
    @logger   = logger
  end

  def run
    expire if ENV['DEBUG_UNLOCK']

    if redis.setnx(key, now) == 1
      logger.puts "Lock acquired"

      begin
        expire interval
        yield
      rescue => e
        expire
        status.critical "Releasing lock due to error: #{e} #{e.backtrace}"
        raise e
      end
    elsif lock_value = redis.get(key)
      if (ttl = now - lock_value.to_i) > interval
        status.warning "Lock problem: #{now} - #{lock_value} > #{interval}, expired immediately"
      else
        status.ok "Lock expires in #{interval - ttl} seconds"
      end
    else
      status.ok "Lock slipped away"
    end
  end

private

  def expire(seconds=0)
    redis.pexpire(@key, seconds*1000)
  end
end

class TinyRedisClient
  RN = "\r\n"

  def initialize(host='localhost', port=6379)
    @socket = TCPSocket.new(host, port)
  end

  def method_missing(method, *args)
    args.unshift method
    data = ["*#{args.size}", *args.map {|arg| "$#{arg.to_s.size}#{RN}#{arg}"}]
    @socket.write(data.join(RN) << RN)
    parse_response
  end

  def parse_response
    case @socket.gets
    when /^\+(.*)\r\n$/ then $1
    when /^:(\d+)\r\n$/ then $1.to_i
    when /^-(.*)\r\n$/  then raise "Redis error: #{$1}"
    when /^\$([-\d]+)\r\n$/
      $1.to_i >= 0 ? @socket.read($1.to_i+2)[0..-3] : nil
    when /^\*([-\d]+)\r\n$/
      $1.to_i > 0 ? (1..$1.to_i).inject([]) { |a,_| a << parse_response } : nil
    end
  end

  def close
    @socket.close
  end
end
