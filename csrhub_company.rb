require 'open-uri/cached'
require 'json'
require 'babosa'
require 'parallel'
require 'yaml'

require_relative 'libs'
require_relative 'yahoo_company'
require_relative 'glassdoor'
require_relative 'mission_dump'
require_relative 'wesoc'

HASH_FILES = ["csrhub_company.rb", "csrhub.yml"]

require 'mongo'
include Mongo
$mongo = MongoClient.new("localhost", 27017)
$db = $mongo["social_impact"]
filehash= Digest::MD5.hexdigest(HASH_FILES.map { |f| File.read(f) }.join("\n"))
$coll = $db["csrhub_#{filehash}"]
$coll.create_index "search"

PROFILE_ID = "467"
BASE_URL = "https://www.csrhub.com/rest"

DATASOURCES = YAML.load_file 'csrhub.yml'
CONFIG = YAML.load_file 'config.yml'
API_KEY = CONFIG["CSRHUB_API_KEY"]

API_FIELDS = %w{search name website csrsite page ratings address basic_ratings special_issues financial reviews mission_statement mission_statement_investigator mission_statement_proof news_sources twitter} + DATASOURCES.keys

# SEARCH_FILTERS = %w{overall community employees environment governance board product} + ["community dev & philanthropy", "compensation & benefits", "diversity & labor rights", "energy & climate change", "environment policy & reporting", "human rights & supply chain", "leadership ethics", "resource management", "training health & safety", "transparency & reporting"]
SEARCH_FILTERS = %w{overall community employees environment governance}
SEARCH_OPERATORS = %w{equal greater_than less_than greater_than_or_equal less_than_or_equal}

class CSRHubCompany
  attr_accessor :data, :resp

  def initialize params
    @name = params[:name]
    results = $coll.find({search: @name})

    if results.count == 0
      @data = {"search" => @name}

      search

      # TODO In parallel below
      datas = Parallel.map([self.method(:get_details), self.method(:get_data_values), self.method(:get_financial_details), self.method(:get_reviews), self.method(:get_missiondump_data), self.method(:get_wesoc)]) do |f|
        f.call
      end
      datas.each { |data| @data.merge! data unless data.nil? }

      @data["name"] = @name if @data["name"].nil?

      $coll.insert(@data)
      puts "Saving"
    else
      puts "Retrieving"
      @data = results.first
      @data.delete "_id"
    end

    @resp = {}
    API_FIELDS.each { |f| @resp[f] = @data[f] }
    @resp = format_output @resp
  end

  # Find all companies in a certain category
  def self.in_category(category)
    category = category.gsub "&", "and"
    category = category.gsub /[^0-9a-z ]/i, ""
    category = category.split.join(" ") # Remove duplicate spaces
    category = category.gsub " ", "-"
    data = get_cached build_api_url("search/industry:#{URI.escape category}")
    data["companies"].map do |company|
      {
        name: company["name"],
        website: company["website"],
        ratings: company["ratings"],
        url: $api_root + "/api/companies/#{URI.escape company['name']}"
      }
    end
  end

  # Search all companies
  def self.search(filters)
    filter_string = []
    filters.each do |filter|
      rating = filter[:filter]
      rating.gsub! "&", "and"
      rating.gsub! " ", "-"

      filter_string << "#{rating}:#{filter[:operator]}:#{filter[:value]}"
    end
    filter_string = filter_string.join ":"

    # Proxy straight through to CSRHub
    puts build_api_url("search/#{filter_string}").inspect
    results = get_cached build_api_url("search/#{filter_string}")
    results["companies"].map do |company|
      {
        name: company["name"],
        website: company["website"],
        ratings: company["ratings"],
        url: $api_root + "/api/companies/#{URI.escape company['name']}"
      }
    end
  end

  # Possible search filters
  def self.search_filters
    SEARCH_FILTERS.map do |filter|
      {
        name: filter,
        url: $api_root + "/api/companies/search/#{URI.escape filter}"
      }
    end
  end

  # Possible search operators
  def self.search_operators(filter)
    SEARCH_OPERATORS.map do |operator|
      {
        name: operator,
        base_url: $api_root +  "/api/companies/search/#{URI.escape filter}/#{URI.escape operator}/",
        example_url: $api_root +  "/api/companies/search/#{URI.escape filter}/#{URI.escape operator}/50"
      }
    end
  end

  protected
  # Find company on CSRHub
  def search
    puts search_url
    data = get_cached search_url
    company = data["companies"].first
    return {} if company.nil?
    @alias = company["alias"]

    @data.merge! company
  end

  # CSRHub API search url
  def search_url
    unless @name.nil?
      CSRHubCompany.build_api_url "search/name:#{URI.escape @name}"
    else
      raise CSRHubSearchException
    end
  end

  # CSRHub API details url
  def details_url
    CSRHubCompany.build_api_url "company/#{@alias}"
  end

  # Get CSRHub /company details endpoint
  def get_details
    return {} if @alias.nil?
    puts details_url
    data = get_cached details_url
    puts "ddone"
    data
  end

  # Get data values one by one
  def get_data_values
    return {} if @alias.nil?
    final_data = {}

    base = "value/company:#{@alias}"
    DATASOURCES.each do |datasource_slug, info|
      final_data[datasource_slug] = {name: info["name"]} unless final_data.include? datasource_slug
      datasource = info["name"]
      elements = info["values"]

      elements.each do |slug, element|
        url = CSRHubCompany.build_api_url "value/company:#{@alias}:datasource:#{URI.escape datasource}:element:#{URI.escape element}"
        puts url
        data = get_cached url
        final_data[datasource_slug][slug.to_s] = {name: element, value: data["Value"]}
      end
    end
    puts "dvdone"

    final_data
  end

  def self.build_api_url endpoint
    "#{BASE_URL}/#{endpoint}/#{PROFILE_ID}/json/?key=#{API_KEY}"
  end

  # Use YahooCompany to get financial details
  def get_financial_details
    data = {}
    yc = YahooCompany.new @name
    data["financial"] = yc.data
    puts "ydone"

    data
  end

  # Use Glassdoor to get employee reviews
  def get_reviews
    {
      "reviews" => Glassdoor.scrape(@name)
    }
  end

  # Get data from MissionDump API
  def get_missiondump_data
    md = MissionDump.new @name
    md.data
  end

  # Twitter
  def get_wesoc
    ws = WeSoc.new @name
    ws.data
  end

  # TODO Is there not a gem that can do this in a less hackish, less likely
  # to break way?
  def format_output data
    if data.is_a? Hash
      return Hash[data.map { |k, v| [k, format_output(v)] }]
    elsif data.is_a? Array
      return data.map { |x| format_output(x) }
    elsif data.is_a? String
      datai = data.to_i
      dataf = data.to_f
      if data == "N/A" or data == "NA" or data == "-" or data == ""
        return nil
      elsif datai.to_s == data
        return datai
      elsif dataf != 0 or data == ("0." + "0"*(data.length<2 ? 0 : data.length-2))
        return dataf
      # TODO Ugly!!
      elsif data =~ /(N\/A|[\d+\-%]*) +- +(N\/A|[\d+\-%\.]*)/i
        groups = data.match /(N\/A|[\d+\-%]*) +- +(N\/A|[\d+\-%\.]*)/i
        return format_output [groups[1], groups[2]]
      elsif data[0] == "+"
        num = format_output(data[1..-1])
        if num.is_a? String
          return data
        else
          return num
        end
      elsif data[0] == "-"
        num = format_output(data[1..-1])
        unless num.is_a? Integer or num.is_a? Float
          return data
        else
          return -num
        end
      else
        data.gsub! /<b>(.*)<\/b>/i, '\1'
        data.gsub! "&nbsp;", ""
        return data
      end
    else
      return data
    end
  end
end

class CSRHubSearchException < Exception
end
