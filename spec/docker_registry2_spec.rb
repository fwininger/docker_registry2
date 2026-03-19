# frozen_string_literal: true

require 'tmpdir'
require 'openssl'
require_relative '../lib/docker_registry2'

RSpec.describe DockerRegistry2 do
  let(:connected_object) { described_class.connect('http://localhost:5000') }

  describe '.connect' do
    it { expect { connected_object }.not_to raise_error }
    it { expect(connected_object).not_to be_nil }
  end

  describe '.tags' do
    let(:tags_hello_world_v1) do
      VCR.use_cassette('tags/hello-world-v1') { connected_object.tags('hello-world-v1') }
    end
    let(:tags_hello_world_v99) do
      VCR.use_cassette('tags/hello-world-v99') { connected_object.tags('hello-world-v99') }
    end

    context 'tag exist' do
      it { expect { tags_hello_world_v1 }.not_to raise_error }
      it { expect(tags_hello_world_v1).not_to be_nil }
      it { expect(tags_hello_world_v1.keys).to contain_exactly('tags', 'name') }
      it { expect(tags_hello_world_v1['tags']).to eq ['latest'] }
      it { expect(tags_hello_world_v1['name']).to eq 'hello-world-v1' }
    end

    context 'tag doesnt exist' do
      it { expect { tags_hello_world_v99 }.to raise_error(DockerRegistry2::NotFound) }
    end
  end

  describe '#search' do
    it 'lists all the repositories matching the query' do
      repos = VCR.use_cassette('search/hello_world') { connected_object.search('hello-world') }
      expect(repos).to eq %w[hello-world-v1 hello-world-v2 hello-world-v3 hello-world-v4]
    end
  end

  describe 'manifest' do
    let(:manifest_hello_world_v1_latest) do
      VCR.use_cassette('manifest/hello-world-v1_latest') { connected_object.manifest('hello-world-v1', 'latest') }
    end

    let(:manifest_hello_world_v1_non_existent) do
      VCR.use_cassette('manifest/hello-world-v1_non_existent') do
        connected_object.manifest('hello-world-v1', 'non_existent')
      end
    end

    let(:manifest_hello_world_v99_latest) do
      VCR.use_cassette('manifest/hello-world-v99_latest') { connected_object.manifest('hello-world-v99', 'latest') }
    end

    let(:my_ubuntu_multiarch_manifest) do
      VCR.use_cassette('manifest/multiarch_ubuntu') { connected_object.manifest('my-ubuntu', '17.04') }
    end

    context 'manifest exists' do
      it { expect { manifest_hello_world_v1_latest }.not_to raise_error }
    end

    context 'manifest for wrong tag' do
      it { expect { manifest_hello_world_v1_non_existent }.to raise_error(DockerRegistry2::NotFound) }
    end

    context 'manifest for wrong image' do
      it { expect { manifest_hello_world_v99_latest }.to raise_error(DockerRegistry2::NotFound) }
    end

    context 'multiarch manifest exists' do
      it { expect { my_ubuntu_multiarch_manifest }.not_to raise_error }
    end

    context 'multiarch manifest returns the expected archs' do
      let(:archs) do
        my_ubuntu_multiarch_manifest.fetch('manifests').map { |manifest| manifest.fetch('platform').fetch('architecture') }
      end

      it { expect { my_ubuntu_multiarch_manifest }.not_to raise_error }
      it { expect(archs).to match_array(%w[amd64 arm64]) }
    end

    it 'retries manifest requests with the legacy Docker accept header after a 500 response' do
      manifest_url = 'http://localhost:5000/v2/hello-world-v1/manifests/latest'
      manifest_body = {
        'schemaVersion' => 1,
        'name' => 'hello-world-v1',
        'tag' => 'latest',
        'fsLayers' => [{ 'blobSum' => 'sha256:abc123' }]
      }.to_json
      modern_accept = [
        'application/vnd.docker.distribution.manifest.v2+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.oci.image.index.v1+json',
        'application/json'
      ].join(',')
      legacy_accept = [
        'application/vnd.docker.distribution.manifest.v2+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.docker.distribution.manifest.v1+prettyjws',
        'application/json'
      ].join(',')

      stub_request(:get, manifest_url)
        .with(headers: { 'Accept' => modern_accept })
        .to_return(status: 500, body: 'registry error')
      stub_request(:get, manifest_url)
        .with(headers: { 'Accept' => legacy_accept })
        .to_return(status: 200, body: manifest_body, headers: { 'Content-Type' => 'application/json' })

      manifest = VCR.turned_off { connected_object.manifest('hello-world-v1', 'latest') }

      expect(manifest['schemaVersion']).to eq(1)
      expect(a_request(:get, manifest_url).with(headers: { 'Accept' => modern_accept })).to have_been_made.once
      expect(a_request(:get, manifest_url).with(headers: { 'Accept' => legacy_accept })).to have_been_made.once
    end

    context 'Docker registry without path' do
      let(:uri) { 'https://example.com' }
      let(:registry) { DockerRegistry2::Registry.new(uri) }

      it 'The @path should be empty' do
        expect(registry.instance_variable_get(:@base_uri)).to eq('https://example.com:443/')
      end
    end

    context 'Docker registry with a @path' do
      let(:uri) { 'https://registry.myCompany.com/dockerproxy' }
      let(:registry) { DockerRegistry2::Registry.new(uri) }

      it 'The @path is included' do
        expect(registry.instance_variable_get(:@base_uri)).to eq('https://registry.myCompany.com:443/dockerproxy/')
      end
    end

    context 'Extracts the digest of an image' do
      let(:uri) { 'http://localhost:5000' }
      let(:registry) { DockerRegistry2::Registry.new(uri) }

      it 'Digest is extracted from a manifest with single arch' do
        VCR.use_cassette('manifest/ubuntu') do
          expect(connected_object.digest('my-image', '2.0')).to eq('sha256:6d28b970d82cb05ce1aca12baddcd72b7034c7e771fdd97d0862672deb863fca')
        end
      end
      it 'Digest is extracted from a multiarch image' do
        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect(connected_object.digest('my-ubuntu', '17.04', 'amd64', 'linux')).to eq('sha256:213e05583a7cb8756a3f998e6dd65204ddb6b4c128e2175dcdf174cdf1877459')
        end

        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect(connected_object.digest('my-ubuntu', '17.04', 'arm64', 'linux')).to eq('sha256:213e05583a7cb8756a3f998e6dd65204ddb6b4c128e2175dcdf174cdf1877459')
        end
      end

      it 'Digest is extracted from a multiarch image with variant' do
        VCR.use_cassette('manifest/multiarch_php_variant') do
          expect(connected_object.digest('php', 'latest', 'arm', 'linux', 'v5')).to eq('sha256:1eb3215f71b6dcf1a1f9bec5fde07ae166ecf43de16e48ebdff3641ee54cac72')
        end
      end

      manifests = [
        {
          'mediaType' => 'application/vnd.docker.distribution.manifest.v2+json',
          'size' => 1357,
          'digest' => 'sha256:213e05583a7cb8756a3f998e6dd65204ddb6b4c128e2175dcdf174cdf1877459',
          'platform' => {
            'architecture' => 'amd64',
            'os' => 'linux'
          }
        },
        {
          'mediaType' => 'application/vnd.docker.distribution.manifest.v2+json',
          'size' => 1357,
          'digest' => 'sha256:213e05583a7cb8756a3f998e6dd65204ddb6b4c128e2175dcdf174cdf1877459',
          'platform' => {
            'architecture' => 'arm64',
            'os' => 'linux'
          }
        }
      ]

      it 'When it a multiarch image and no arch/os are specified it returns the manifests' do
        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect(connected_object.digest('my-ubuntu', '17.04')).to eq(manifests)
        end
      end

      it 'When it a multiarch image and only arch is given it returns the manifests' do
        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect(connected_object.digest('my-ubuntu', '17.04', 'arm64')).to eq(manifests)
        end
      end

      it 'When it a multiarch image and only os is given it returns the manifests' do
        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect(connected_object.digest('my-ubuntu', '17.04', nil, 'linux')).to eq(manifests)
        end
      end

      it 'Fails when there are no matches' do
        VCR.use_cassette('manifest/multiarch_ubuntu') do
          expect do
            connected_object.digest('my-ubuntu',
                                    '17.04', 'arm64', 'windows')
          end.to raise_error(DockerRegistry2::NotFound, 'No matches found for the image=my-ubuntu tag=17.04 os=windows architecture=arm64')
        end
      end
    end
  end

  describe '#blob' do
    let(:uri) { 'https://registry.example.com' }
    let(:registry) { DockerRegistry2::Registry.new(uri, user: 'me', password: 'secret') }
    let(:blob_url) { "#{uri}/v2/private/repo/blobs/sha256:abc123" }
    let(:auth_header) { "Basic #{Base64.strict_encode64('me:secret')}" }

    it 'does not write the unauthenticated challenge body into streamed blob files' do
      stub_request(:get, blob_url)
        .to_return(
          status: 401,
          body: 'auth required',
          headers: { 'WWW-Authenticate' => 'Basic realm="Registry"' }
        ).then
        .to_return(
          status: 200,
          body: 'real blob data',
          headers: { 'Content-Length' => '14' }
        )

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'blob.bin')

        registry.blob('private/repo', 'sha256:abc123', path)

        expect(File.binread(path)).to eq('real blob data')
      end

      expect(a_request(:get, blob_url).with(headers: { 'Authorization' => auth_header })).to have_been_made.once
    end

    it 'follows redirected blob downloads' do
      redirected_url = 'https://storage.example.com/downloads/sha256:abc123'

      stub_request(:get, blob_url)
        .to_return(status: 307, headers: { 'Location' => redirected_url })
      stub_request(:get, redirected_url)
        .to_return(status: 200, body: 'redirected blob data')

      blob = VCR.turned_off { registry.blob('private/repo', 'sha256:abc123') }

      expect(blob.body).to eq('redirected blob data')
    end

    it 'drops authorization on cross-host redirects' do
      redirected_url = 'https://canonical.example.com/downloads/sha256:abc123'

      stub_request(:get, blob_url)
        .to_return(
          status: 401,
          body: 'auth required',
          headers: { 'WWW-Authenticate' => 'Basic realm="Registry"' }
        ).then
        .to_return(status: 307, headers: { 'Location' => redirected_url })
      stub_request(:get, blob_url)
        .with(headers: { 'Authorization' => auth_header })
        .to_return(status: 307, headers: { 'Location' => redirected_url })
      stub_request(:get, redirected_url)
        .to_return(status: 200, body: 'redirected blob data')

      blob = VCR.turned_off { registry.blob('private/repo', 'sha256:abc123') }

      expect(blob.body).to eq('redirected blob data')
      expect(a_request(:get, redirected_url).with(headers: { 'Authorization' => auth_header })).not_to have_been_made
    end
  end

  describe '#tag' do
    let(:uri) { 'https://registry.example.com' }
    let(:registry) { DockerRegistry2::Registry.new(uri) }
    let(:manifest_url) { "#{uri}/v2/source/repo/manifests/latest" }
    let(:redirected_tag_url) { 'https://canonical.example.com/v2/destination/repo/manifests/release' }
    let(:tag_url) { "#{uri}/v2/destination/repo/manifests/release" }
    let(:manifest_body) { { 'schemaVersion' => 2, 'config' => { 'digest' => 'sha256:abc123' } }.to_json }

    it 'preserves PUT when following redirects for tag writes' do
      stub_request(:get, manifest_url)
        .to_return(status: 200, body: manifest_body, headers: { 'Content-Type' => 'application/json' })

      stub_request(:put, tag_url)
        .to_return(status: 301, headers: { 'Location' => redirected_tag_url })

      stub_request(:put, redirected_tag_url)
        .with(body: manifest_body)
        .to_return(status: 201, body: '')

      registry.tag('source/repo', 'latest', 'destination/repo', 'release')

      expect(a_request(:put, redirected_tag_url).with(body: manifest_body)).to have_been_made.once
      expect(a_request(:get, redirected_tag_url)).not_to have_been_made
    end
  end

  describe 'unexpected HTTP errors' do
    let(:uri) { 'https://registry.example.com' }
    let(:registry) { DockerRegistry2::Registry.new(uri) }

    it 'raises for server errors instead of parsing the response body' do
      stub_request(:get, "#{uri}/v2/_catalog")
        .to_return(status: 500, body: 'upstream error')

      expect { registry.search('hello-world') }
        .to raise_error(DockerRegistry2::RegistryHTTPException, 'Registry request failed with status 500')
    end

    it 'raises for rate-limited tag requests' do
      stub_request(:get, "#{uri}/v2/private/repo/tags/list")
        .to_return(status: 429, body: 'slow down')

      expect { registry.tags('private/repo') }
        .to raise_error(DockerRegistry2::RegistryHTTPException, 'Registry request failed with status 429')
    end
  end

  describe 'http_options compatibility' do
    let(:tls_version) { 'TLSv1_2' }

    let(:registry) do
      DockerRegistry2::Registry.new(
        'https://registry.example.com',
        open_timeout: 2,
        read_timeout: 5,
        http_options: {
          'proxy' => 'http://proxy.example.com:8080',
          'headers' => { 'X-Test' => '1' },
          'params' => { 'ns' => 'team' },
          'verify_ssl' => false,
          'ssl_version' => tls_version,
          'ssl_ca_file' => '/tmp/ca.pem',
          'ssl_ca_path' => '/tmp/certs',
          'ssl_cert_store' => 'custom-store',
          'request' => { 'timeout' => 15 }
        }
      )
    end

    it 'preserves caller-supplied Faraday connection options' do
      options = registry.send(:connection_options)

      expect(options[:proxy]).to eq('http://proxy.example.com:8080')
      expect(options[:headers]).to eq('X-Test' => '1')
      expect(options[:params]).to eq('ns' => 'team')
    end

    it 'maps legacy top-level ssl options into Faraday ssl settings' do
      options = registry.send(:connection_options)

      expect(options[:ssl]).to include(
        verify: false,
        version: tls_version,
        ca_file: '/tmp/ca.pem',
        ca_path: '/tmp/certs',
        cert_store: 'custom-store'
      )
    end

    it 'maps numeric verify_ssl modes to verify_mode instead of boolean verify' do
      numeric_verify_registry = DockerRegistry2::Registry.new(
        'https://registry.example.com',
        http_options: { 'verify_ssl' => OpenSSL::SSL::VERIFY_NONE }
      )

      options = numeric_verify_registry.send(:connection_options)

      expect(options[:ssl]).to include(verify_mode: OpenSSL::SSL::VERIFY_NONE)
      expect(options[:ssl]).not_to have_key(:verify)
    end

    it 'merges request timeouts without discarding caller request options' do
      options = registry.send(:connection_options)

      expect(options[:request]).to include(timeout: 15, open_timeout: 2)
    end

    it 'preserves string-keyed timeout overrides from http_options' do
      string_timeout_registry = DockerRegistry2::Registry.new(
        'https://registry.example.com',
        http_options: { 'open_timeout' => 10, 'read_timeout' => 20 }
      )

      options = string_timeout_registry.send(:connection_options)

      expect(options[:request]).to include(open_timeout: 10, timeout: 20)
    end

    it 'loads legacy mTLS file paths into OpenSSL objects' do
      key = OpenSSL::PKey::RSA.new(2048)
      name = OpenSSL::X509::Name.parse('/CN=registry.example.com')
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = name
      cert.issuer = name
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new('SHA256'))

      Dir.mktmpdir do |dir|
        cert_path = File.join(dir, 'client.crt')
        key_path = File.join(dir, 'client.key')
        File.write(cert_path, cert.to_pem)
        File.write(key_path, key.to_pem)

        mtls_registry = DockerRegistry2::Registry.new(
          'https://registry.example.com',
          http_options: {
            'ssl_client_cert' => cert_path,
            'ssl_client_key' => key_path
          }
        )

        options = mtls_registry.send(:connection_options)

        expect(options[:ssl][:client_cert]).to be_a(OpenSSL::X509::Certificate)
        expect(options[:ssl][:client_key]).to be_a(OpenSSL::PKey::RSA)
      end
    end
  end
end
