# frozen_string_literal: true

require 'fileutils'
require 'base64'
require 'faraday'
require 'faraday/follow_redirects'
require 'faraday/net_http'
require 'json'
require 'openssl'

module DockerRegistry2
  Response = Struct.new(:body, :headers, :code, :request_url, keyword_init: true)

  class Registry # rubocop:disable Metrics/ClassLength
    # @param [#to_s] base_uri Docker registry base URI
    # @param [Hash] options Client options
    # @option options [#to_s] :user User name for basic authentication
    # @option options [#to_s] :password Password for basic authentication
    # @option options [#to_s] :open_timeout Time to wait for a connection with a registry.
    #                                       It is ignored if http_options[:open_timeout] is also specified.
    # @option options [#to_s] :read_timeout Time to wait for data from a registry.
    #                                       It is ignored if http_options[:read_timeout] is also specified.
    # @option options [Hash] :http_options Extra options for Faraday connection/request setup.
    def initialize(uri, options = {})
      @uri = URI.parse(uri)
      @base_uri = "#{@uri.scheme}://#{@uri.host}:#{@uri.port}#{@uri.path}"
      # `URI.join("https://example.com/foo/bar", "v2")` drops `bar` in the base URL. A trailing slash prevents that.
      @base_uri << '/' unless @base_uri.end_with? '/'
      @user = options[:user]
      @password = options[:password]
      @http_options = options[:http_options] || {}
      apply_timeout_defaults(options)
      @connection = nil
    end

    def doget(url, accept: nil)
      doreq 'get', url, nil, nil, accept: accept
    end

    def doput(url, payload = nil)
      doreq 'put', url, nil, payload
    end

    def dodelete(url)
      doreq 'delete', url
    end

    def dohead(url)
      doreq 'head', url
    end

    # When a result set is too large, the Docker registry returns only the first items and adds a Link header in the
    # response with the URL of the next page. See <https://docs.docker.com/registry/spec/api/#pagination>. This method
    # iterates over the pages and calls the given block with each response.
    def paginate_doget(url)
      loop do
        response = doget(url)
        yield response

        link_header = response.headers[:link] or break
        next_url = parse_link_header(link_header)[:next] or break

        # The next URL in the Link header may be relative to the request URL, or absolute.
        # URI.join handles both cases nicely.
        url = URI.join(response.request_url, next_url)
      end
    end

    def search(query = '')
      all_repos = []
      paginate_doget('v2/_catalog') do |response|
        repos = JSON.parse(response.body)['repositories']
        repos.select! { |repo| repo.match?(/#{query}/) } unless query.empty?
        all_repos += repos
      end
      all_repos
    end

    def tags(repo, count = nil, last = '', withHashes = false, auto_paginate: false)
      # create query params
      params = []
      params.push(['last', last]) if last && last != ''
      params.push(['n', count]) unless count.nil?

      query_vars = ''
      query_vars = "?#{URI.encode_www_form(params)}" if params.length.positive?

      response = doget "v2/#{repo}/tags/list#{query_vars}"
      # parse the response
      resp = JSON.parse response.body
      # parse out next page link if necessary
      resp['last'] = last(response.headers[:link]) if response.headers[:link]

      # do we include the hashes?
      if withHashes
        resp['hashes'] = {}
        resp['tags'].each do |tag|
          resp['hashes'][tag] = digest(repo, tag)
        end
      end

      return resp unless auto_paginate

      while (last_tag = resp.delete('last'))
        additional_tags = tags(repo, count, last_tag, withHashes)
        resp['last'] = additional_tags['last']
        resp['tags'] += additional_tags['tags']
        resp['tags'] = resp['tags'].uniq
        resp['hashes'].merge!(additional_tags['hashes']) if withHashes
      end

      resp
    end

    def manifest(repo, tag)
      # first get the manifest
      response = doget_with_legacy_fallback("v2/#{repo}/manifests/#{tag}")
      parsed = JSON.parse response.body
      manifest = DockerRegistry2::Manifest[parsed]
      manifest.body = response.body
      manifest.headers = response.headers
      manifest
    end

    def blob(repo, digest, outpath = nil)
      blob_url = "v2/#{repo}/blobs/#{digest}"
      if outpath.nil?
        response = doget(blob_url)
        DockerRegistry2::Blob.new(response.headers, response.body)
      else
        File.open(outpath, 'w') do |fd|
          doreq('get', blob_url, fd)
        end

        outpath
      end
    end

    def manifest_digest(repo, tag)
      tag_path = "v2/#{repo}/manifests/#{tag}"
      dohead(tag_path).headers[:docker_content_digest]
    rescue DockerRegistry2::InvalidMethod
      # Pre-2.3.0 registries didn't support manifest HEAD requests
      doget(tag_path).headers[:docker_content_digest]
    end

    def digest(image, tag, architecture = nil, os = nil, variant = nil)
      manifest = manifest(image, tag)
      parsed_manifest = JSON.parse(manifest.body)

      # Multi-arch images
      if parsed_manifest.key?('manifests')
        manifests = parsed_manifest['manifests']

        return manifests if architecture.nil? || os.nil?

        manifests.each do |entry|
          if !variant.nil?
            return entry['digest'] if entry['platform']['architecture'] == architecture && entry['platform']['os'] == os && entry['platform']['variant'] == variant
          elsif entry['platform']['architecture'] == architecture && entry['platform']['os'] == os
            return entry['digest']
          end
        end

        raise DockerRegistry2::NotFound, "No matches found for the image=#{image} tag=#{tag} os=#{os} architecture=#{architecture}"

      end

      manifest.headers[:docker_content_digest]
    end

    def rmtag(image, tag)
      # TODO: Need full response back. Rewrite other manifests() calls without JSON?
      reference = doget("v2/#{image}/manifests/#{tag}").headers[:docker_content_digest]

      dodelete("v2/#{image}/manifests/#{reference}").code
    end

    def pull(repo, tag, dir)
      # make sure the directory exists
      FileUtils.mkdir_p dir
      # get the manifest
      m = manifest repo, tag
      # puts "pulling #{repo}:#{tag} into #{dir}"
      # manifest can contain multiple manifests one for each API version
      downloaded_layers = []
      downloaded_layers += _pull_v2(repo, m, dir) if m['schemaVersion'] == 2
      downloaded_layers += _pull_v1(repo, m, dir) if m['schemaVersion'] == 1
      # return downloaded_layers
      downloaded_layers
    end

    def _pull_v2(repo, manifest, dir)
      # make sure the directory exists
      FileUtils.mkdir_p dir
      return false unless manifest['schemaVersion'] == 2

      # pull each of the layers
      manifest['layers'].each do |layer|
        # define path of file to save layer in
        layer_file = "#{dir}/#{layer['digest']}"
        # skip layer if we already got it
        next if File.file? layer_file

        # download layer
        # puts "getting layer (v2) #{layer['digest']}"
        blob(repo, layer['digest'], layer_file)
      end
    end

    def _pull_v1(repo, manifest, dir)
      # make sure the directory exists
      FileUtils.mkdir_p dir
      return false unless manifest['schemaVersion'] == 1

      # pull each of the layers
      manifest['fsLayers'].each do |layer|
        # define path of file to save layer in
        layer_file = "#{dir}/#{layer['blobSum']}"
        # skip layer if we already got it
        next if File.file? layer_file

        # download layer
        # puts "getting layer (v1) #{layer['blobSum']}"
        blob(repo, layer['blobSum'], layer_file)
        # return layer file
      end
    end

    def push(manifest, dir); end

    def tag(repo, tag, newrepo, newtag)
      manifest = manifest(repo, tag)

      raise DockerRegistry2::RegistryVersionException unless manifest['schemaVersion'] == 2

      doput "v2/#{newrepo}/manifests/#{newtag}", manifest.to_json
    end

    def copy(repo, tag, newregistry, newrepo, newtag); end

    # gets the size of a particular blob, given the repo and the content-addressable hash
    # usually unneeded, since manifest includes it
    def blob_size(repo, blobSum)
      response = dohead "v2/#{repo}/blobs/#{blobSum}"
      Integer(response.headers[:content_length], 10)
    end

    # Parse the value of the Link HTTP header and return a Hash whose keys are the rel values turned into symbols, and
    # the values are URLs. For example, `{ next: '/v2/_catalog?n=100&last=x' }`.
    def parse_link_header(header)
      parts = header.split(',')
      links = {}

      # Parse each part into a named link
      parts.each do |part, _index|
        section = part.split(';')
        url = section[0][/<(.*)>/, 1]
        name = section[1][/rel="?([^"]*)"?/, 1].to_sym
        links[name] = url
      end

      links
    end

    def last(header)
      links = parse_link_header(header)
      if links[:next]
        query = URI(links[:next]).query
        last = URI.decode_www_form(query).to_h['last']
      end
      last
    end

    def manifest_sum(manifest)
      size = 0
      manifest['layers'].each do |layer|
        size += layer['size']
      end
      size
    end

    private

    def doreq(type, url, stream = nil, payload = nil, **request_options)
      response = perform_request(type, url, payload: payload, stream: stream, **request_options)
      return handle_error_response(response, unauthorized_exception: DockerRegistry2::RegistryAuthenticationException) unless response.code == 401

      header = response.headers[:www_authenticate]
      method = header.to_s.downcase.split[0]
      case method
      when 'basic'
        do_basic_req(type, url, stream, payload, **request_options)
      when 'bearer'
        do_bearer_req(type, url, header, stream: stream, payload: payload, **request_options)
      else
        raise DockerRegistry2::RegistryUnknownException
      end
    end

    def do_basic_req(type, url, stream = nil, payload = nil, **request_options)
      response = perform_request(type, url, payload: payload, stream: stream, auth: :basic, **request_options)
      handle_error_response(response, unauthorized_exception: DockerRegistry2::RegistryAuthenticationException)
    end

    def do_bearer_req(type, url, header, request_options = {})
      token = authenticate_bearer(header)
      response = perform_request(type, url,
                                 payload: request_options[:payload],
                                 stream: request_options[:stream],
                                 auth: :bearer,
                                 bearer_token: token,
                                 **request_options.except(:payload, :stream))
      handle_error_response(response, unauthorized_exception: DockerRegistry2::RegistryAuthenticationException)
    end

    def authenticate_bearer(header)
      # get the parts we need
      target = split_auth_header(header)
      # did we have a username and password?
      target[:params][:account] = @user if defined? @user && !@user.to_s.strip.empty?
      # authenticate against the realm
      uri = URI.parse(target[:realm])
      response = perform_absolute_request(:get, uri.to_s, params: target[:params], auth: :basic)
      handle_error_response(response,
                            unauthorized_exception: DockerRegistry2::RegistryAuthenticationException,
                            forbidden_exception: DockerRegistry2::RegistryAuthenticationException)
      # now save the web token
      result = JSON.parse(response.body)
      result['token'] || result['access_token']
    end

    def split_auth_header(header = '')
      h = { params: {} }
      header.scan(/(\w+)="([^"]+)"/) do |entry|
        case entry[0]
        when 'realm'
          h[:realm] = entry[1]
        else
          h[:params][entry[0]] = entry[1]
        end
      end
      h
    end

    def headers(payload: nil, bearer_token: nil, accept: nil)
      headers = {}
      headers['Authorization'] = "Bearer #{bearer_token}" unless bearer_token.nil?
      headers['Accept'] = accept || default_accept_header if payload.nil?
      headers['Content-Type'] = 'application/vnd.docker.distribution.manifest.v2+json' unless payload.nil?

      headers
    end

    def default_accept_header
      %w[application/vnd.docker.distribution.manifest.v2+json
         application/vnd.docker.distribution.manifest.list.v2+json
         application/vnd.oci.image.manifest.v1+json
         application/vnd.oci.image.index.v1+json
         application/json].join(',')
    end

    def legacy_manifest_accept_header
      %w[application/vnd.docker.distribution.manifest.v2+json
         application/vnd.docker.distribution.manifest.list.v2+json
         application/vnd.docker.distribution.manifest.v1+prettyjws
         application/json].join(',')
    end

    def connection
      @connection ||= build_connection(@base_uri)
    end

    def build_connection(base_url)
      Faraday.new(base_url, **connection_options) do |faraday|
        faraday.response :follow_redirects,
                         limit: 5,
                         standards_compliant: true
        faraday.adapter :net_http
      end
    end

    def connection_options
      options = symbolize_keys(@http_options).dup
      options.delete(:open_timeout)
      options.delete(:read_timeout)

      ssl = normalize_ssl_options(options)
      request = request_options(options.delete(:request))

      options[:ssl] = ssl unless ssl.empty?
      options[:request] = request unless request.empty?
      options
    end

    def request_options(request = nil)
      options = symbolize_keys(request || {})
      options[:open_timeout] ||= @http_options[:open_timeout] || @http_options['open_timeout']
      options[:timeout] ||= @http_options[:read_timeout] || @http_options['read_timeout']
      options
    end

    def normalize_ssl_options(options)
      ssl = symbolize_keys(options.delete(:ssl) || {})
      normalize_legacy_verify_ssl!(ssl, options)
      ssl_aliases.each do |target_key, source_keys|
        source_keys.each do |source_key|
          next if source_key == :verify_ssl
          next unless options.key?(source_key)

          ssl[target_key] = options.delete(source_key)
        end
      end
      normalize_legacy_client_cert_paths!(ssl)
      ssl
    end

    def ssl_aliases
      {
        version: %i[ssl_version],
        ca_file: %i[ca_file ssl_ca_file],
        ca_path: %i[ca_path ssl_ca_path],
        cert_store: %i[cert_store ssl_cert_store],
        client_cert: %i[client_cert ssl_client_cert],
        client_key: %i[client_key ssl_client_key],
        verify_mode: %i[verify_mode]
      }
    end

    def apply_timeout_defaults(options)
      @http_options[:open_timeout] = options[:open_timeout] || 2 unless @http_options.key?(:open_timeout) || @http_options.key?('open_timeout')
      @http_options[:read_timeout] = options[:read_timeout] || 5 unless @http_options.key?(:read_timeout) || @http_options.key?('read_timeout')
    end

    def normalize_legacy_verify_ssl!(ssl, options)
      return unless options.key?(:verify_ssl)

      verify_ssl = options.delete(:verify_ssl)
      if verify_ssl.is_a?(Numeric)
        ssl[:verify_mode] = verify_ssl
      else
        ssl[:verify] = verify_ssl
      end
    end

    def normalize_legacy_client_cert_paths!(ssl)
      ssl[:client_cert] = load_client_certificate(ssl[:client_cert]) if ssl[:client_cert].is_a?(String)
      ssl[:client_key] = load_client_key(ssl[:client_key]) if ssl[:client_key].is_a?(String)
    end

    def load_client_certificate(path)
      OpenSSL::X509::Certificate.new(File.read(path))
    end

    def load_client_key(path)
      OpenSSL::PKey.read(File.read(path))
    end

    def symbolize_keys(hash)
      hash.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
    end

    def perform_request(type, url, request_options = {})
      perform(connection, type, url, request_options)
    end

    def perform_absolute_request(type, url, request_options = {})
      uri = URI.parse(url)
      absolute_connection = build_connection("#{uri.scheme}://#{uri.host}:#{uri.port}")
      request_url = uri.request_uri
      perform(absolute_connection, type, request_url, request_options)
    end

    def perform(conn, type, url, request_options = {})
      request_headers = headers(payload: request_options[:payload],
                                bearer_token: request_options[:bearer_token],
                                accept: request_options[:accept])
      response = conn.run_request(type.to_sym, url, request_options[:payload], request_headers) do |request|
        request.params.update(request_options[:params]) if request_options[:params]
        request.options.on_data = stream_handler(request_options[:stream]) if request_options[:stream]
        apply_auth!(request, request_options[:auth])
      end

      normalize_response(response, stream: request_options[:stream])
    rescue Faraday::SSLError
      raise DockerRegistry2::RegistrySSLException
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, SocketError
      raise DockerRegistry2::RegistryUnknownException
    end

    def apply_auth!(request, auth)
      case auth
      when :basic
        return if @user.to_s.empty? && @password.to_s.empty?

        token = Base64.strict_encode64([@user, @password].join(':'))
        request.headers['Authorization'] = "Basic #{token}"
      when nil, :bearer
        nil
      else
        raise ArgumentError, "Unsupported auth strategy: #{auth}"
      end
    end

    def stream_handler(stream)
      proc do |chunk, _overall_received_bytes, env|
        status = env.status.to_i
        stream.write(chunk) if status >= 200 && status < 300
      end
    end

    def normalize_response(response, stream: nil)
      DockerRegistry2::Response.new(
        body: stream.nil? ? response.body : nil,
        headers: normalize_headers(response.headers),
        code: response.status,
        request_url: response.env.url.to_s
      )
    end

    def normalize_headers(raw_headers)
      headers = {}
      raw_headers.each do |key, value|
        normalized_key = key.to_s.tr('-', '_').downcase.to_sym
        headers[normalized_key] = value
      end
      headers
    end

    def handle_error_response(response, unauthorized_exception:, forbidden_exception: nil)
      case response.code
      when 200..299
        response
      when 401
        raise unauthorized_exception
      when 403
        raise(forbidden_exception || DockerRegistry2::RegistryAuthorizationException)
      when 404
        raise DockerRegistry2::NotFound, "Image not found at #{@uri.host}"
      when 405
        raise DockerRegistry2::InvalidMethod
      else
        raise DockerRegistry2::RegistryHTTPException, "Registry request failed with status #{response.code}"
      end
    end

    def doget_with_legacy_fallback(url)
      doget(url)
    rescue DockerRegistry2::RegistryHTTPException => e
      raise e unless e.message.include?('status 500')

      doget(url, accept: legacy_manifest_accept_header)
    end
  end
end
