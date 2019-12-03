require "socket"
require "eew_parser"
require "digest/md5"
require "open-uri"
require "logger"
require "ipaddr"
require "slack-ruby-client"
require "lru_redux"

ServerListURL = "http://lst10s-sp.wni.co.jp/server_list.txt"
UserID = "test@example.com" # WNI
Password = "changeme"
Channel = "#channel"
SlackUsername =  "緊急地震速報"
IconURL = "https://slack-files2.s3-us-west-2.amazonaws.com/avatars/2018-06-18/383300443972_adff82647cf3967cb337_72.png"
DEBUG = true

trap(:INT) { exit }
STDOUT.sync = true
@logger = Logger.new(STDOUT)

client = Slack::Web::Client.new(token: "token")
@cache = LruRedux::TTL::Cache.new(8, 300)

def get_server
  open(ServerListURL) do |io|
    ip_addr, port = io.readlines(chomp: true).sample.split(":")
    IPAddr.new(ip_addr) # verify
    return ip_addr, Integer(port)
  end
end

def parse_headers(str)
  headers = {}
  str.each_line(chomp: true) do |header|
    key, value = header.split(": ", 2)
    headers[key] = value if value
  end
  return headers
end

def run(&b)
  digest = Digest::MD5.hexdigest(Password)
  host, port = get_server()
  TCPSocket.open(host, port) do |eew|
    eew.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)

    eew.write("GET /login HTTP/1.0\r\nX-WNI-Account: #{UserID}\r\nX-WNI-Password: #{digest}\r\n\r\n")
    line = eew.readline("\n\n", chomp: true)
    headers = parse_headers(line)
    @logger.debug(headers)
    if headers["X-WNI-Result"] == "OK"
      @logger.info("#{host}:#{port} との接続を確立しました")
    else
      @logger.error("認証に失敗しました。")
      abort
    end
    loop do
      line = eew.readline("\n\n", chomp: true)
      headers = parse_headers(line)
      case headers["X-WNI-ID"]
      when "Keep-Alive"
        print "."
        @cache.expire
        # @logger.debug(headers)
        # wni_time = Time.strptime(headers["X-WNI-Time"], "%Y/%m/%d %T.%N")
      when "Data"
        puts
        @logger.debug(line.inspect)
        eew.readline("\n\x02\n\x02\n") # discard
        eew_line = eew.readline("9999=")
        @logger.debug(eew_line.inspect)
        eew_line.lstrip!
        begin
          yield EEW::Parser.new(eew_line)
        rescue => ex
          @logger.error(ex)
        end
      else
        @logger.warn("不明なWNI-ID: #{headers["X-WNI-ID"]}")
      end
    end
  end
end

run do |eew|
  begin
    @logger.debug(eew.inspect)
    # if !eew.warning? && !eew.first? && !eew.final?
    #   @logger.info("\n" + eew.print)
    #   next
    # end
    
    if eew.seismic_intensity == "1" || eew.seismic_intensity == "2"
      @logger.info("\n" + eew.print)
      next
    end

    position = eew.position
    if position == "不明又は未設定"
      epicenter = "#{eew.epicenter} (#{position})"
    else
      # example: position = "N37.1 E140.5"
      lat = position[1, 4] # 37.1
      lon = position[7, 5] # 140.5
      location = "#{lat},#{lon}" # 37.1,140.5
      map_url = "http://maps.google.co.jp/maps?q=loc:#{location}&ll=#{location}&z=8"
      epicenter = "<#{map_url}|#{eew.epicenter} (#{position})>"
    end

    now = Time.now

    printed = <<-EOS
震央: #{epicenter}
震源の深さ: #{eew.depth} km
現在時刻: #{now.strftime("%T")} (#{(now - eew.report_time).to_i}秒遅延)
発表時刻: #{eew.report_time.strftime("%T")} (#{(eew.report_time - eew.earthquake_time).to_i}秒経過)
地震発生時刻: #{eew.earthquake_time.strftime("%T")}
地震識別番号: <http://www.tenki.jp/bousai/earthquake/detail-#{eew.id}.html|#{eew.id}>
    EOS

    # printed << "地震識別番号: <http://www.tenki.jp/bousai/earthquake/detail-#{eew.id}.html|#{eew.id}>\n" if eew.first?
    printed << "発表状況: #{eew.status} (#{eew.drill_type})\n" unless eew.normal?
    printed << "最大予測震度の変化(変化の理由): #{eew.change} (#{eew.reason_of_change})\n" if eew.changed?

    begin
      if eew.has_ebi?
        printed << "\n地域ごとの予測震度・主要動到達予測時刻 (EBI):\n"
        eew.ebi.each do |local|
          arrival_time = nil
          if local[:arrival]
            arrival_time = "すでに到達"
          elsif _arrival_time = local[:arrival_time]
            arrival_time = _arrival_time.strftime("%T")
            if _arrival_time > now
              arrival_time.concat(" (あと#{(_arrival_time - now).to_i}秒)")
            else
              arrival_time.concat(" (#{(now - _arrival_time).to_i}秒経過)")
            end
          end

          printed << "#{local[:area_name].ljust(10)} 震度#{local[:intensity].ljust(3)} 予想到達時刻: #{arrival_time}\n"
        end
      end
    rescue => ex
      @logger.error(ex)
    end

    report_number = "(第#{eew.number}報)"
    report_number << " (最終報)" if eew.final?
    report_number << " (訓練)" if eew.drill?
    message = "緊急地震速報 #{eew.epicenter} 震度#{eew.seismic_intensity} M#{eew.magnitude} #{report_number}\n```#{printed}```"
    message.prepend("<!channel> (警報) ") if eew.warning?

    if ts = @cache[eew.id]
      client.chat_update(channel: Channel, ts: ts, text: message)
    else
      response = client.chat_postMessage(
        channel: Channel,
        username: SlackUsername,
        icon_url: IconURL,
        text: message
      )
      @cache[eew.id] = response.ts
    end

    @logger.info("\n" + eew.print)
  rescue => ex
    @logger.error(ex)
  end
end
