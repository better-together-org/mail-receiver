# frozen_string_literal: true
require_relative "../../lib/mail_receiver/ce_mail_receiver"

RSpec.describe CeMailReceiver do
  let(:recipient) { "requests+bay-of-islands@example.com" }
  let(:mail) { "some body" }

  it "raises an error without a recipient" do
    expect { described_class.new(file_for(:ce_standard), nil, mail) }.to raise_error(
      MailReceiverBase::ReceiverException,
    )
  end

  it "raises an error without mail" do
    expect { described_class.new(file_for(:ce_standard), recipient, nil) }.to raise_error(
      MailReceiverBase::ReceiverException,
    )

    expect { described_class.new(file_for(:ce_standard), recipient, "") }.to raise_error(
      MailReceiverBase::ReceiverException,
    )
  end

  it "raises an error if the env file doesn't have CE_API_KEY" do
    expect { described_class.new(file_for(:ce_missing_key), recipient, mail) }.to raise_error(
      MailReceiverBase::ReceiverException,
    )
  end

  it "does not require Discourse-specific env vars" do
    expect { described_class.new(file_for(:ce_standard), recipient, mail) }.not_to raise_error
  end

  it "has the correct endpoint" do
    receiver = described_class.new(file_for(:ce_standard), recipient, mail)
    expect(receiver.endpoint).to eq("https://ce.example.com/inbound-email/relay")
  end

  it "posts the raw message body with the correct content type and basic auth" do
    expect_any_instance_of(Net::HTTP).to receive(:request) do |_http, request|
      expect(request["Content-Type"]).to eq("message/rfc822")
      expect(request.body).to eq(mail)
      expect(request["Authorization"]).to start_with("Basic ")

      Net::HTTPSuccess.new(1.0, 200, "OK")
    end

    receiver = described_class.new(file_for(:ce_standard), recipient, mail)
    expect(receiver.process).to eq(:success)
  end

  it "returns failure on HTTP error" do
    expect_any_instance_of(Net::HTTP).to receive(:request) do |http|
      Net::HTTPServerError.new(http, 500, "Error")
    end

    receiver = described_class.new(file_for(:ce_standard), recipient, mail)
    expect(receiver.process).to eq(:failure)
  end
end
