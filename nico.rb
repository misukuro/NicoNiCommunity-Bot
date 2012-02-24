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
LATEST_COMMUNITY_NUMBER = 1539038 

API_WAIT_TIME = 1.00
NICO_LOGIN_URL = "https://secure.nicovideo.jp/secure/login?site=niconico"
COMMUNITY_URL = "http://com.nicovideo.jp/"
COMMUNITY_PARTICIPATION_URL = COMMUNITY_URL + "motion/"
COMMUNITY_LEAVE_URL = COMMUNITY_URL + "leave/"
COMMUNITY_MEMBER_URL = COMMUNITY_URL + "member/"
COMMUNITY_TOP_URL = COMMUNITY_URL + "community/"
JOIN_REQUEST_URL = "http://com.nicovideo.jp/my_contact"
EDIT_CONTACT_URL = COMMUNITY_URL + "edit_group_contact/"

#The Class to connect to NicoNico
class NicoClient
	attr_accessor :session, :last_access_time

	def login()
		uri = URI.parse(NICO_LOGIN_URL)
		Net::HTTP.version_1_2
		http = Net::HTTP.new(uri.host, uri.port)
		if(uri.port == 443)
			http.use_ssl = true
			http.ca_file = "./nico.cer"
			http.verify_mode = OpenSSL::SSL::VERIFY_PEER
			http.verify_depth = 5
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
			end while community_join?(community_id) && attempts <= 3
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

				if has_error_of_member_page?(document) then
					i += 1
					sleep(1)
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
				if i <= 10 && users_count == 0 then
					p "Failed to get members"
					response.split("\n").each do |line|
						p line
					end
					p "test"
					raise "not in community error"
				end
			end 
			p users_count.to_s + " users was registed." unless users_count == 35

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
#				retract_join_request(community_id)
				return false
			end
		end
		return false
	end
=begin
	def retract_join_request(community_id)
		p "retract"
		contact_url = JOIN_REQUEST_URL
		community_url = COMMUNITY_PARTICIPATION_URL + community_id
		response = get_response(community_url)
		response.force_encoding("utf-8")
		contact_id = 0
		document = Nokogiri.HTML(response)
		pattern_community = /community\/(co\d+)/
		pattern_contact = /my_contact\/(\d+)/
		document.search("//table//tr//td//p").each do |p|
			p.search("a[1]").each do |a|
				community_url = a["href"]
				if community_url =~ pattern_community
					if $1 == community_id
						a = item.search("a[2]")
						raise "invalid html" if a.empty?
						contact_url = a["href"]
						if contact_url =~ pattern_contact
							contact_id = $1
							p "retract"
						end
					end
				end
			end
		end	
		unless contact_id == 0
			p "retract"
			post_data = {:mode=>"cancel"}
			get_response(EDIT_CONTACT_URL + "#{community_id}/#{contact_id}", post_data)
		end
	end
=end
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
			return false
		end
		response.force_encoding("utf-8")
		document = Nokogiri.HTML(response)
		document.search("//div[@class='body']").each do |item|
			if item =~ /参加申請を送りました/
				#retract_join_request(community_id)
				return false
			end
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
					req["User-Agent"] = "katoken@morimati.info"
					req["Referer"] = uri
					req["Cookie"] = "user_session=#{@session}"
					req.set_form_data(post_data)
					response = access.request(req)
					puts "\e[31m#{response.code} #{response['location']}\e[m" unless response.code != 302
					return response.read_body, response['location']
				end
			else
				Net::HTTP.start(uri.host, uri.port) do |access|
					response = access.get(path, "Referer" => url,
										 "Cookie" => "user_session=#{@session}")
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
	rescue Timeout::Error, StandardError => e
		printException(e)
		p "(Retrying)"
		attempts += 1
		retry if attempts <= 5
	end
	next_community_number += 1
end while next_community_number < LATEST_COMMUNITY_NUMBER 


#redis.smembers(community_id).each do |user_id|
#	p user_id
#end


