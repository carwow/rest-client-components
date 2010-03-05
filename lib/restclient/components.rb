require 'restclient'
require 'rack'

module RestClient
  module Rack
    class Compatibility
      def initialize(app)
        @app = app
      end
      
      def call(env)
        status, header, body = @app.call(env)
        net_http_response = RestClient::MockNetHTTPResponse.new(body, status, header)
        content = ""
        net_http_response.body.each{|line| content << line}
        response = RestClient::Response.new(content, net_http_response)
        if block = env['restclient.hash'][:block]
          block.call(response)
        # only raise error if response is not successful
        elsif !(200...300).include?(response.code) && e = env['restclient.hash'][:error]
          raise e
        else
          response
        end
      end
    end
  end

  class <<self
    attr_reader :components
  end
  
  # Enable a Rack component. You may enable as many components as you want.
  # e.g.
  # Transparent HTTP caching:
  #   RestClient.enable Rack::Cache, 
  #                       :verbose     => true,
  #                       :metastore   => 'file:/var/cache/rack/meta'
  #                       :entitystore => 'file:/var/cache/rack/body'
  # 
  # Transparent logging of HTTP requests (commonlog format):
  #   RestClient.enable Rack::CommonLogger, STDOUT
  # 
  # Please refer to the documentation of each rack component for the list of available options.
  # 
  def self.enable(component, *args)
    # remove any existing component of the same class
    disable(component)
    if component == RestClient::Rack::Compatibility
      @components.push [component, args]
    else
      @components.unshift [component, args]
    end
  end
  
  # Disable a component
  #   RestClient.disable Rack::Cache
  #   => array of remaining components
  def self.disable(component)
    @components.delete_if{|(existing_component, options)| component == existing_component}
  end
  
  # Returns true if the given component is enabled, false otherwise
  #   RestClient.enable Rack::Cache
  #   RestClient.enabled?(Rack::Cache)
  #   => true
  def self.enabled?(component)
    !@components.detect{|(existing_component, options)| component == existing_component}.nil?
  end
  
  def self.reset
    # hash of the enabled components 
    @components = [[RestClient::Rack::Compatibility]]
  end
  
  def self.debeautify_headers(headers = {})   # :nodoc:
    headers.inject({}) do |out, (key, value)|
			out[key.to_s.gsub(/_/, '-').split("-").map{|w| w.capitalize}.join("-")] = value.to_s
			out
		end
  end
  
  reset
  
  # Reopen the RestClient::Request class to add a level of indirection in order to create the stack of Rack middleware.
  # 
	class Request
	  alias_method :original_execute, :execute
	  def execute(&block)
      uri = URI.parse(@url)
      # minimal rack spec
      env = { 
        "restclient.hash" => {:request => self, :error => nil, :block => block},
        "REQUEST_METHOD" => @method.to_s.upcase,
        "SCRIPT_NAME" => "",
        "PATH_INFO" => uri.path || "/",
        "QUERY_STRING" => uri.query || "",
        "SERVER_NAME" => uri.host,
        "SERVER_PORT" => uri.port.to_s,
        "rack.version" => ::Rack::VERSION,
        "rack.run_once" => false,
        "rack.multithread" => true,
        "rack.multiprocess" => true,
        "rack.url_scheme" => uri.scheme,
        "rack.input" => payload || StringIO.new,
        "rack.errors" => $stderr
      }
      @processed_headers.each do |key, value|
        env.merge!("HTTP_"+key.to_s.gsub("-", "_").upcase => value)
      end
      env.delete('HTTP_CONTENT_TYPE'); env.delete('HTTP_CONTENT_LENGTH')
      stack = RestClient::RACK_APP
      RestClient.components.each do |(component, args)|
        if (args || []).empty?
          stack = component.new(stack)
        else
          stack = component.new(stack, *args)
        end
      end
      response = stack.call(env)
      # allow to use the response block, even if not using the Compatibility component
      unless RestClient.enabled?(RestClient::Rack::Compatibility)
        if block = env['restclient.hash'][:block]
          block.call(response)
        end
      end
      response
    end
  end
	
	module Payload
	  class Base
	    def rewind(*args)
	      @stream.rewind(*args)
      end
      
      def gets(*args)
        @stream.gets(*args)
      end
      
      def each(&block)
        @stream.each(&block)
      end
    end
  end
  
  # A class that mocks the behaviour of a Net::HTTPResponse class.
  # It is required since RestClient::Response must be initialized with a class that responds to :code and :to_hash.
  class MockNetHTTPResponse
    attr_reader :body, :header, :status
    alias_method :code, :status
    
    def initialize(body, status, header)
      @body = body
      @status = status
      @header = header
    end

    def to_hash
      @header.inject({}) {|out, (key, value)|
        # In Net::HTTP, header values are arrays
        out[key] = [value]
        out
      }
    end    
  end
  
  RACK_APP = Proc.new { |env|
    begin
      # get the original request, replace headers with those of env, and execute it
      request = env['restclient.hash'][:request]
      additional_headers = (env.keys.select{|k| k=~/^HTTP_/}).inject({}){|accu, k|
        accu[k.gsub("HTTP_", "")] = env[k]
        accu
      }
      # hack, should probably avoid to call #read on rack.input..
      payload = if (env['rack.input'].size > 0)
        env['rack.input'].rewind
        Payload.generate(env['rack.input'].read)
      else
        nil
      end
      request.instance_variable_set "@payload", payload
      headers = request.make_headers(additional_headers)
      headers.delete('Content-Type')
      headers['Content-type'] = env['CONTENT_TYPE'] if env['CONTENT_TYPE']
      request.processed_headers.update(headers)
      response = request.original_execute
    rescue RestClient::ExceptionWithResponse => e  
      env['restclient.hash'][:error] = e
      response = e.response
    end
    # to satisfy Rack::Lint
    response.headers.delete(:status)
    header = RestClient.debeautify_headers( response.headers )
    body = response.to_s
    # return the real content-length since RestClient does not do it when decoding gzip responses
    header['Content-Length'] = body.length.to_s if header.has_key?('Content-Length')
    [response.code, header, [body]]
  }

end
