require 'httparty'
require 'nokogiri'
require 'fedex/helpers'
require 'fedex/rate'

module Fedex
  module Request
    class Base
      include Helpers
      include HTTParty
      read_timeout 5 # always have timeouts!
      # If true the rate method will return the complete response from the Fedex Web Service
      attr_accessor :debug
      # Fedex Text URL
      # TEST_URL = "https://wsbeta.fedex.com:443/xml/"
      TEST_URL = "https://apis-sandbox.fedex.com"

      # Fedex Production URL
      # PRODUCTION_URL = "https://ws.fedex.com:443/xml/"
      PRODUCTION_URL = "https://apis.fedex.com"

      # List of available Service Types
      SERVICE_TYPES = %w(EUROPE_FIRST_INTERNATIONAL_PRIORITY FEDEX_1_DAY_FREIGHT FEDEX_2_DAY FEDEX_2_DAY_AM FEDEX_2_DAY_FREIGHT FEDEX_3_DAY_FREIGHT FEDEX_EXPRESS_SAVER FEDEX_FIRST_FREIGHT FEDEX_FREIGHT_ECONOMY FEDEX_FREIGHT_PRIORITY FEDEX_GROUND FIRST_OVERNIGHT GROUND_HOME_DELIVERY INTERNATIONAL_ECONOMY INTERNATIONAL_ECONOMY_FREIGHT INTERNATIONAL_FIRST INTERNATIONAL_PRIORITY INTERNATIONAL_PRIORITY_FREIGHT PRIORITY_OVERNIGHT SMART_POST STANDARD_OVERNIGHT)

      # List of available Packaging Type
      PACKAGING_TYPES = %w(FEDEX_10KG_BOX FEDEX_25KG_BOX FEDEX_BOX FEDEX_ENVELOPE FEDEX_PAK FEDEX_TUBE YOUR_PACKAGING)

      # List of available DropOffTypes
      DROP_OFF_TYPES = %w(BUSINESS_SERVICE_CENTER DROP_BOX USE_SCHEDULED_PICKUP REQUEST_COURIER STATION REGULAR_PICKUP CONTACT_FEDEX_TO_SCHEDULE DROPOFF_AT_FEDEX_LOCATION)

      # Clearance Brokerage Type
      CLEARANCE_BROKERAGE_TYPE = %w(BROKER_INCLUSIVE BROKER_INCLUSIVE_NON_RESIDENT_IMPORTER BROKER_SELECT BROKER_SELECT_NON_RESIDENT_IMPORTER BROKER_UNASSIGNED)

      # Recipient Custom ID Type
      RECIPIENT_CUSTOM_ID_TYPE = %w(COMPANY INDIVIDUAL PASSPORT)

      # List of available Payment Types
      PAYMENT_TYPE = %w(RECIPIENT SENDER THIRD_PARTY)

      # List of available Carrier Codes
      CARRIER_CODES = %w(FDXC FDXE FDXG FDCC FXFR FXSP)

      # In order to use Fedex rates API you must first apply for a developer(and later production keys),
      # Visit {http://www.fedex.com/us/developer/ Fedex Developer Center} for more information about how to obtain your keys.
      # @param [String] key - Fedex web service key
      # @param [String] password - Fedex password
      # @param [String] account_number - Fedex account_number
      # @param [String] meter - Fedex meter number
      # @param [String] mode - [development/production]
      #
      # return a Fedex::Request::Base object
      def initialize(credentials, options={})
        requires!(options, :shipper, :recipient, :packages)
        @credentials = credentials
        @shipper, @recipient, @packages, @service_type, @customs_clearance_detail, @debug = options[:shipper], options[:recipient], options[:packages], options[:service_type], options[:customs_clearance_detail], options[:debug]
        @origin = options[:origin]
        @debug = ENV['DEBUG'] == 'true'
        @shipping_options =  options[:shipping_options] ||={}
        @payment_options = options[:payment_options] ||={}
        requires!(@payment_options, :type, :account_number, :name, :company, :phone_number, :country_code) if @payment_options.length > 0
        if options.has_key?(:mps)
          @mps = options[:mps]
          requires!(@mps, :package_count, :total_weight, :sequence_number)
          requires!(@mps, :master_tracking_id) if @mps.has_key?(:sequence_number) && @mps[:sequence_number].to_i >= 2
        else
          @mps = {}
        end
        # Expects hash with addr and port
        if options[:http_proxy]
          self.class.http_proxy options[:http_proxy][:host], options[:http_proxy][:port]
        end
      end

      # Sends post request to Fedex web service and parse the response.
      # Implemented by each subclass
      def process_request
        raise NotImplementedError, "Override process_request in subclass"
      end

      private

      def token_body
        {
          client_id: @credentials.client_id,
          client_secret: @credentials.client_secret,
          grant_type: @credentials.grant_type
        }
      end

      # A post to the Fedex to get a bearer token .  In this example
      # See here for more information https://developer.fedex.com/api/en-cn/catalog/authorization/v1/docs.html
      #
      def bearer_token
        begin
          response = HTTParty.post("#{api_url}/oauth/token", body: token_body)
          case response.code
          when 200
            JSON.parse(response.body)['access_token']
          else
            Rails.logger.error(response["errors"][0]["message"])
            raise Exception.new(response["errors"][0]["message"])
          end
        rescue HTTParty::Error, SocketError, Timeout::Error => e
          false
        end
      end

      def get_cached_bearer_token
        test_mode = @credentials.mode == "development"
        token = Rails.cache.read("fedex-ship-bearer-token") if !test_mode
        if token.nil?
          token = bearer_token
          create_bearer_token_cached(token) if token && !test_mode
        end
        token
      end

      def create_bearer_token_cached(token)
        Rails.cache.write("fedex-ship-bearer-token", token, expires_in: 45.minutes)
      end

      # Add shipper to xml request
      def add_shipper
        {
          "address": {
            "streetLines": address_lines(Array(@shipper[:address])).compact,
            "city": @shipper[:city],
            "stateOrProvinceCode": @shipper[:state],
            "postalCode": @shipper[:postal_code],
            "countryCode": @shipper[:country_code],
            "residential": false
          },
          "contact": {
            "personName": @shipper[:name],
            "phoneNumber": @shipper[:phone_number],
            "companyName": @shipper[:company]
          }
        }

      end

      def address_lines(arr)
        arr.take(2).map{|address_line| address_line}
      end


      # Add shipper to xml request
      def add_origin
        if @origin
          {
            "address": {
              "streetLines": address_lines(Array(@origin[:address])),
              "city": @origin[:city],
              "stateOrProvinceCode": @origin[:state],
              "postalCode": @origin[:postal_code],
              "countryCode": @origin[:country_code],
              "residential": false
            },
            "contact": {
              "personName": @origin[:name],
              "phoneNumber": @origin[:phone_number],
              "companyName": @origin[:company]
            }
          }
        end
      end

      # Add recipient to xml request
      def add_recipient
        [
          {
            "address": {
              "streetLines": address_lines(Array(@recipient[:address])),
              "city": @recipient[:city],
              "stateOrProvinceCode": @recipient[:state],
              "postalCode": @recipient[:postal_code],
              "countryCode": @recipient[:country_code],
              "residential": false
            },
            "contact": {
              "personName": @recipient[:name],
              "phoneNumber": @recipient[:phone_number],
              "companyName": @recipient[:company]
            }
          }
        ]

      end

      # Add shipping charges to xml request
      def add_shipping_charges_payment
        {
          "paymentType": @payment_options[:type] || "SENDER",
          "payor": add_payor
        }
      end

      def add_payor
        if service[:version].to_i >= Fedex::API_VERSION.to_i
          {
            "responsibleParty": {
              "contact": {
                "personName": @payment_options[:name] || @shipper[:name],
                "phoneNumber": @payment_options[:phone_number] || @shipper[:phone_number],
                "companyName": @payment_options[:company] || @shipper[:company]
              },
              "accountNumber": {
                "value": @payment_options[:account_number] || @credentials.account_number
              }
            }
          }
        else
          {
            "accountNumber": {
              "value": @payment_options[:account_number] || @credentials.account_number
            }
          }
        end
      end

      # Add Master Tracking Id (for MPS Shipping Labels, this is required when requesting labels 2 through n)
      def add_master_tracking_id
        if @mps.has_key? :master_tracking_id
          {
            "trackingIdType" => @mps[:master_tracking_id][:tracking_id_type],
            "trackingNumber" => @mps[:master_tracking_id][:tracking_number]
          }
        end
      end

      # Add packages to xml request
      def add_packages(request_body)
        request_body = JSON.parse(request_body.to_json)
        package_count = @packages.size
        if @mps.has_key? :package_count
          request_body["requestedShipment"]["totalPackageCount"] = @mps[:package_count]
        else
          request_body["requestedShipment"]["totalPackageCount"] = package_count
        end
        request_body["requestedShipment"]["requestedPackageLineItems"] = []
        @packages.each do |package|
          new_object = {}
          if @mps.has_key? :sequence_number
            new_object["sequenceNumber"] = @mps[:sequence_number]
          else
            new_object = {"groupPackageCount" => 1}
          end

          # For commented nodes I have checked and compared those nodes in old and new document and didn't find any relatable node. So, I kept them commented. These do not have any impact on our integration as we are not having any relation  with these nodes in our application.
          if package[:insured_value]
            # xml.InsuredValue{
            #   xml.Currency package[:insured_value][:currency]
            #   xml.Amount package[:insured_value][:amount]
            # }
          end
          new_object["weight"] = {"units" => package[:weight][:units], "value" => package[:weight][:value]}
          if package[:dimensions]
            new_object["dimensions"] = {
              "length" => package[:dimensions][:length],
              "width" => package[:dimensions][:width],
              "height" => package[:dimensions][:height],
              "units" => package[:dimensions][:units]
            }
          end
          new_object = add_customer_references(new_object, package)
          if package[:special_services_requested]
            if package[:special_services_requested][:special_service_types]
              if package[:special_services_requested][:special_service_types].is_a? Array
                new_object["packageSpecialServices"] = {"specialServiceTypes" => package[:special_services_requested][:special_service_types]}
              else
                new_object["packageSpecialServices"] = {"specialServiceTypes" => [package[:special_services_requested][:special_service_types]]}
              end
            end
            # Handle COD Options
            if package[:special_services_requested][:cod_detail]
              new_object["packageSpecialServices"]["packageCODDetail"] = {"codCollectionAmount" => {
                  "amount" => package[:special_services_requested][:cod_detail][:cod_collection_amount][:amount],
                  "currency" => package[:special_services_requested][:cod_detail][:cod_collection_amount][:currency]
                }
              }
              # For commented nodes I have checked and compared those nodes in old and new document and didn't find any relatable node. So, I kept them commented. These do not have any impact on our integration as we are not having any relation  with these nodes in our application.
              if package[:special_services_requested][:cod_detail][:add_transportation_charges]
                # xml.AddTransportationCharges package[:special_services_requested][:cod_detail][:add_transportation_charges]
              end
              # xml.CollectionType package[:special_services_requested][:cod_detail][:collection_type]
              # xml.CodRecipient {
              #   # add_shipper
              # }
              if package[:special_services_requested][:cod_detail][:reference_indicator]
                # xml.ReferenceIndicator package[:special_services_requested][:cod_detail][:reference_indicator]
              end
            end
            # DangerousGoodsDetail goes here
            if package[:special_services_requested][:dry_ice_weight]
              new_object["packageSpecialServices"]["dryIceWeight"] = {
                "units" => package[:special_services_requested][:dry_ice_weight][:units],
                "value" => package[:special_services_requested][:dry_ice_weight][:value]
              }
            end
            if package[:special_services_requested][:signature_option_detail]
              new_object["packageSpecialServices"]["signatureOptionType"] = package[:special_services_requested][:signature_option_detail][:signature_option_type]
            end
            if package[:special_services_requested][:priority_alert_detail]
              # xml.PriorityAlertDetail package[:special_services_requested][:priority_alert_detail]
              new_object["packageSpecialServices"]["priorityAlertDetail"] = {
                "enhancementTypes": [ package[:special_services_requested][:priority_alert_detail] ],
                "content": [ "string" ]
              }
            end
          end
          request_body["requestedShipment"]["requestedPackageLineItems"] << new_object
        end
        return request_body
      end

      def add_customer_references(package_body, package)
        # customer_refrences is a legacy misspelling
        if refs = package[:customer_references] || package[:customer_refrences]
          refs.each do |ref|
            if ref.is_a?(Hash)
              # :type can specify custom type:
              #
              # BILL_OF_LADING, CUSTOMER_REFERENCE, DEPARTMENT_NUMBER,
              # ELECTRONIC_PRODUCT_CODE, INTRACOUNTRY_REGULATORY_REFERENCE,
              # INVOICE_NUMBER, P_O_NUMBER, RMA_ASSOCIATION,
              # SHIPMENT_INTEGRITY, STORE_NUMBER
              package_body["customerReferences"] = [{"customerReferenceType" => ref[:type], "value" => ref[:value]}]
            else
              package_body["customerReferences"] = [{"customerReferenceType" => 'CUSTOMER_REFERENCE', "value" => ref}]
            end
          end
        end
        return package_body
      end

      # Add customs clearance(for international shipments)
      def add_customs_clearance
        # xml.CustomsClearanceDetail{
        #   hash_to_xml(xml, @customs_clearance_detail)
        # }
        @customs_clearance_detail if @customs_clearance_detail
      end

      # Fedex Web Service Api
      def api_url
        @credentials.mode == "production" ? PRODUCTION_URL : TEST_URL
      end

      # Build xml Fedex Web Service request
      # Implemented by each subclass
      def build_xml
        raise NotImplementedError, "Override build_xml in subclass"
      end

      # Build xml nodes dynamically from the hash keys and values
      def hash_to_xml(xml, hash)
        hash.each do |key, value|
          key_s_down = key.to_s.downcase
          if key_s_down.match(/^commodities_\d{1,}$/)
            element = 'Commodities'
          elsif key_s_down.match(/^masked_data_\d{1,}$/)
            element = 'MaskedData'
          else
            element = camelize(key)
          end
          if value.is_a?(Hash)
            xml.send element do |x|
              hash_to_xml(x, value)
            end
          elsif value.is_a?(Array)
            value.each do |v|
              xml.send element do |x|
                hash_to_xml(x, v)
              end
            end
          else
            xml.send element, value
          end
        end
      end

      # Parse response, convert keys to underscore symbols
      def parse_response(response)
        response = sanitize_response_keys(response.parsed_response)
      end

      # Recursively sanitizes the response object by cleaning up any hash keys.
      def sanitize_response_keys(response)
        if response.is_a?(Hash)
          response.inject({}) { |result, (key, value)| result[underscorize(key).to_sym] = sanitize_response_keys(value); result }
        elsif response.is_a?(Array)
          response.collect { |result| sanitize_response_keys(result) }
        else
          response
        end
      end

      def service
        raise NotImplementedError,
          "Override service in subclass: {:id => 'service', :version => 1}"
      end

      # Use GROUND_HOME_DELIVERY for shipments going to a residential address within the US.
      def service_type
        if @recipient[:residential].to_s =~ /true/i and @service_type =~ /GROUND/i and @recipient[:country_code] =~ /US/i
          "GROUND_HOME_DELIVERY"
        else
          @service_type
        end
      end

      # Successful request
      def success?(response)
        (!response[:rate_reply].nil? and %w{SUCCESS WARNING NOTE}.include? response[:rate_reply][:highest_severity])
      end

    end
  end
end
