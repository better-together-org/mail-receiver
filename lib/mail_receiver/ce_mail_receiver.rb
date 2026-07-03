# frozen_string_literal: true
require "syslog"
require "json"
require "uri"
require "net/http"
require_relative "mail_receiver_base"

# Speaks Community Engine's ActionMailbox-based ingress contract
# (POST raw RFC822 body, HTTP Basic Auth) instead of Discourse's own
# form-encoded /admin/email/handle_mail contract.
#
# Deliberately does not call super(env_file): MailReceiverBase's
# constructor enforces DISCOURSE_API_KEY/DISCOURSE_API_USERNAME/
# DISCOURSE_MAIL_ENDPOINT, which is the wrong contract here. A single
# container can host both a Discourse domain and a CE domain at once
# (see boot's CE_MAIL_DOMAINS handling), each with its own distinct
# credentials, so this uses independently-named CE_API_KEY/
# CE_API_USERNAME/CE_MAIL_ENDPOINT env vars instead.
class CeMailReceiver < MailReceiverBase
  def initialize(env_file = nil, recipient = nil, mail = nil)
    unless env_file && File.exist?(env_file)
      fatal "Config file %s does not exist. Aborting.", env_file
    end
    @env = JSON.parse(File.read(env_file))

    %w[CE_API_KEY CE_API_USERNAME CE_MAIL_ENDPOINT].each do |kw|
      fatal "env var %s is required for the ce target", kw unless @env[kw]
    end

    @recipient = recipient
    @mail = mail

    logger.debug "Recipient: #{@recipient}"
    fatal "No recipient passed on command line." unless @recipient
    fatal "No message passed on stdin." if @mail.nil? || @mail.empty?
  end

  def key
    @env["CE_API_KEY"]
  end

  def username
    @env["CE_API_USERNAME"]
  end

  def endpoint
    @env["CE_MAIL_ENDPOINT"]
  end

  def process
    uri = URI.parse(endpoint)

    begin
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      post = Net::HTTP::Post.new(uri.request_uri)
      post["Content-Type"] = "message/rfc822"
      post.basic_auth username, key
      post.body = @mail

      response = http.request(post)
    rescue StandardError => ex
      logger.err "Failed to POST the e-mail to %s: %s (%s)", endpoint, ex.message, ex.class
      logger.err ex.backtrace.map { |l| "  #{l}" }.join("\n")

      return :failure
    ensure
      http.finish if http && http.started?
    end

    return :success if Net::HTTPSuccess === response

    logger.err "Failed to POST the e-mail to %s: %s", endpoint, response.code
    :failure
  end
end
