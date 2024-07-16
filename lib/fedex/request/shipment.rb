require 'fedex/request/base'

module Fedex
  module Request
    class Shipment < Base
      attr_reader :response_details

      def initialize(credentials, options={})
        super
        requires!(options, :service_type)
        # Label specification is required even if we're not using it.
        @label_specification = {
          :label_format_type => 'COMMON2D',
          :image_type => 'PDF',
          :label_stock_type => 'PAPER_LETTER'
        }
        @label_specification.merge! options[:label_specification] if options[:label_specification]
        @customer_specified_detail = options[:customer_specified_detail] if options[:customer_specified_detail]
      end

      # Sends post request to Fedex web service and parse the response.
      # A label file is created with the label at the specified location.
      # The parsed Fedex response is available in #response_details
      # e.g. response_details[:completed_shipment_detail][:completed_package_details][:tracking_ids][:tracking_number]
      def process_request
        headers = {
          "X-locale": "en_US",
          "Content-Type": "application/json",
          "authorization": "bearer #{get_cached_bearer_token}"
        }
        api_response = self.class.post "#{api_url}/ship/v1/shipments", :headers => headers, :body => build_body.to_json
        puts api_response if @debug
        if success?(api_response)
          success_response(api_response, api_response)
        else
          failure_response(api_response, api_response)
        end
      end

      private

      # Add information for shipments
      def build_body
        request_body = {
          "requestedShipment": {
            "shipDatestamp": @shipping_options[:ship_timestamp] ||= Time.now.utc.iso8601(2).to_date.strftime("%Y-%m-%d"),
            "pickupType": @shipping_options[:drop_off_type] ||= "USE_SCHEDULED_PICKUP",
            "serviceType": service_type,
            "packagingType": @shipping_options[:packaging_type] ||= "YOUR_PACKAGING",
            "shipper": add_shipper,
            "recipients": add_recipient,
            "shippingChargesPayment": add_shipping_charges_payment,
            "labelSpecification": add_label_specification,
            "rateRequestType": ["ACCOUNT"]
          }
        }
        request_body = add_packages(request_body)
        request_body["requestedShipment"]["totalWeight"] = @mps[:total_weight][:value] if @mps.has_key? :total_weight
        request_body["requestedShipment"]["origin"] = add_origin if @origin
        request_body["requestedShipment"]["shipmentSpecialServices"] = add_special_services if @shipping_options[:return_reason] || @shipping_options[:cod] || @shipping_options[:saturday_delivery]
        request_body["requestedShipment"]["customsClearanceDetail"] = add_customs_clearance if @customs_clearance_detail
        request_body["requestedShipment"]["masterTrackingId"] = add_master_tracking_id if @mps.has_key? :master_tracking_id
        request_body["labelResponseOptions"] = "LABEL"
        request_body["accountNumber"] = { "value" => @credentials.account_number }
        return request_body
      end

      def add_total_weight
        @mps[:total_weight][:value] if @mps.has_key? :total_weight
      end

      # Hook that can be used to add custom parts.
      def add_custom_components(xml)
        add_label_specification xml
      end

     # Add the label specification
      def add_label_specification
        label_object = {
          "labelFormatType": @label_specification[:label_format_type],
          "imageType": @label_specification[:image_type],
          "labelStockType": @label_specification[:label_stock_type]
        }
        label_object["customerSpecifiedDetail"] = @customer_specified_detail if @customer_specified_detail
        if @label_specification[:printed_label_origin] && @label_specification[:printed_label_origin][:address]
          label_object["printedLabelOrigin"] = {
            "address": {
              "streetLines": address_lines(Array(@label_specification[:printed_label_origin][:address][:address])),
              "city": @label_specification[:printed_label_origin][:address][:city],
              "stateOrProvinceCode": @label_specification[:printed_label_origin][:address][:state],
              "postalCode": @label_specification[:printed_label_origin][:address][:postal_code],
              "countryCode": @label_specification[:printed_label_origin][:address][:country_code],
              "residential": false
            },
            "contact": {
              "personName": @label_specification[:printed_label_origin][:address][:name],
              "phoneNumber": @label_specification[:printed_label_origin][:address][:phone_number],
              "phoneExtension": "+91",
              "companyName": @label_specification[:printed_label_origin][:address][:company]
            }
          }
        end
        return label_object
      end

      def add_customer_specific_details
        @customer_specified_detail if @customer_specified_detail
      end
      # For commented nodes I have checked and compared those nodes in old and new document and didn't find any relatable node. So, I kept them commented. These do not have any impact on our integration as we are not having any relation  with these nodes in our application.
      def add_special_services
        #   if @shipping_options[:saturday_delivery]
        #     xml.SpecialServiceTypes "SATURDAY_DELIVERY"
        #   end
        # }

        if @shipping_options[:return_reason] || @shipping_options[:cod] || @shipping_options[:saturday_delivery]
          special_services = {}
          special_services["specialServiceTypes"] = Array.new
          if @shipping_options[:return_reason]
            special_services["specialServiceTypes"] << "RETURN_SHIPMENT"
            special_services["returnShipmentDetail"] = {"returnType" => "PRINT_RETURN_LABEL"}
            special_services["returnShipmentDetail"]["rma"] = {"reason" => "#{@shipping_options[:return_reason]}" }
          end
          if @shipping_options[:cod]
            special_services["specialServiceTypes"] << "COD"
            if  @shipping_options[:cod][:currency] || @shipping_options[:cod][:amount]
              special_services["shipmentCODDetail"] = {
                "codCollectionAmount": {
                  "currency" => @shipping_options[:cod][:currency].upcase,
                  "amount" => @shipping_options[:cod][:amount]
                }
              }
            end
            special_services["shipmentCODDetail"]["codCollectionType"] = @shipping_options[:cod][:collection_type] if @shipping_options[:cod][:collection_type]
          end
          if @shipping_options[:saturday_delivery]

          end
          return special_services
        end
      end

      # Callback used after a failed shipment response.
      def failure_response(api_response, response)
        if response["errors"]
          error_message = response["errors"][0]["message"]
          raise ShipLabelError, error_message
        end
      end

      # Callback used after a successful shipment response.
      def success_response(api_response, response)
        @response_details = response["output"]
      end

      def service
        { :id => 'ship', :version => Fedex::API_VERSION }
      end

      # Successful request
      def success?(response)
        response["output"].present? && response["output"]["transactionShipments"].present? && response["errors"].nil?
      end

    end
  end
end
