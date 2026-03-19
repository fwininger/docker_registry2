## v1.19.0, 19 March 2026

- Replace the `rest-client` transport with Faraday while keeping `http_options`
  compatibility for proxy, timeout, SSL, and mTLS settings
- Follow redirects for blob downloads and tag writes without forwarding
  authorization headers across hosts
- Retry manifest requests with the legacy schema-v1 Accept header when newer
  registries return HTTP 500 for legacy manifests
- Raise `DockerRegistry2::RegistryHTTPException` for unexpected HTTP errors
  instead of attempting to parse error responses as registry payloads
- Update the development and CI matrix to Ruby 3.2 through 4.0, and pin
  schema-v1 integration coverage to `registry:2.8.3`

## v1.7.1, 13 July 2019

- Add `application/json` to the list of acceptable response formats from
  registries to fix Artifactory returning 406 Not Acceptable errors when
  application/vnd.docker.distribution.manifest.v2+json is requested on the tags
  endpoint

## v1.7.0, 18 June 2019

- Add `auto_paginate` option to `DockerRegistry2::Registry#tags`. When set to
  true (as a keyword argument) the client will automatically paginate through
  responses from the client to return a list of all tags

## v1.3.3, 18 December 2017

- Use DockerRegistry2::NotFound in unauthenticated request calls

## v1.3.2, 15 December 2017

- Use DockerRegistry2::NotFound in basic request calls (as well as bearer ones)

## v1.3.1, 15 December 2017

- New DockerRegistry2::NotFound exceptions

## v1.3.0, 22 October 2017

- Add basic tests
- Add support for both v1 and v2 schemas thanks to https://github.com/lehn-etracker

## v1.2.0, 15 October 2017

- Add shorter default timeouts. Previously, the RestClient default of 60 seconds
  was used for both open_timeout and read_timeout. Now, those values are set at
  2 seconds and 5 seconds, respectively.

## v1.1.0, 13 October 2017

- Move `ping` call from `DockerRegistry2::Registry.new` to
  `DockerRegistry2.connect`, to allow a registry to be initialized without a
  ping.
