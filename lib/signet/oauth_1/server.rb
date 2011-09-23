# Copyright (C) 2011 The Yakima Herald-Republic.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require 'stringio'
require 'addressable/uri'
require 'signet'
require 'signet/errors'
require 'signet/oauth_1'
require 'signet/oauth_1/credential'

module Signet
  module OAuth1
    class Server

      # @return [Proc] lookup the value from this Proc.
      attr_accessor :nonce_timestamp, :client_credential, :token_credential, 
                    :temporary_credential, :verifier

      ##
      # Creates an OAuth 1.0 server.
      # @overload initialize(options)
      #   @param [Proc] nonce_timestamp verify a nonce/timestamp pair.
      #   @param [Proc] client_credential find a client credential.
      #   @param [Proc] token_credential find a token credential.
      #   @param [Proc] temporary_credential find a temporary credential.
      #   @param [Proc] verifier validate a verifier value.
      #
      # @example
      #   server = Signet::OAuth1::Server.new(
      #     :nonce_timestamp =>
      #       lambda { |n,t| OauthNonce.remember(n,t) },
      #     :client_credential =>
      #       lambda { |key| ClientCredential.find_by_key(key).to_hash },
      #     :token_credential =>
      #       lambda { |key| TokenCredential.find_by_key(key).to_hash },
      #     :temporary_credential => 
      #       lambda { |key| TemporaryCredential.find_by_key(key).to_hash },
      #     :verifier => 
      #       lambda {|verifier| Verifier.find_by_verifier(verifier).active? }
      #   )
      def initialize(options={})
        [:nonce_timestamp, :client_credential, :token_credential, 
         :temporary_credential, :verifier].each do |attr|
           instance_variable_set("@#{attr}", options[attr])
        end
      end

      ##
      # Determine if the supplied nonce/timestamp pair is valid by calling 
      # the {#nonce_timestamp} Proc.
      #
      # @param [String, #to_str] Nonce value from the request
      # @param [String, #to_str] Timestamp value from the request
      # @return [Boolean] if the nonce/timestamp pair is valid.
      def validate_nonce_timestamp(nonce, timestamp)
        nonce = 
          @nonce_timestamp.call(nonce, timestamp) if 
            @nonce_timestamp.respond_to?(:call)
        nonce ? true : false
      end

      ## 
      # Find the appropriate client credential by calling 
      # the {#client_credential} Proc.
      #
      # @param [String] Key provided to the :client_credential Proc.
      # @return [Signet::OAuth1::Credential] The client credential.
      def find_client_credential(key)
        cred = @client_credential.call(key) if 
                @client_credential.respond_to?(:call)
        nil if cred.nil?
        nil unless cred.instance_of?(Enumerable)
        cred.instance_of?(::Signet::OAuth1::Credential) ? cred 
        : ::Signet::OAuth1::Credential.new(cred)
      end

      ## 
      # Find the appropriate client credential by calling 
      # the {#token_credential} Proc.
      #
      # @param [String] Key provided to the :token_credential Proc.
      # @return [Signet::OAuth1::Credential] if the credential is found.
      def find_token_credential(key)
        cred = @token_credential.call(key) if @token_credential.respond_to?(:call)
        nil if cred.nil?
        nil unless cred.instance_of?(Enumerable)
        cred.instance_of?(::Signet::OAuth1::Credential) ? cred 
          : ::Signet::OAuth1::Credential.new(cred)
      end

      ## 
      # Find the appropriate client credential by calling 
      # the {#temporary_credential} Proc.
      #
      # @param [String] Key provided to the :temporary_credential Proc.
      # @return [Signet::OAuth1::Credential] if the credential is found.
      def find_temporary_credential(key)
        cred = @temporary_credential.call(key) if 
                @temporary_credential.respond_to?(:call)
        nil if cred.nil?
        nil unless cred.instance_of?(Enumerable)
        cred.instance_of?(::Signet::OAuth1::Credential) ? cred 
          : ::Signet::OAuth1::Credential.new(cred)
      end

      ## 
      #  Determine if the verifier is valid by calling the Proc in {#verifier}.
      #
      # @param [String] Key provided to the :verifier Proc.
      # @return [Boolean] verifier if if returns anything other than nil or false.
      def find_verifier(verifier)
        verified = @verifier.call(verifier) if @verifier.respond_to?(:call)
        verified ? true : false
      end


      ## 
      # Validate and normalize the components from an HTTP request.
      # @overload verify_request_components(options)
      #   @param [Hash] request A pre-constructed request to verify.
      #   @param [String] method the HTTP method , defaults to `GET`
      #   @param [Addressable::URI, String] uri the URI .
      #   @param [Hash, Array] headers the HTTP headers.
      #   @param [StringIO, String] body The HTTP body.
      #   @param [HTTPAdapter] adapter The HTTP adapter(optional).
      # @return [Hash] normalized request components
      def verify_request_components(options={})
        if options[:request]
          if options[:request].kind_of?(Array)
            request = options[:request]
          elsif options[:adapter]
            request = options[:adapter].adapt_request(options[:request])
          end
          method, uri, headers, body = request
        else
          method = options[:method] || 'GET'
          uri = options[:uri]
          headers = options[:headers] || []
          body = options[:body] || ''
        end

        headers = headers.to_a if headers.kind_of?(Hash)
        method = method.to_s.upcase

        request_components = {
          :method => method,
          :uri => uri,
          :headers => headers
        }

        # Verify that we have all the pieces required to validate the HTTP request
        request_components.each do |(key, value)|
          unless value
            raise ArgumentError, "Missing :#{key} parameter."
          end
        end
        request_components[:body] = body
        request_components
      end

      ##
      # Validate and normalize the HTTP Authorization header.
      # 
      # @param [Array] headers of HTTP request.
      # @return [Hash] Hash of Authorization header.
      def verify_auth_header_components(headers)
        auth_header = headers.find{|x| x[0] == 'Authorization'}
        if(auth_header.nil? || auth_header[1] == '')
          raise MalformedAuthorizationError.new('Authorization header is missing') 
        end
        auth_hash = ::Signet::OAuth1.parse_authorization_header(
          auth_header[1] ).inject({}) {|acc, (key,val)| acc[key.downcase] = val; acc}

        # Realm isn't used, and will throw the signature off.
        auth_hash.delete("realm")
        auth_hash
      end


      ##
      # @overload request_realm(options)
      #   @param [Hash] request A pre-constructed request to verify.
      #   @param [String] method the HTTP method , defaults to `GET`
      #   @param [Addressable::URI, String] uri the URI .
      #   @param [Hash, Array] headers the HTTP headers.
      #   @param [StringIO, String] body The HTTP body.
      #   @param [HTTPAdapter] adapter The HTTP adapter(optional).
      # @return [String] The Authorization realm of the request.
      def request_realm(options={})
        if(options[:request])
          request_components = verify_request_components(
            :request=>options[:request], 
            :adapter=>options[:adapter] )
        else
          request_components = verify_request_components(
            :method=>options[:method], 
            :uri=>options[:uri], 
            :headers=>options[:headers], 
            :body=>options[:body] )
        end
        
        auth_header = request_components[:headers].find{|x| x[0] == 'Authorization'}
        if(auth_header.nil? || auth_header[1] == '')
          raise MalformedAuthorizationError.new('Authorization header is missing') 
        end
        auth_hash = ::Signet::OAuth1.parse_authorization_header(
          auth_header[1] ).inject({}) {|acc, (key,val)| acc[key.downcase] = val; acc}
        auth_hash['realm']
      end

      ##
      # Authenticates a temporary credential request. If no oauth_callback is
      # present in the request, 'oob' will be returned.
      #
      # @overload authenticate_temporary_credential_request(options)
      #   @param [Hash] request The configuration parameters for the request.
      #   @param [String] method the HTTP method , defaults to `GET`
      #   @param [Addressable::URI, String] uri the URI .
      #   @param [Hash, Array] headers the HTTP headers.
      #   @param [StringIO, String] body The HTTP body.
      #   @param [HTTPAdapter] adapter The HTTP adapter(optional).
      # @return [String, false] The oauth_callback value, or false if not valid.
      def authenticate_temporary_credential_request(options={})
        verifications = {
          :client_credential => 
            lambda { |x| ::Signet::OAuth1::Credential.new('Client credential key', 
                                                          'Client credential secret'
                                                         )
            }
        }
        verifications.each do |(key, value)|
          raise ArgumentError, "#{key} was not set." unless self.send(key)
        end
        
        if(options[:request])
          request_components = verify_request_components(
            :request=>options[:request], 
            :adapter=>options[:adapter] )
        else
          request_components = verify_request_components(
            :method=>options[:method], 
            :uri=>options[:uri], 
            :headers=>options[:headers] )
        end
        # body should be blank; we don't care in any case.
        method = request_components[:method]
        uri = request_components[:uri]
        headers = request_components[:headers]

        auth_hash = verify_auth_header_components(headers)
        return false unless(client_credential = find_client_credential(
                                                  auth_hash['oauth_consumer_key']) )

        return false unless validate_nonce_timestamp(auth_hash['oauth_nonce'], 
                                                     auth_hash['oauth_timestamp'])
        client_credential_secret = client_credential.secret if client_credential

        computed_signature = ::Signet::OAuth1.sign_parameters(
          method, 
          uri, 
          auth_hash.to_a, 
          client_credential_secret, 
          nil
        )
        if(computed_signature == auth_hash['oauth_signature'])
          auth_hash.fetch('oauth_callback', 'oob').empty? ? 'oob' 
            : auth_hash.fetch('oauth_callback')
        else
          false
        end
      end


      ##
      # Authenticates a token credential request.
      # @overload authenticate_token_credential_request(options)
      #   @param [Hash] request The configuration parameters for the request.
      #   @param [String] method the HTTP method , defaults to `GET`
      #   @param [Addressable::URI, String] uri the URI .
      #   @param [Hash, Array] headers the HTTP headers.
      #   @param [StringIO, String] body The HTTP body.
      #   @param [HTTPAdapter] adapter The HTTP adapter(optional).
      # @return [Boolean] the authenticity of the request(valid/not valid).
      def authenticate_token_credential_request(options={})
        verifications = {
          :client_credential => 
            lambda {|x| ::Signet::OAuth1::Credential.new('Client credential key', 
                                                         'Client credential secret') 
                   },
          :temporary_credential => 
            lambda {|x| ::Signet::OAuth1::Credential.new('Temporary credential key', 
                                                         'Temporary credential secret') 
                   },
          :verifier => 
            lambda {|x| 'Verifier' }
        }
        verifications.each do |(key, value)|
          unless self.send(key)
            raise ArgumentError, "#{key} was not set."
          end
        end
        if(options[:request])
          request_components = verify_request_components(
            :request=>options[:request], 
            :adapter=>options[:adapter] 
          )
        else
          request_components = verify_request_components(
            :method=>options[:method], 
            :uri=>options[:uri], 
            :headers=>options[:headers], 
            :body=>options[:body] 
          )
        end
        # body should be blank; we don't care in any case.
        method = request_components[:method]
        uri = request_components[:uri]
        headers = request_components[:headers]
 
        auth_hash = verify_auth_header_components(headers)
        return false unless(
          client_credential = find_client_credential(auth_hash['oauth_consumer_key'])
        )
        return false unless(
          temporary_credential = find_temporary_credential(auth_hash['oauth_token'])
        )
        return false unless validate_nonce_timestamp(
          auth_hash['oauth_nonce'], auth_hash['oauth_timestamp'])

        computed_signature = ::Signet::OAuth1.sign_parameters(
          method, 
          uri, 
          auth_hash.to_a, 
          client_credential.secret, 
          temporary_credential.secret
        )

        (computed_signature == auth_hash['oauth_signature'])
      end

      ##
      # Authenticates a request for a protected resource.
      # @overload authenticate_resource_request(options)
      #   @param [Hash] request The configuration parameters for the request.
      #   @param [String] method the HTTP method , defaults to `GET`
      #   @param [Addressable::URI, String] uri the URI .
      #   @param [Hash, Array] headers the HTTP headers.
      #   @param [StringIO, String] body The HTTP body.
      #   @param [Boolean] two_legged skip the token_credential lookup?
      #   @param [HTTPAdapter] adapter The HTTP adapter(optional).
      #
      # @return [Boolean] The authenticity of the request(valid/not valid).
      def authenticate_resource_request(options={})
        verifications = {
          :client_credential => 
            lambda do |x| 
              ::Signet::OAuth1::Credential.new('Client credential key', 
                                               'Client credential secret')
            end 
        }

        unless(options[:two_legged] == true)
          verifications.update(
            :token_credential => 
              lambda do |x| 
                ::Signet::OAuth1::Credential.new('Token credential key', 
                                                 'Token credential secret')
              end 
          )
        end
        # Make sure all required state is set
        verifications.each do |(key, value)|
          unless self.send(key)
            raise ArgumentError, "#{key} was not set."
          end
        end

        if(options[:request])
          request_components = verify_request_components(
            :request=>options[:request], 
            :adapter=>options[:adapter] )
        else
          request_components = verify_request_components(
            :method=>options[:method], 
            :uri=>options[:uri], 
            :headers=>options[:headers], 
            :body=>options[:body] )
        end
        method = request_components[:method]
        uri = request_components[:uri]
        headers = request_components[:headers]
        body = request_components[:body]


        if !body.kind_of?(String) && body.respond_to?(:each)
          # Just in case we get a chunked body
          merged_body = StringIO.new
          body.each do |chunk|
            merged_body.write(chunk)
          end
          body = merged_body.string
        end
        if !body.kind_of?(String)
          raise TypeError, "Expected String, got #{body.class}."
        end

        media_type = nil
        headers.each do |(header, value)|
          if header.downcase == 'Content-Type'.downcase
            media_type = value.gsub(/^([^;]+)(;.*?)?$/, '\1')
          end
        end

        auth_hash = verify_auth_header_components(headers)

        auth_token = auth_hash['oauth_token']

        unless(options[:two_legged])
          return false if(auth_token.nil?)
          return false unless(token_credential = find_token_credential(auth_token))
          token_credential_secret = token_credential.secret if token_credential
        end

        return false unless(client_credential = 
                            find_client_credential(auth_hash['oauth_consumer_key']))

        return false unless validate_nonce_timestamp(auth_hash['oauth_nonce'], 
                                                     auth_hash['oauth_timestamp'])

        if(method == ('POST' || 'PUT') && 
           media_type == 'application/x-www-form-urlencoded')
          request_components[:body] = body
          post_parameters = Addressable::URI.form_unencode(body)
          post_parameters.each {|param| param[1] = "" if param[1].nil?}
          # If the auth header doesn't have the same params as the body, it
          # can't have been signed correctly(5849#3.4.1.3)
          unless(post_parameters == auth_hash.reject{|k,v| k.index('oauth_')}.to_a)
            raise MalformedAuthorizationError.new( 
              'Request is of type application/x-www-form-urlencoded ' + 
              'but Authentication header did not include form values'
                                                 )
          end
        end

        client_credential_secret = client_credential.secret if client_credential

        computed_signature = ::Signet::OAuth1.sign_parameters(
          method, 
          uri, 
          auth_hash.to_a, 
          client_credential_secret, 
          token_credential_secret
        )

        (computed_signature == auth_hash['oauth_signature'])
      end

    end
  end
end
