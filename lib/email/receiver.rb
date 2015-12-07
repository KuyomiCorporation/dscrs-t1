require_dependency 'new_post_manager'
require_dependency 'email/html_cleaner'

module Email

  class Receiver

    include ActionView::Helpers::NumberHelper

    class ProcessingError < StandardError; end
    class EmailUnparsableError < ProcessingError; end
    class EmptyEmailError < ProcessingError; end
    class UserNotFoundError < ProcessingError; end
    class UserNotSufficientTrustLevelError < ProcessingError; end
    class BadDestinationAddress < ProcessingError; end
    class TopicNotFoundError < ProcessingError; end
    class TopicClosedError < ProcessingError; end
    class AutoGeneratedEmailError < ProcessingError; end
    class EmailLogNotFound < ProcessingError; end
    class InvalidPost < ProcessingError; end

    attr_reader :body, :email_log

    def initialize(raw, opts=nil)
      @raw = raw
      @opts = opts || {}
    end

    def process
      raise EmptyEmailError if @raw.blank?

      message = Mail.new(@raw)

      body = parse_body(message)

      dest_info = { type: :invalid, obj: nil }
      message.to.each do |to_address|
        dest_info = check_address(to_address)
        break if dest_info[:type] != :invalid
      end

      raise BadDestinationAddress   if dest_info[:type] == :invalid
      raise AutoGeneratedEmailError if message.header.to_s =~ /auto-generated/ || message.header.to_s =~ /auto-replied/

      # TODO get to a state where we can remove this
      @message = message
      @body = body

      user_email = @message.from.first
      @user = User.find_by_email(user_email)

      case dest_info[:type]
      when :group
        raise BadDestinationAddress unless SiteSetting.email_in
        group = dest_info[:obj]

        if @user.blank?
          if SiteSetting.allow_staged_accounts
            @user = create_staged_account(user_email)
          else
            wrap_body_in_quote(user_email)
            @user = Discourse.system_user
          end
        end

        raise UserNotFoundError if @user.blank?
        raise UserNotSufficientTrustLevelError.new(@user) unless @user.has_trust_level?(TrustLevel[SiteSetting.email_in_min_trust.to_i])

        create_new_topic(archetype: Archetype.private_message, target_group_names: [group.name])
      when :category
        raise BadDestinationAddress unless SiteSetting.email_in
        category = dest_info[:obj]

        if @user.blank? && category.email_in_allow_strangers
          if SiteSetting.allow_staged_accounts
            @user = create_staged_account(user_email)
          else
            wrap_body_in_quote(user_email)
            @user = Discourse.system_user
          end
        end

        raise UserNotFoundError if @user.blank?
        raise UserNotSufficientTrustLevelError.new(@user) unless category.email_in_allow_strangers || @user.has_trust_level?(TrustLevel[SiteSetting.email_in_min_trust.to_i])

        create_new_topic(category: category.id)
      when :reply
        @email_log = dest_info[:obj]

        raise EmailLogNotFound   if @email_log.blank?
        raise TopicNotFoundError if Topic.find_by_id(@email_log.topic_id).nil?
        raise TopicClosedError   if Topic.find_by_id(@email_log.topic_id).closed?

        create_reply
      end

    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
      raise EmailUnparsableError.new(e)
    end

    def create_staged_account(email)
      User.create(
        email: email,
        username: UserNameSuggester.suggest(email),
        name: User.suggest_name(email),
        staged: true
      )
    end

    def check_address(address)
      group = Group.find_by_email(address)
      return { type: :group, obj: group } if group

      category = Category.find_by_email(address)
      return { type: :category, obj: category } if category

      regex = Regexp.escape(SiteSetting.reply_by_email_address)
      regex = regex.gsub(Regexp.escape('%{reply_key}'), "(.*)")
      regex = Regexp.new(regex)
      match = regex.match address
      if match && match[1].present?
        reply_key = match[1]
        email_log = EmailLog.for(reply_key)
        return { type: :reply, obj: email_log }
      end

      { type: :invalid, obj: nil }
    end

    def parse_body(message)
      body = select_body message
      encoding = body.encoding
      raise EmptyEmailError if body.strip.blank?

      body = discourse_email_trimmer body
      raise EmptyEmailError if body.strip.blank?

      body = EmailReplyParser.parse_reply body
      raise EmptyEmailError if body.strip.blank?

      body.force_encoding(encoding).encode("UTF-8")
    end

    def select_body(message)
      html = nil

      if message.multipart?
        text = fix_charset message.text_part
        # prefer text over html
        return text if text
        html = fix_charset message.html_part
      elsif message.content_type =~ /text\/html/
        html = fix_charset message
      end

      if html
        body = HtmlCleaner.new(html).output_html
      else
        body = fix_charset message
      end

      return body if @opts[:skip_sanity_check]

      # Certain trigger phrases that means we didn't parse correctly
      if body =~ /Content\-Type\:/ || body =~ /multipart\/alternative/ || body =~ /text\/plain/
        raise EmptyEmailError
      end

      body
    end

    # Force encoding to UTF-8 on a Mail::Message or Mail::Part
    def fix_charset(object)
      return nil if object.nil?

      if object.charset
        object.body.decoded.force_encoding(object.charset.gsub(/utf8/i, "UTF-8")).encode("UTF-8").to_s
      else
        object.body.to_s
      end
    rescue
      nil
    end

    REPLYING_HEADER_LABELS = ['From', 'Sent', 'To', 'Subject', 'Reply To', 'Cc', 'Bcc', 'Date']
    REPLYING_HEADER_REGEX = Regexp.union(REPLYING_HEADER_LABELS.map { |lbl| "#{lbl}:" })

    def line_is_quote?(l)
      l =~ /\A\s*\-{3,80}\s*\z/ ||
      l =~ Regexp.new("\\A\\s*" + I18n.t('user_notifications.previous_discussion') + "\\s*\\Z") ||
      (l =~ /via #{SiteSetting.title}(.*)\:$/) ||
      # This one might be controversial but so many reply lines have years, times and end with a colon.
      # Let's try it and see how well it works.
      (l =~ /\d{4}/ && l =~ /\d:\d\d/ && l =~ /\:$/) ||
      (l =~ /On [\w, ]+\d+.*wrote:/)
    end

    def discourse_email_trimmer(body)
      lines = body.scrub.lines.to_a
      range_start = 0
      range_end = 0

      # If we started with a quote, skip it
      lines.each_with_index do |l, idx|
        break unless line_is_quote?(l) or l =~ /^>/ or l.blank?
        range_start = idx + 1
      end

      lines[range_start..-1].each_with_index do |l, idx|
        break if line_is_quote?(l)

        # Headers on subsequent lines
        break if (0..2).all? { |off| lines[idx+off] =~ REPLYING_HEADER_REGEX }
        # Headers on the same line
        break if REPLYING_HEADER_LABELS.count { |lbl| l.include? lbl } >= 3
        range_end = range_start + idx
      end

      lines[range_start..range_end].join.strip
    end

    private

    def wrap_body_in_quote(user_email)
      @body = "[quote=\"#{user_email}\"]\n#{@body}\n[/quote]"
    end

    def create_reply
      create_post_with_attachments(@email_log.user,
                                   raw: @body,
                                   topic_id: @email_log.topic_id,
                                   reply_to_post_number: @email_log.post.post_number)
    end

    def create_new_topic(topic_options={})
      topic_options[:raw] = @body
      topic_options[:title] = @message.subject

      result = create_post_with_attachments(@user, topic_options)
      topic_id = result.post.present? ? result.post.topic_id : nil

      EmailLog.create(
        email_type: "topic_via_incoming_email",
        to_address: @message.from.first, # pick from address because we want the user's email
        topic_id: topic_id,
        user_id: @user.id,
      )

      result
    end

    def create_post_with_attachments(user, post_options={})
      options = {
        cooking_options: { traditional_markdown_linebreaks: true },
      }.merge(post_options)

      raw = options[:raw]

      # deal with attachments
      @message.attachments.each do |attachment|
        tmp = Tempfile.new("discourse-email-attachment")
        begin
          # read attachment
          File.open(tmp.path, "w+b") { |f| f.write attachment.body.decoded }
          # create the upload for the user
          upload = Upload.create_for(user.id, tmp, attachment.filename, tmp.size)
          if upload && upload.errors.empty?
            # try to inline images
            if attachment.content_type.start_with?("image/")
              if raw =~ /\[image: Inline image \d+\]/
                raw.sub!(/\[image: Inline image \d+\]/, attachment_markdown(upload))
                next
              end
            end
            raw << "\n#{attachment_markdown(upload)}\n"
          end
        ensure
          tmp.close!
        end
      end

      options[:raw] = raw

      create_post(user, options)
    end

    def attachment_markdown(upload)
      if FileHelper.is_image?(upload.original_filename)
        "<img src='#{upload.url}' width='#{upload.width}' height='#{upload.height}'>"
      else
        "<a class='attachment' href='#{upload.url}'>#{upload.original_filename}</a> (#{number_to_human_size(upload.filesize)})"
      end
    end

    def create_post(user, options)
      # Mark the reply as incoming via email
      options[:via_email] = true
      options[:raw_email] = @raw

      manager = NewPostManager.new(user, options)
      result = manager.perform

      if result.errors.present?
        raise InvalidPost, result.errors.full_messages.join("\n")
      end

      result
    end

  end
end
