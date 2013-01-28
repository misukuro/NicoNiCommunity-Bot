#!/usr/bin/env ruby
# -*- encoding: utf-8 -*-

require "net/https"
require "uri"
require "socket"
require "rubygems"
require "nokogiri"
require "redis"
require "json"

module OpenSSL
  module SSL
    remove_const :VERIFY_PEER
  end
end
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

# Set the configuration
NICO_ID = "" # Email address
NICO_PASS = "" # Password
USER_ID = "" # User ID of account
USER_AGENT = "" # Email address to notify to Nico
LATEST_COMMUNITY_NUMBER = 1922507

API_WAIT_TIME = 2.00
NICO_LOGIN_URL = "https://secure.nicovideo.jp/secure/login?site=niconico"
COMMUNITY_URL = "http://com.nicovideo.jp/"
COMMUNITY_PARTICIPATION_URL = COMMUNITY_URL + "motion/"
COMMUNITY_LEAVE_URL = COMMUNITY_URL + "leave/"
COMMUNITY_MEMBER_URL = COMMUNITY_URL + "member/"
COMMUNITY_TOP_URL = COMMUNITY_URL + "community/"
JOIN_REQUEST_URL = COMMUNITY_URL + "my_contact/"

class ErrorType
  i = 0
  %w(NOTLOGIN).each do |name|
    const_set(name, i)
    i += 1
  end
end

#The Class to connect to NicoNico
class NicoClient
  attr_accessor :session, :last_access_time, :error_type

  def login()
    uri = URI.parse(NICO_LOGIN_URL)
    Net::HTTP.version_1_2
    http = Net::HTTP.new(uri.host, uri.port)
    if(uri.port == 443)
      http.use_ssl = true
      http.ca_file = "./nico.cer"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_depth = 5
      http.ssl_version = :SSLv3
    end

    response = http.start do |access|
      post_data = {:mail=>NICO_ID, :password=>NICO_PASS}
      path = uri.path
      path += "?" + uri.query unless uri.query.nil?
      req = Net::HTTP::Post.new(path)
      req["User-Agent"] = USER_AGENT 
      req.set_form_data(post_data)
      response = access.request(req)
    end

    pattern = /user_session=(user_session_\d+_\d+)/
    session_cookie = response.get_fields('set-cookie').find do |cookie|
      pattern.match(cookie)
    end
    @session = pattern.match(session_cookie)[1]
    return true
  end

  #Participate in the community that is speciified to get the members.
  def get_community_member(community_id)
    #check if already joined.
    user_list = Array.new()
    unless community_join?(community_id) then
      #return empty list if manual approval
      attempts = 0
      begin
        is_manual = join_community(community_id)
        return user_list unless is_manual
        attempts += 1
      end while community_join?(community_id) && attempts <= 10
    end

    #get the members
    user_list = get_member(community_id)

    #leave the community
    is_complete = leave_community(community_id)
    leave_community(community_id) unless is_complete
    return user_list
  end

  #Check if document of members page have errors.
  def has_error_of_member_page?(document)
    document.search("//span[@class='error_solution']").each do |item|
      if item.text =~ /先にコミュニティに/
        return true
      end
    end

    document.search("//p[@class='TXT12']").each do |item|
      if item.value =~ /システムの問題により、/
        return true
      end
    end
    return false
  end

  #Get the user id from members page.
  def get_member(community_id)
    user_list = Array.new()
    now_page = next_page = 1
    begin 
      community_member_url = COMMUNITY_MEMBER_URL + community_id + "?page=" + now_page.to_s
      i = users_count = 0
      while users_count == 0 do
        response = get_response(community_member_url)
        response.force_encoding("utf-8")
        document = Nokogiri.HTML(response)
        document.search("//div[@class='mb16p4']//p[@class='error_description']").each do |item|
          return user_list if item.text =~ /削除された/
        end
        if has_error_of_member_page?(document) then
          i += 1
          sleep(1)
          if i >= 10 
            get_join_community_list.each do |community_id| 
              leave_community(community_id)
            end
            raise "not login"
          end
          next
        end

        pattern = /user\/(\d+)/
        #get the users id
        document.search("//div[@class='memberItem']//p[3]//a[1]").each do |item|
          user_url = item["href"]
          user_id = pattern.match(user_url)
          user_list.push(user_id[1])
          users_count += 1
        end

        i += 1
        if i >= 10 && users_count == 0 then
          p "Failed to get members"
          response.split("\n").each do |line|
            p line
          end
          raise "not in community error"
        end
      end 

      #get the page link number
      document.search("//div[@class='pagelink']//a[@class='num']").each do |item|
        next_page = Integer(item.text) if next_page < Integer(item.text)
      end
      now_page += 1
    end while now_page <= next_page
    return user_list
  end

  #check if already joined.
  def community_join?(community_id)
    community_url = COMMUNITY_PARTICIPATION_URL + community_id
    response = get_response(community_url)
    response.force_encoding("utf-8")
    response.split("\n").each do |line|
      if line =~ /<p class=\"error_description\">\n*[\t\s]*このコミュニティには、すでに参加しています。/
        return true
      elsif line =~ /このコミュニティには、すでに参加申請を送信しています/
        retract_join_request()
        return false
      end
    end
    return false
  end

  def retract_join_request()
    contact_url = JOIN_REQUEST_URL
    response = get_response(contact_url)
    response.force_encoding("utf-8")
    document = Nokogiri.HTML(response)
    pattern_contact = /my_contact\/(\d+)/
    pattern_form = /\/(edit_group_contact\/co\d+\/\d+)/
    contacts = Array.new
    document.search("//table//tr//td//p//a").each do |a|
      contact_url = a["href"]
      if contact_url =~ pattern_contact
        contact_id = $1
        next if contacts.include?(contact_id)
        contacts.push(contact_id)
        res = get_response(JOIN_REQUEST_URL + contact_id)
        res.force_encoding("utf-8")
        doc = Nokogiri.HTML(res)
        doc.search("//form").each do |form|
          next unless form["action"] =~ pattern_form
          post_data = {:mode=>"cancel"}
          response = get_response(COMMUNITY_URL + $1, post_data)
        end
      end
    end	
  end

  def exist_community?(community_id)
    community_url = COMMUNITY_TOP_URL + community_id
    response = get_response(community_url)
    response.force_encoding("utf-8")
    response.split("\n").each do |line|
      if line =~ /お探しのコミュニティは存在しないか、削除された可能性があります。/
        return false
      elsif line =~ /このコミュニティは以下の理由のため、削除されました。/
        return false
      elsif line =~ /ページが見つかりませんでした/
        return false
      elsif line =~ /<strong>(\d+)<\/strong> 人 /
        p "There are #{$1} people in #{community_id}."
      elsif line =~ /短時間での連続アクセスはご遠慮ください/
        p "短時間での連続アクセスはご遠慮ください"
      end
    end
    return true
  end

  def join_community(community_id)
    community_url = COMMUNITY_PARTICIPATION_URL + community_id

    #Go to the application screen of community participation,
    #determine whether the automatic approval.
    response = get_response(community_url)
    response.force_encoding("utf-8")
    document = Nokogiri.HTML(response)
    document.search("//div[@class='mb16p4']//p[@class='error_description']").each do |item|
      if item.text =~ /削除された/
        p "Not exist community : #{community_id}"
        return false
      end
    end
    confirm = response.split("\n").each do |line|
      #Not to participate if manual approval
      if line =~ /.+<input type=\"hidden\" name=\"mode\" value=\"(confirm)\">/
        p "Manual approval : #{community_id}"
        return false
      end
    end

    #Send a request for participation
    post_data = {"mode"=>"commit", :notify=>"", :title=>"", :comment=>""}
    response, location = get_response_location(community_url, post_data)
    #When the maximum number of participants, manual approval.
    puts "\033[31m#{location}\e[m" if location && location !~ /done/
    if location =~ /accept_fail=1/ then
      p "Manual approval : #{community_id}"
      retract_join_request()
      return false
    end
    return true
  end

  def leave_community(community_id)
    community_url = COMMUNITY_LEAVE_URL + community_id

    #Go to the leaving screen, determine whether already left community
    response = get_response(community_url)
    response.force_encoding("utf-8")
    time_stamp = commit_key = nil
    confirm = response.split("\n").each do |line|
      if line =~ /あなたはこのコミュニティのメンバーではありません。/
        return
      elsif line =~ /.*<input type=\"hidden\" name=\"time\" value=\"(\d+)\">/
        time_stamp = $1
      elsif line =~ /.*<input type=\"hidden\" name=\"commit_key\" value=\"([^\"]+)\">/
        commit_key = $1
      end
    end

    if time_stamp.nil? or commit_key.nil?
      p "Failed to get time_stamp or commit_key"
      return false
    end

    post_data = {:time => time_stamp, :commit_key => commit_key, :commit => "test"}
    response = get_response(community_url, post_data)
    response = get_response(community_url)
    response.force_encoding("utf-8")
    response.split("\n").each do |line|
      if line =~ /あなたはこのコミュニティのメンバーではありません。 /
        return true
      end
    end
    return false
  end

  #get community list
  def get_join_community_list()
    response = get_response(COMMUNITY_URL + "community")
    response.force_encoding("utf-8")
    document = Nokogiri.HTML(response)
    pattern = /community\/(co\d+)/
    #get the community id
    com_list = Array.new
    document.search("//div[@class='com_frm']//a[1]").each do |item|
      com_url = item["href"]
      com_id = pattern.match(com_url)
      com_list.push(com_id[1])
    end
    return com_list
  end

  def get_response(url, post_data = nil)
    response, location = get_response_location(url, post_data)
    return response
  end

  #Issue the Web request, obtain the response.
  def get_response_location(url, post_data = nil)
    attempts = 0
    begin
      wait_time = 0
      unless @last_access_time.nil?
        wait_time = API_WAIT_TIME - (Time.now - @last_access_time)
        sleep(wait_time) if wait_time > 0
      end
      p url
      @last_access_time = Time.now
      uri = URI.parse(url)
      path = uri.path
      path += "?" + uri.query unless uri.query.nil?
      response_string = nil
      Net::HTTP.version_1_2
      if(!post_data.nil?) then
        http = Net::HTTP.new(uri.host, uri.port)
        http.start do |access|
          req = Net::HTTP::Post.new(path)
          req["User-Agent"] = USER_AGENT
          req["Referer"] = uri
          req["Cookie"] = "user_session=#{@session}"
          req.set_form_data(post_data)
          response = access.request(req)
          puts "\e[31m#{response.code} #{response['location']}\e[m" unless response.code != 302
          if(response['location'] =~ /secure/) then
            @error_type = ErrorType::NOTLOGIN
          end
          return response.read_body, response['location']
        end
      else
        Net::HTTP.start(uri.host, uri.port) do |access|
          response = access.get(path, "Referer" => url,
                                "Cookie" => "user_session=#{@session}")
          if(response['location'] =~ /secure/) then
            @error_type = ErrorType::NOTLOGIN
          end
          return response.body, response['location']
        end
      end
    rescue Timeout::Error => e
      printException(e)
      p "(Retrying)"
      attempts += 1
      retry if attempts <= 5
    end
  end
end

def printException(e)
  puts "Exception : #{e.class}; #{e.message}\n\t#{e.backtrace.join("\n\t")}"
end

if ARGV[0] =~ /c*o*(\d+)/ then
  next_community_number = $1.to_i
else
  p "usage: ruby nico.rb COMMUNIRY_NUMBER(orID)"
  exit
end

client = NicoClient.new

unless client.login then
  puts 'login failed'
  exit
end

#client.retract_join_request()
#exit
#client.get_join_community_list.each do |community_id| 
#	client.leave_community(community_id)
#end
#exit

redis = Redis.new

begin
  community_id = "co" + next_community_number.to_s
  attempts = 0
  begin
    if client.exist_community?(community_id) then
      client.get_community_member(community_id).sort.each do |user_id|
        redis.sadd community_id, user_id unless user_id == USER_ID
      end
    end
    if next_community_number % 200 == 0 then 
      client.get_join_community_list.each do |community_id| 
        client.leave_community(community_id)
      end
    end
  rescue Timeout::Error, StandardError => e
    printException(e)
    client.login if client.error_type == ErrorType::NOTLOGIN
    p "(Retrying)"
    attempts += 1
    retry if attempts <= 5
  end
  next_community_number += 1
end while next_community_number < LATEST_COMMUNITY_NUMBER 


#redis.smembers(community_id).each do |user_id|
#	p user_id
#end


