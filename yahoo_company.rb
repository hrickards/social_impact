require 'open-uri/cached'
require 'nokogiri'
require 'sanitize'
require 'json'

DETAILS_URL = "http://query.yahooapis.com/v1/public/yql"

class YahooCompany
  attr_accessor :data

  def initialize name
    @name = name
    @data = {}

    get_ticker
    get_stocks unless @ticker.nil?
  end

  protected
  def get_ticker
    url = "http://d.yimg.com/autoc.finance.yahoo.com/autoc?query=#{URI.escape @name}&callback=YAHOO.Finance.SymbolSuggest.ssCallback"
    jsonp = open(url).read
    data = JSON.parse jsonp[/{.+}/]
    @ticker = data["ResultSet"]["Result"].first["symbol"]
  end

  def get_stocks
    query = "select * from yahoo.finance.quotes where symbol in ('#{@ticker}')"
    url = "#{DETAILS_URL}?q=#{URI.encode query}&format=json&env=http://datatables.org/alltables.env"
    data = get_cached url
    @data = data["query"]["results"]["quote"]
  end
end