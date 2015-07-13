# encoding: utf-8
require 'base64'


class Gw::WebmailMail
  include Sys::Lib::Net::Imap
  include Sys::Lib::Mail
  
  FORMAT_TEXT = 'text'
  FORMAT_HTML = 'html'
  
  attr_accessor :charset, :in_to, :in_cc, :in_bcc, :in_from, :in_sender,
    :in_subject, :in_body, :in_html_body, :in_format, :in_files, :tmp_id, :tmp_attachment_ids, :request_mdn
  
  def initialize(attributes = nil)
    @charset = Gw::WebmailSetting.user_config_value(:mail_encoding, "iso-2022-jp")
    
    if attributes.class == Gw::WebmailMailNode
      @node = attributes
      self.uid     = @node.uid
      self.mailbox = @node.mailbox
      self.extend Gw::Model::Ext::WebmailNode
    elsif attributes
      self.attributes = attributes
    end
  end
  
#  def attributes
#  end
  
  def attributes=(attributes)
    attributes.each do |key, val|
      eval("self.#{key} = val")
    end
  end
  
  def node
    @node ||= find_node 
    @node
  end
  
  def find_node
    cond = {:user_id => Core.current_user.id, :uid => uid, :mailbox => mailbox}
    Gw::WebmailMailNode.find(:first, :conditions => cond)
  end
  
  def request_mdn?
    @request_mdn.to_s == "1"
  end
  
  def reference=(reference)
    @reference = reference
  end
  
  def tmp_attachments
    return [] unless tmp_id
    Gw::WebmailMailAttachment.find(:all, :conditions => {:id => tmp_attachment_ids, :tmp_id => tmp_id})
  end
  
  def delete_tmp_attachments
    return true unless tmp_id
    Gw::WebmailMailAttachment.destroy_all(:tmp_id => tmp_id)
  end
  
  def errors
    @errors ||= ActiveModel::Errors.new(self)
  end
  
  def valid?(mode = :send)
    @in_from_addr     = parse_address(in_from)
    @in_to_addrs      = parse_address(in_to)
    @in_cc_addrs      = parse_address(in_cc)
    @in_bcc_addrs     = parse_address(in_bcc)
    self.in_subject   = NKF.nkf('-Ww --no-best-fit-chars', in_subject) unless in_subject.blank?
    self.in_body      = NKF.nkf('-Ww --no-best-fit-chars', in_body) unless in_body.blank?
    self.in_html_body = NKF.nkf('-Ww --no-best-fit-chars', in_html_body) unless in_html_body.blank?
    
    if in_files.present?
      in_files.each do |file|
        attach = Gw::WebmailMailAttachment.new(:tmp_id => tmp_id)
        if attach.save_file(file)
          @tmp_attachment_ids ||= []
          @tmp_attachment_ids << attach.id
        else
          attach.errors.full_messages.each{|msg| errors.add(:base, "#{file.original_filename.force_encoding('UTF-8')}: #{msg}")}
        end
      end
      
      ## garbage collect
      Sys::File.garbage_collect if rand(100) == 0
    end
    
    return if mode == :file
    
    self.in_subject = "件名なし" if in_subject.blank?
    #errors.add :base, "件名が未入力です。"   if in_subject.blank?
    errors.add :base, "件名は100文字以内で入力してください。" if in_subject.size > 100
    errors.add :base, "宛先は150件以内で入力してください。" if @in_to_addrs.size > 150
    errors.add :base, "Ccは150件以内で入力してください。"   if @in_cc_addrs.size > 150
    errors.add :base, "Bccは150件以内で入力してください。"  if @in_bcc_addrs.size > 150
    
    tmp_attachments.each do |f|
      errors.add :base, "添付ファイルが見つかりません。（#{f.name}）" unless File.exist?(f.upload_path)
    end
    
    if mode == :send
      errors.add :base, "送信元が未入力です。" if in_from.blank?
      errors.add :base, "宛先が未入力です。"   if in_to.blank? && in_cc.blank? && in_bcc.blank?
      if in_format == FORMAT_HTML
        body_check = !in_html_body.blank?
      else
        body_check = !in_body.blank?
      end
      errors.add :base, "本文が未入力です。" unless body_check
    end
    return errors.size == 0
  end
  
  def single_pagination(id, params = {})
    attr     = {}
    last_uid = nil
    
    imap.select(params[:select])
    if params[:sort_starred] == '1' 
      uids  = imap.uid_sort(params[:sort], params[:conditions] + " FLAGGED", "utf-8")
      uids += imap.uid_sort(params[:sort], params[:conditions] + " UNFLAGGED", "utf-8")
    else
      uids = imap.uid_sort(params[:sort], params[:conditions], "utf-8")
    end
    uids.each_with_index do |uid, idx|
      if uid == id.to_i
        attr[:total_items]  = uids.size
        attr[:prev_uid]     = last_uid
        attr[:next_uid]     = uids[idx + 1]
        attr[:current_page] = idx + 1
        attr[:prev_page]    = idx if idx > 0
        attr[:next_page]    = idx + 2 if attr[:next_uid]
        break
      end
      last_uid = uid
    end
    attr
  end
  
  def prepare_mail(request = nil)
    mail = Mail.new
    mail.charset     = @charset
    mail.from        = @in_from_addr[0]
    mail.to          = @in_to_addrs.join(',')
    mail.cc          = @in_cc_addrs.join(',')
    mail.bcc         = @in_bcc_addrs.join(',')
    #mail.body    = in_body
    mail["X-Mailer"] = "Joruri Mail ver. #{Joruri.version}"
    mail["User-Agent"] = request.user_agent if request
    
    if @reference ## for answer
      references = []
      case value = @reference.mail.references
      when String
        references << value
      when Array
        references += value
      when ActiveSupport::Multibyte::Chars
        value.to_s.scan(/<([^>]+)>/) {|m| references << m[0] }
      end
      references << @reference.mail.message_id if @reference.mail.message_id
      mail.references("<#{references.join('> <')}>") if references.size > 0
    end
    
    mail.subject = mime_encode(in_subject.gsub(/\r\n|\n/, ' '), false)
    extend_subject_field(mail.header['subject'].field)
    
    if self.request_mdn?
      extend_header_fields(mail.header_fields)
      #mail["Disposition-Notification-To"] = @in_from_addr[0].raw
      mail["Disposition-Notification-To"] ||= @in_from_addr[0].to_s
    end
      
    if tmp_attachments.size == 0
      if self.in_format == FORMAT_HTML
        mail.html_part = make_html_part(self.in_html_body)
        mail.text_part = make_text_part(self.in_body)
      else
        mail.body = encode_text_body(self.in_body)
      end
    else
      if self.in_format == FORMAT_HTML
        html_part = make_html_part(self.in_html_body) 
        text_part = make_text_part(self.in_body)
        alt_part = Mail::Part.new
        alt_part.content_type "multipart/alternative"
        alt_part.add_part(html_part)
        alt_part.add_part(text_part)
        mail.add_part(alt_part)
      else
        mail.text_part = make_text_part(self.in_body)
      end
      tmp_attachments.each do |f|
        name = f.name
        name = NKF.nkf('-WjM', name).split.join if @charset.downcase == 'iso-2022-jp'
        name = NKF.nkf('-WwM', name).split.join if @charset.downcase == 'utf-8'
        mail.attachments[name] = {
          :content => [f.read].pack('m'),
          :content_type => %Q(#{f.mime_type}; name="#{name}"),
          :encoding => 'base64'
        }
      end
      mail.attachments.each {|p| extend_content_type_field(p['content-type'].field) }
    end
    mail
  end

  def prepare_mdn(original, send_mode = 'manual', request = nil)
    mail = Mail.new    
    mail.charset = @charset
    from = parse_address(in_from)[0]
    mail.from = from
    mail.to = original.disposition_notification_to_addrs[0]
    mail.content_type = "multipart/report; report-type=disposition-notification"

    mail["X-Mailer"]  = "Joruri Mail ver. #{Joruri.version}"
    mail["User-Agent"] = request.user_agent if request
    
    mail.subject = mime_encode("開封済み : #{original.subject.gsub(/\r\n|\n/, ' ')}", false)
    extend_subject_field(mail.header['subject'].field)
    
    #第１パート
    body1 = "次のユーザーに送信されたメッセージの開封確認です:\r\n" +
      "#{original.friendly_from_addr} : #{original.date('%Y/%m/%d %H:%M')}\r\n\r\n" +
      "メッセージが、次の時間に開封されました : #{Time.now.strftime('%Y/%m/%d %H:%M')}"
    mail.text_part = make_text_part(body1)
    
    #第２パート
    original_recipient = original.mail.header['original-recipient']
    if send_mode == 'auto'
      mode = 'automatically'
    else
      mode = 'manually'
    end
    body2 = "Reporting-UA: #{mail["X-Mailer"]}\r\n"
    body2 += "Original-Recipient: #{original_recipient.value}" if original_recipient
    body2 += "Final-Recipient: rfc822; #{from.address}\r\n"
    body2 += "Original-Message-ID: <#{original.mail.message_id}>\r\n" if original.mail.message_id 
    body2 += "Disposition: manual-action/MDN-sent-#{mode}; displayed\r\n"

    part2 = Mail::Part.new
    part2.content_type = %Q(message/disposition-notification; name="ReportPart2.txt")
    part2.content_disposition = "inline"
    #part2.content_transfer_encoding = "7bit"
    part2.body = body2
    mail.add_part part2
    
    #第３パート
    part3 = Mail::Part.new
    part3.content_type = %Q(text/rfc822-headers; name="ReportPart3.txt")
    part3.content_disposition = "inline"
    #part3.content_transfer_encoding = "7bit"
    part3.body = original.mail.header.raw_source
    mail.add_part part3
    
    mail
  end
  
  def self.fetch(uids, mailbox, options = {})
    items = options[:items] || []
    return items if uids.blank?
    
    uids = [uids] if uids.class == Fixnum
    use_cache = options[:use_cache] || true
    
    imap.examine(mailbox)
    
    ## load cache
    if use_cache
      node = Gw::WebmailMailNode.new
      node.and :user_id, Core.current_user.id
      node.and :uid, 'IN', uids
      node.and :mailbox, mailbox
      if (nodes = node.find(:all)).size > 0
        nuids = nodes.collect {|n| n.uid }
        flags = {}
        msgs  = imap.uid_fetch(nuids, ["UID", "FLAGS"])
        msgs.each {|msg| flags[msg.attr['UID']] = msg.attr['FLAGS'] } if !msgs.blank?
        nodes.each do |n|
          item = self.new(n)
          item.flags = flags[n.uid]
          items << item
          uids.delete(n.uid)
        end
      end
      return items if uids.blank?
    end
    
    ## load imap
    #fields = ["UID", "FLAGS", "RFC822.SIZE", "BODY.PEEK[HEADER.FIELDS (DATE FROM TO CC BCC SUBJECT CONTENT-TYPE CONTENT-DISPOSITION DISPOSITION-NOTIFICATION-TO)]", "BODYSTRUCTURE"]
    fields = ["UID", "FLAGS", "RFC822.SIZE", "BODY.PEEK[HEADER.FIELDS (DATE FROM TO CC BCC SUBJECT CONTENT-TYPE CONTENT-DISPOSITION DISPOSITION-NOTIFICATION-TO)]"]
    msgs   = imap.uid_fetch(uids, fields)
    msgs.each do |msg|
      item = self.new
      header = msg.attr["BODY[HEADER.FIELDS (DATE FROM TO CC BCC SUBJECT CONTENT-TYPE CONTENT-DISPOSITION DISPOSITION-NOTIFICATION-TO)]"]
      #structure = self.encode_body_structure(msg.attr["BODYSTRUCTURE"], 0)
      #item.parse("#{header}#{structure}")
      item.parse("#{header}")
      item.uid     = msg.attr["UID"].to_i
      item.mailbox = mailbox
      item.size    = msg.attr['RFC822.SIZE']
      item.flags   = msg.attr["FLAGS"]
      if !use_cache
        items << item
        next
      end
      
      ## save cache
      node = Gw::WebmailMailNode.new({
        :user_id         => Core.current_user.id,
        :uid             => item.uid,
        :mailbox         => mailbox,
        :message_date    => item.date,
        :from            => item.friendly_from_addr,
        :to              => item.friendly_to_addrs.join("\n"),
        :cc              => item.friendly_cc_addrs.join("\n"),
        :bcc             => item.friendly_bcc_addrs.join("\n"),
        :subject         => item.subject,
        :has_attachments => item.has_attachments?,
        :size            => item.size,
        :has_disposition_notification_to => item.has_disposition_notification_to?
      })
      node.save
      node_item = self.new(node)
      node_item.flags = item.flags
      items << node_item
    end if !msgs.blank?
    
    items
  end

  def self.fetch_for_filter(uids, mailbox, options = {})
    items = []
    return items if uids.blank?
    
    uids = [uids] if uids.class == Fixnum
    imap.examine(mailbox)
        
    ## load imap
    fields = ["UID", "BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT)]"]
    msgs   = imap.uid_fetch(uids, fields)
    msgs.each do |msg|
      item = self.new
      item.parse(msg.attr["BODY[HEADER.FIELDS (FROM TO SUBJECT)]"])
      item.uid     = msg.attr["UID"].to_i
      item.mailbox = mailbox
      items << item
    end if !msgs.blank?    
    items
  end

  def parse_address(address)
    return [] if address.class != String
    addrs = []
    address.split(/\n|\t|,|;|、|，/).each do |a|
      next if (a = a.strip).blank?
      if pos = a.rindex('<')
        name = a.slice(0, pos).strip
        addr = a.slice(pos, a.size).strip
        ma = Mail::Address.new
        (ma.address = addr) rescue next
        ma.display_name = mime_encode(name, charset = @charset)
        addrs << ma rescue nil
      else
        addrs << Mail::Address.new(a) rescue nil
      end
    end
    addrs
  end
  
  def parse_raw_address(address)
    return [] if address.class != String
    addrs = []
    address.split(/\n|\t|,|;|、|，/).each do |a|
      if pos = a.rindex('<')
        name = a.slice(0, pos).strip
        addr = a.slice(pos, a.size).strip.gsub(/[<>]/, '')
        addrs << {:name => name, :address => addr, :friendly_address => a.strip} unless addr.blank?
      else
        addr = a.strip
        addrs << {:name => "", :address => addr, :friendly_address => addr} unless addr.blank?
      end
    end
    addrs
  end
  
  def for_save
    return nil unless @mail
    extend_bcc_field(@mail.header['bcc'].field)
    @mail  
  end
  
  def save_address_history
    addrs  = parse_raw_address(in_to)
    #addrs += parse_raw_address(in_cc)
    #addrs += parse_raw_address(in_bcc)
    
    addrs.each do |addr|
      item = Gw::WebmailMailAddressHistory.new(
        :user_id => Core.current_user.id, 
        :address => addr[:address], 
        :friendly_address => addr[:friendly_address]
      )
      item.save
    end
    
    max_count = Joruri.config.application['webmail.mail_address_history_max_count']
    curr_count = Gw::WebmailMailAddressHistory.count(:conditions => {:user_id => Core.current_user.id})
    
    if curr_count > max_count
      Gw::WebmailMailAddressHistory.connection.execute(
        "DELETE FROM gw_webmail_mail_address_histories 
          WHERE user_id = #{Core.current_user.id} ORDER BY created_at LIMIT #{curr_count - max_count}"
      )
    end
  end
  
protected
  def mime_encode(str, omit_space = true, charset = @charset)
    mime = nil
    mime = NKF.nkf('-WjM', str) if charset.downcase == 'iso-2022-jp'
    mime = NKF.nkf('-WwM', str) if charset.downcase == 'utf-8'
    mime = mime.split.join if mime && omit_space
    mime
  end
      
  def modify_html_body(html, charset = 'utf-8')
    %Q(<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">) +
    %Q(<html><head><meta http-equiv="content-type" content="text/html; charset=#{charset}"></head>) +
    %Q(<body>#{html}</body></html>)
  end
  
  def make_html_part(body, charset = @charset)
    part = Mail::Part.new
    part.content_type %Q(text/html; charset="#{charset}")
    body = encode_text_body(modify_html_body(body, charset), charset)
    part.body body
    part
  end
  
  def make_text_part(body, charset = @charset)
    part = Mail::Part.new
    part.content_type %Q(text/plain; charset="#{charset}")
    body = encode_text_body(body, charset)
    part.body body
    part
  end
  
  def encode_text_body(body, charset = @charset)
    return NKF.nkf("-Wj", body).force_encoding('us-ascii') if charset.downcase == 'iso-2022-jp'
    body
  end
  
  def self.encode_body_structure(struct, lv)
    return "" if !struct || lv > 5
    
    msg = ""
    if lv != 0 && struct.media_type && struct.subtype
      msg += "Content-Type: #{struct.media_type.downcase}/#{struct.subtype.downcase}"
      msg += ";" unless struct.param
      msg += "\r\n"
      if struct.param

        struct.param.each_with_index do |(key, value), index|
          if key == "BOUNDARY" || key == "NAME"
            msg += " #{key.downcase}=\"#{value}\""
          else
            msg += " #{key.downcase}=#{value}"
          end
          msg += ";" if index != struct.param.size - 1
          msg += "\r\n"
        end
        msg += "\r\n"
      end
    end
    if struct.multipart? && struct.parts && struct.param
      boundary = struct.param["BOUNDARY"]
      struct.parts.each do |part|
        msg += "--#{boundary}\r\n"
        msg += encode_body_structure(part, lv + 1)
        msg += "\r\n"
      end
      msg += "--#{boundary}--\r\n\r\n"
    end
    msg
  end
end

#module Mail
#  module CommonMessageId # :nodoc:
#    private
#    def do_encode(field_name)
#      return %Q{#{field_name}: #{message_ids.map { |m| "<#{m}>" }.join(' ')}\r\n} if field_name == "References"
#      %Q{#{field_name}: #{message_ids.map { |m| "<#{m}>" }.join(', ')}\r\n}
#    end
#  end
#end
