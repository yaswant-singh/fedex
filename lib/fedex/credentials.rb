require 'fedex/helpers'

module Fedex
  class Credentials
    include Helpers
    attr_reader :account_number, :mode, :grant_type, :client_id, :client_secret

    # In order to use Fedex rates API you must first apply for a developer(and later production keys),
    # Visit {http://www.fedex.com/us/developer/ Fedex Developer Center} for more information about how to obtain your keys.
    # @param [String] account_number - Fedex account_number
    # @param [String] mode - [development/production]
    #
    # return a Fedex::Credentials object
    def initialize(options={})
      requires!(options, :account_number, :mode, :grant_type, :client_id, :client_secret)
      @account_number = options[:account_number]
      @mode = options[:mode]

      #New parameters
      @grant_type = options[:grant_type]
      @client_id = options[:client_id]
      @client_secret = options[:client_secret]
    end
  end
end