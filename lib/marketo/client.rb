require File.expand_path('authentication_header', File.dirname(__FILE__))

module Rapleaf
  module Marketo
    def self.new_client(access_key, secret_key, api_subdomain = 'na-i', api_version = '1_5', document_version = '1_4', logger=nil)
      client = Savon::Client.new do
        wsdl.endpoint     = "https://#{api_subdomain}.marketo.com/soap/mktows/#{api_version}"
        wsdl.document     = "http://app.marketo.com/soap/mktows/#{document_version}?WSDL"
        http.read_timeout = 90
        http.open_timeout = 90
        http.headers      = {"Connection" => "Keep-Alive"}
      end

      Client.new(client, Rapleaf::Marketo::AuthenticationHeader.new(access_key, secret_key), logger)
    end

    # = The client for talking to marketo
    # based on the SOAP wsdl file: <i>http://app.marketo.com/soap/mktows/1_4?WSDL</i>
    #
    # Usage:
    #
    # client = Rapleaf::Marketo.new_client(<access_key>, <secret_key>, api_subdomain = 'na-i', api_version = '1_5', document_version = '1_4')
    #
    # == get_lead_by_email:
    #
    # lead_record = client.get_lead_by_email('sombody@examnple.com')
    #
    # puts lead_record.idnum
    #
    # puts lead_record.get_attribute('FirstName')
    #
    # puts lead_record.get_attribute('LastName')
    #
    # == sync_lead: (update)
    #
    # lead_record = client.sync_lead('example@rapleaf.com', 'Joe', 'Smith', 'Company 1', '415 911')
    #
    # == sync_lead_record: (update with custom fields)
    #
    # lead_record = Rapleaf::Marketo::LeadRecord.new('harry@rapleaf.com')
    #
    # lead_record.set_attribute('FirstName', 'harry')
    #
    # lead_record.set_attribute('LastName', 'smith')
    #
    # lead_record.set_attribute('Email', 'harry@somesite.com')
    #
    # lead_record.set_attribute('Company', 'Rapleaf')
    #
    # lead_record.set_attribute('MobilePhone', '123 456')
    #
    # response = client.sync_lead_record(lead_record)
    #
    # == sync_lead_record_on_id: (update with custom fields, ensuring the sync is id based)
    #
    # similarly, you can force a sync via id instead of email by calling client.sync_lead_record_on_id(lead_record)
    #
    class Client
      # This constructor is used internally, create your client with *Rapleaf::Marketo.new_client(<access_key>, <secret_key>)*
      def initialize(savon_client, authentication_header, logger=nil)
        @client = savon_client
        @header = authentication_header
        set_logger(logger) if !logger.nil?
      end

      public

      def get_lead_by_idnum(idnum)
        get_lead(LeadKey.new(LeadKeyType::IDNUM, idnum))
      end

      def get_lead_by_contact_id(contact_id)
        log_info("Attempting to retrieve lead by contact id: " + contact_id.to_s)
        get_lead(LeadKey.new(LeadKeyType::SFDCCONTACTID, contact_id))
      end
      
      def get_lead_by_lead_id(lead_id)
        log_info("Attempting to retrieve lead by lead id: " + lead_id.to_s)
        get_lead(LeadKey.new(LeadKeyType::SFDCLEADID, lead_id))
      end

      def get_lead_by_email(email)
        get_lead(LeadKey.new(LeadKeyType::EMAIL, email))
      end

      def set_logger(logger)
        @log_id = SecureRandom.uuid
        @logger = logger
      end

      # create (if new) or update (if existing) a lead
      #
      # * email - email address of lead
      # * first - first name of lead
      # * last - surname/last name of lead
      # * company - company the lead is associated with
      # * mobile - mobile/cell phone number
      #
      # returns the LeadRecord instance on success otherwise nil
      def sync_lead(email, first, last, company, mobile)
        lead_record = LeadRecord.new(email)
        lead_record.set_attribute('FirstName', first)
        lead_record.set_attribute('LastName', last)
        lead_record.set_attribute('Email', email)
        lead_record.set_attribute('Company', company)
        lead_record.set_attribute('MobilePhone', mobile)
        sync_lead_record(lead_record)
      end

      def sync_lead_record(lead_record)
        begin
          attributes = []
          lead_record.each_attribute_pair do |name, value|
            attributes << {:attr_name => name, :attr_type => 'string', :attr_value => value}
          end

          response = send_request("ns1:paramsSyncLead", {
              :return_lead => true,
              :lead_record =>
                  {:email               => lead_record.email,
                   :lead_attribute_list => {
                       :attribute => attributes}}})
          return LeadRecord.from_hash(response[:success_sync_lead][:result][:lead_record])
        rescue Exception => e
          log_error(e)
          return nil
        end
      end

      def sync_lead_record_on_id(lead_record)
        idnum = lead_record.idnum
        raise 'lead record id not set' if idnum.nil?

        begin
          attributes = []
          lead_record.each_attribute_pair do |name, value|
              attributes << {:attr_name => name, :attr_type => 'string', :attr_value => value}
          end

          attributes << {:attr_name => 'Id', :attr_type => 'string', :attr_value => idnum.to_s}

          response = send_request("ns1:paramsSyncLead", {
              :return_lead => true,
              :lead_record =>
                  {
                    :lead_attribute_list => { :attribute => attributes},
                    :id => idnum
                  }})
          return LeadRecord.from_hash(response[:success_sync_lead][:result][:lead_record])
        rescue Exception => e
          log_error(e)
          return nil
        end
      end
      
      def associate_cookie(lead_record, cookie)
        idnum = lead_record.idnum
        
        raise 'lead record id not set' if idnum.nil?

        attributes = []
        attributes << {:attr_name => 'Id', :attr_type => 'string', :attr_value => idnum.to_s}

        response = send_request("ns1:paramsSyncLead", {
            :return_lead => true,
            :lead_record =>
                {
                  :lead_attribute_list => { :attribute => attributes },
                  :Id => idnum
                },
            :marketo_cookie => cookie})

        log_info("Attempting to call marketo_gem's associate_cookie for user with id = #{idnum.to_s}...")
        log_info("cookie = " + cookie.to_s)
        log_info("attributes = " + attributes.to_s)
        log_info("response: " + response.to_s)

        return LeadRecord.from_hash(response[:success_sync_lead][:result][:lead_record])
      end

      def add_to_list(list_key, email)
        list_operation(list_key, ListOperationType::ADD_TO, email)
      end

      def remove_from_list(list_key, email)
        list_operation(list_key, ListOperationType::REMOVE_FROM, email)
      end

      def is_member_of_list?(list_key, email)
        list_operation(list_key, ListOperationType::IS_MEMBER_OF, email)
      end

      private

      def log_info(message)
        @logger.info("[#{@log_id}] [#{Time.now}]  INFO  " + message) if @logger
      end

      def log_error(e)
        if @logger
          @logger.error("[#{@log_id}] [#{Time.now}]  ERROR  " + e.message)
        end
      end


      def list_operation(list_key, list_operation_type, email)
        begin
          response = send_request("ns1:paramsListOperation", {
              :list_operation   => list_operation_type,
              :list_key         => list_key,
              :strict           => 'false',
              :list_member_list => {
                  :lead_key => [
                      {:key_type => 'EMAIL', :key_value => email}
                  ]
              }
          })
          return response
        rescue Exception => e
          log_error(e)
          return nil
        end
      end

      def get_lead(lead_key)
        begin
          response = send_request("ns1:paramsGetLead", {:lead_key => lead_key.to_hash})
          return LeadRecord.from_hash(response[:success_get_lead][:result][:lead_record_list][:lead_record])
        rescue Exception => e
          log_error(e)
          return nil
        end
      end

      def send_request(namespace, body)
        @header.set_time(DateTime.now)
        response = request(namespace, body, @header.to_hash)
        response.to_hash
      end

      def request(namespace, body, header)
        @client.request namespace do |soap|
          soap.namespaces["xmlns:ns1"]            = "http://www.marketo.com/mktows/"
          soap.body                               = body
          soap.header["ns1:AuthenticationHeader"] = header
        end
      end
    end
  end
end