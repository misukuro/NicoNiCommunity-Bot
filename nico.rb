# -*- encoding: utf-8 -*-
require "net/https"
require "uri"
require "socket"
require "rubygems"
require "nokogiri"
require "rexml/document"

module OpenSSL
	module SSL
		remove_const :VERIFY_PEER
	end
end
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

NICO_ID = ""
NICO_PASS = ""
API_WAIT_TIME = 0.50
NICO_LOGIN_URL = "https://secure.nicovideo.jp/secure/login?site=niconico"
COMMUNITY_URL = "http://com.nicovideo.jp/"
COMMUNITY_PARTICIPATION_URL = COMMUNITY_URL + "motion/"
COMMUNITY_LEAVE_URL = COMMUNITY_URL + "leave/"
COMMUNITY_MEMBER_URL = COMMUNITY_URL + "member/"

#The Class to connect the NicoNico
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
			req["User-Agent"] = "katoken@morimati.info"
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
		unless community_join?(community_id) then
			join_community(community_id)
		end

		#get the members
		now_page = 1
		next_page = 1
		user_list = Array.new()
		begin 
			community_member_url = COMMUNITY_MEMBER_URL + community_id + "?page=" + now_page.to_s
			response = get_response(community_member_url)
			response.force_encoding("utf-8")
			document = Nokogiri.HTML(response)
			pattern = /user\/(\d+)/
			#get the users id
			document.search("//div[@class='memberItem']//p[3]//a[1]").each do |item|
				user_url = item["href"]
				user_id = pattern.match(user_url)
				user_list.push(user_id[1])
			end
			#get the page link number
			document.search("//div[@class='pagelink']//a[@class='num']").each do |item|
				next_page = Integer(item.text) if next_page < Integer(item.text)
			end
			now_page += 1
		end while now_page <= next_page 

		#leave the community
		leave_community(community_id)
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
			end
		end
		return false
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
				return
			end
		end

		#Send a request for participation
		post_data = {"mode"=>"commit", :notify=>"", :title=>"", :comment=>""}
		get_response(community_url, post_data);
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
			return
		end

		post_data = {:time => time_stamp, :commit_key => commit_key, :commit => "test"}
		response = get_response(community_url, post_data)
	end

	#Issue the Web request, obtain the response.
	def get_response(url, post_data = nil)
		wait_time = 0
		unless @last_access_time.nil?
			wait_time = API_WAIT_TIME - (Time.now - @last_access_time)
			sleep(wait_time) if wait_time > 0
		end
		p "#{Integer(wait_time * 1000)}" + " " + url
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
				response_string =  response.read_body
			end
		else
			Net::HTTP.start(uri.host, uri.port) do |access|
				response = access.get(path, "Referer" => url,
									 "Cookie" => "user_session=#{@session}")
				response_string =  response.body
			end
		end

		return response_string
	end
end

client = NicoClient.new()

if(client.login() == false) then
	puts 'login failed'
	exit
end

community_id = "co1280039"
user_list = client.get_community_member(community_id)
user_list.sort.each do |user_id|
	p user_id
end
