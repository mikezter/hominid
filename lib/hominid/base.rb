module Hominid
  class Base
    include Hominid::Campaign
    include Hominid::Helper
    include Hominid::List
    include Hominid::Security

    # MailChimp API Documentation: http://www.mailchimp.com/api/1.2/
    MAILCHIMP_API_VERSION = "1.2"
    MAILCHIMP_EXPORT_API_VERSION = "1.0"
    MAILCHIMP_EXPORT_PATH = "/export/#{MAILCHIMP_EXPORT_API_VERSION}/list/"

    def initialize(config = {})
      raise StandardError.new('Please provide your Mailchimp API key.') unless config[:api_key]
      raise ArgumentError.new('Your Mailchimp API key is malformatted.') unless config[:api_key].include?('-')
      dc = config[:api_key].split('-').last
      defaults = {
        :double_opt_in      => false,
        :merge_tags         => {},
        :replace_interests  => true,
        :secure             => false,
        :send_goodbye       => false,
        :send_notify        => false,
        :send_welcome       => false,
        :update_existing    => true
      }
      @config = defaults.merge(config).freeze
      if config[:secure]
        @chimpApi = XMLRPC::Client.new2("https://#{dc}.api.mailchimp.com/#{MAILCHIMP_API_VERSION}/")
        @exportApi = Net::HTTP.new("#{dc}.api.mailchimp.com", 443)
      else
        @chimpApi = XMLRPC::Client.new2("http://#{dc}.api.mailchimp.com/#{MAILCHIMP_API_VERSION}/")
        @exportApi = Net::HTTP.new("#{dc}.api.mailchimp.com", 80)
      end
    end

    def apply_defaults_to(options) # :nodoc:
      @config.merge(options)
    end

    def call(method, *args) # :nodoc:
      @chimpApi.call(method, @config[:api_key], *args)
    rescue XMLRPC::FaultException => error
      # Handle common cases for which the Mailchimp API would raise Exceptions
      case error.faultCode
      when 100..199
        raise UserError.new(error)
      when 200..299
        raise ListError.new(error)
      when 300..399
        raise CampaignError.new(error)
      when 500..599
        raise ValidationError.new(error)
      else
        raise APIError.new(error)
      end
    rescue RuntimeError => error
      if error.message =~ /Wrong type!/
        hashes = args.select{|a| a.is_a? Hash}
        errors = hashes.select{|k, v| v.nil? }.collect{ |k, v| "#{k} is Nil." }.join(' ')
        raise CommunicationError.new(errors)
      else
        raise error
      end
    rescue Exception => error
      raise CommunicationError.new(error.message)
    end

    def call_export(list_id, status)
      uri = "#{MAILCHIMP_EXPORT_PATH}?apikey=#{@config[:api_key]}&id=#{list_id}"

      !status.nil? && uri += "&status=#{status}"

      # Don't parse the whole thing since there could be thousands of records
      out, keys = [], []
      body = @exportApi.request_get(uri).body
      lines = body.send(body.respond_to?(:lines) ? :lines : :to_s).to_a

      lines.each_with_index do |l, i|
        if i == 0
          keys = JSON.parse(l).map { |k| k.gsub(" ", "_") }
        else
          # Magic! http://snippets.dzone.com/posts/show/302
          out << Hash[*keys.zip(JSON.parse(l)).flatten]
        end
      end
      out
    rescue Exception => error
      raise CommunicationError.new(error.message)
    end

    def clean_merge_tags(merge_tags) # :nodoc:
      return {} unless merge_tags.is_a? Hash
      merge_tags.each do |key, value|
        if merge_tags[key].is_a? String
          merge_tags[key] = value.gsub("\v", '')
        elsif merge_tags[key].nil?
          merge_tags[key] = ''
        end
      end
    end

    def hash_to_object(object) # :nodoc:
      return case object
      when Hash
        object = object.clone
        object.each do |key, value|
          object[key.downcase] = hash_to_object(value)
        end
        OpenStruct.new(object)
      when Array
        object = object.clone
        object.map! { |i| hash_to_object(i) }
      else
        object
      end
    end

  end
end

