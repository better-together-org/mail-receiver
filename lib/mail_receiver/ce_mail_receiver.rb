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
# Reuses the same env var names as DiscourseMailReceiver so `boot`'s
# validation logic doesn't need to change. For a "ce" target the
# semantics shift: DISCOURSE_API_USERNAME holds the Basic Auth username
# (CE expects "actionmailbox"), DISCOURSE_API_KEY holds the Basic Auth
# password (CE's RAILS_INBOUND_EMAIL_PASSWORD), and DISCOURSE_MAIL_ENDPOINT
# holds CE's full /inbound-email/relay URL.
class CeMailReceiver < MailReceiverBase
  def initialize(env_file = nil, recipient = nil, mail = nil)
    super(env_file)

    @recipient = recipient
    @mail = mail

    logger.debug "Recipient: #{@recipient}"
    fatal "No recipient passed on command line." unless @recipient
    fatal "No message passed on stdin." if @mail.nil? || @mail.empty?
  end

  def endpoint
    @endpoint ||=
      @env["DISCOURSE_MAIL_ENDPOINT"] ||
        fatal(
          "DISCOURSE_MAIL_ENDPOINT (the CE /inbound-email/relay URL) is required for the ce target",
        )
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
