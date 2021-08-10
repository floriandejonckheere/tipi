# frozen_string_literal: true

require 'bundler/setup'
require 'tipi'
require 'openssl'
require 'acme-client'

# ::Exception.__disable_sanitized_backtrace__ = true

class CertificateManager
  def initialize(store:, challenge_handler:)
    @store = store
    @challenge_handler = challenge_handler
    @contexts = {}
    @requests = Polyphony::Queue.new
    Thread.new { run }
  end

  def <<(req)
    @requests << req
  end

  def run
    while true
      name, state = @requests.shift
      state[:ctx] = get_context(name)
    end
  end

  def get_context(name)
    @contexts[name] = setup_context(name)
  end

  CERTIFICATE_REGEXP = /(-----BEGIN CERTIFICATE-----\n[^-]+-----END CERTIFICATE-----\n)/.freeze

  def setup_context(name)
    private_key, certificate = get_certificate(name)
    ctx = OpenSSL::SSL::SSLContext.new
    chain = certificate.scan(CERTIFICATE_REGEXP).map { |p|  OpenSSL::X509::Certificate.new(p.first) }
    cert = chain.shift
    ctx.add_certificate(cert, private_key, chain)
    Polyphony::Net.setup_alpn(ctx, Tipi::ALPN_PROTOCOLS)
    ctx
  end
  
  def get_certificate(name)
    @store[name] ||= provision_certificate(name)
  end

  def private_key
    @private_key ||= OpenSSL::PKey::RSA.new(4096)
  end

  ACME_DIRECTORY = 'https://acme-staging-v02.api.letsencrypt.org/directory'

  def acme_client
    @acme_client ||= setup_acme_client
  end

  def setup_acme_client
    client = Acme::Client.new(
      private_key: private_key,
      directory: ACME_DIRECTORY
    )
    account = client.new_account(
      contact: 'mailto:info@noteflakes.com',
      terms_of_service_agreed: true
    )
    p account: account.kid
    client
  end

  def provision_certificate(name)
    order = acme_client.new_order(identifiers: [name])
    authorization = order.authorizations.first
    # p authorization: authorization
    challenge = authorization.http
    p challenge_token: challenge.token
  
    @challenge_handler.add(challenge)
    challenge.request_validation
    p challenge_status: challenge.status
    while challenge.status == 'pending'
      sleep(1)
      p fiber: Fiber.current
      challenge.reload
      p challenge_status: challenge.status
    end
    exit!(31) if challenge.status == 'invalid'
  
    different_private_key = OpenSSL::PKey::RSA.new(4096)
    csr = Acme::Client::CertificateRequest.new(private_key: different_private_key, subject: { common_name: name })
    p csr: csr
    order.finalize(csr: csr)
    p order_status: order.status
    while order.status == 'processing'
      sleep(1)
      order.reload
      p order_status: order.status
    end
    certificate = begin
      order.certificate(force_chain: 'DST Root CA X3')
    rescue Acme::Client::Error::ForcedChainNotFound
      order.certificate
    end

    chain = certificate.scan(CERTIFICATE_REGEXP).map { |p|  OpenSSL::X509::Certificate.new(p.first) }
    cert = chain.shift
    puts "Certificate expires: #{cert.not_after.inspect}"

    [different_private_key, certificate] # => PEM-formatted certificate
  rescue Polyphony::BaseException
    raise
  rescue Exception => e
    p error: e
    p backtrace: e.backtrace
    exit!
  ensure
    @challenge_handler.remove(challenge) if challenge
  end
end

class AcmeHTTPChallengeHandler
  def initialize
    @challenges = {}
  end

  def add(challenge)
    path = "/.well-known/acme-challenge/#{challenge.token}"
    @challenges[path] = challenge
  end

  def remove(challenge)
    path = "/.well-known/acme-challenge/#{challenge.token}"
    @challenges.delete(path)
  end

  def call(req)
    challenge = @challenges[req.path]

    # handle incoming request
    challenge = @challenges[req.path]
    return req.respond(nil, ':status' => 400) unless challenge

    p respond_to_challenge: challenge.token

    req.respond(challenge.file_content, 'content-type' => challenge.content_type)
  end
end

challenge_handler = AcmeHTTPChallengeHandler.new
certificate_manager = CertificateManager.new(
  store: {},
  challenge_handler: challenge_handler
)

http_handler = ->(r) do
  puts '*' * 40
  if r.path =~ /\/\.well\-known\/acme\-challenge/
    challenge_handler.call(r)
  else
    r.redirect "https://#{r.host}#{r.path}"
  end
end

https_handler = ->(r) { r.respond('Hello, world!') }

http_listener = spin do
  opts = {
    reuse_addr:   true,
    reuse_port:   true,
    dont_linger:  true,
  }
  puts 'Listening for HTTP on localhost:10080'
  server = Polyphony::Net.tcp_listen('0.0.0.0', 10080, opts)
  server.accept_loop do |client|
    spin do
      Tipi.client_loop(client, opts, &http_handler)
    end      
  end
  # Tipi.serve('0.0.0.0', 10080, opts, &http_handler)
end

def wait_for_ctx(state)
  period = 0.00001
  while !state[:ctx]
    sleep period
    period *= 2 if period < 0.1
  end
end

https_listener = spin do
  ctx = OpenSSL::SSL::SSLContext.new
  f = Fiber.new do |peer|
    while true
      peer = peer.transfer :foo
    end
  end
  
  ctx.servername_cb = proc do |_socket, name|
    p request_name: name
    state = { ctx: nil }
    certificate_manager << [name, state]
    wait_for_ctx(state)
    state[:ctx]
  end
  opts = {
    reuse_addr:     true,
    reuse_port:     true,
    dont_linger:    true,
    secure_context: ctx,
    alpn_protocols: Tipi::ALPN_PROTOCOLS
  }

  puts 'Listening for HTTPS on localhost:10443'
  server = Polyphony::Net.tcp_listen('0.0.0.0', 10443, opts)

  accept_loop_fiber = Fiber.current
  accept_loop_worker = Thread.new do
    loop do
      connection = server.accept
      accept_loop_fiber << connection
    rescue OpenSSL::SSL::SSLError, SystemCallError
      # ignore
    rescue => e
      puts "HTTPS accept error: #{e.inspect}"
      puts e.backtrace.join("\n")
    end
  end

  while true
    client = receive
    spin do
      Tipi.client_loop(client, opts) { |req| req.respond('Hello world') }
    end
  end
end

begin
  Fiber.await(http_listener, https_listener)
rescue Interrupt
  puts "Got SIGINT, terminating"
rescue Exception => e
  puts '*' * 40
  p e
  puts e.backtrace.join("\n")
end
