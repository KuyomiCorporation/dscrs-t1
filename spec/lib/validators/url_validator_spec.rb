# frozen_string_literal: true

RSpec.describe UrlValidator do
  subject(:validate) { validator.validate_each(record, :website, record.website) }

  let(:record) { Fabricate.build(:user_profile, user: Fabricate.build(:user)) }
  let(:validator) { described_class.new(attributes: :website) }

  [
    "http://https://google.com",
    "http://google/",
    "ftp://ftp.google.com",
    "http:///what.is.this",
    "http://meta.discourse.org TEST",
  ].each do |invalid_url|
    it "#{invalid_url} should not be valid" do
      record.website = invalid_url
      validate
      expect(record.errors[:website]).to be_present
    end
  end

  %w[
    http://discourse.productions
    https://google.com
    http://xn--nw2a.xn--j6w193g/
    http://見.香港/
  ].each do |valid_url|
    it "#{valid_url} should be valid" do
      record.website = valid_url
      validate
      expect(record.errors[:website]).to_not be_present
    end
  end
end
