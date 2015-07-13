# encoding: utf-8
class Gw::Admin::Webmail::MailsController < Gw::Controller::Admin::Base
  include Sys::Controller::Scaffold::Base
  include Gw::Controller::Admin::Mobile::Mail
  helper Gw::MailHelper
  layout :select_layout
  
  def pre_dispatch
    return if params[:action] == 'status'
    return redirect_to :action => 'index' if params[:reset]
    
    if params[:src] == 'mailto'
      mailto = parse_mailto(params[:uri])
      return redirect_to new_gw_webmail_mail_path(mailto.merge(:mailbox => 'INBOX'))
    end
    
    @limit = 20
    @new_window = params[:new_window].blank? ? nil : 1
    @mail_form_size = Gw::WebmailSetting.user_config_value(:mail_form_size, 'medium') unless params[:action] == 'index'
    @mailbox = Gw::WebmailMailbox.load_mailbox(params[:mailbox] || 'INBOX')
    @filter = ["UNDELETED"]
    @sort = get_sort_params(@mailbox.name)
  rescue => e
    rescue_mail(e)
  end
  
  def load_mailboxes
    load_starred_mails
    reload = flash[:gw_webmail_load_mailboxes]
    flash.delete(:gw_webmail_load_mailboxes)
    Gw::WebmailMailbox.load_quota(reload)
    Gw::WebmailMailbox.load_mailboxes(reload)
  end
  
  def reset_mailboxes(mailboxes = [:all])
    flash[:gw_webmail_load_mailboxes] = mailboxes.uniq
  end
  
  def load_starred_mails
    Util::Database.lock_by_name(Core.current_user.account) do
      cond = {:user_id => Core.current_user.id, :name => 'load_starred_mails'}
      setting = Gw::WebmailSetting.find(:first, :conditions => cond)
      if setting
        mailbox_uids = JSON.parse(setting.value) rescue {}
        Gw::WebmailSetting.delete_all(cond)
        Gw::WebmailMailbox.load_starred_mails(mailbox_uids)
      end
    end
  end
  
  def reset_starred_mails(mailbox_uids = {'INBOX' => :all})
    Util::Database.lock_by_name(Core.current_user.account) do
      cond = {:user_id => Core.current_user.id, :name => 'load_starred_mails'}
      setting = Gw::WebmailSetting.find(:first, :conditions => cond) || Gw::WebmailSetting.new(cond)
      hash = JSON.parse(setting.value) rescue {}
      mailbox_uids.each do |mailbox, uids|
        hash[mailbox] ||= []
        hash[mailbox] = (hash[mailbox] + uids).uniq
      end
      setting.value = hash.to_json
      setting.save
    end
  end
  
  def load_quota
    Gw::WebmailMailbox.load_quota
  end
  
  def index
    return empty if params[:do] == 'empty'
    
    confs = Gw::WebmailSetting.user_config_values(
      [:mails_per_page, :mail_form_size, :mail_list_from_address, :mail_list_subject, :mail_open_window, :mail_address_history])
    @limit = confs[:mails_per_page].blank? ? 20 : confs[:mails_per_page].to_i if !request.mobile?
    @mail_form_size = confs[:mail_form_size].blank? ? 'medium' : confs[:mail_form_size]
    @mail_list_from_address = confs[:mail_list_from_address]
    @mail_list_subject = confs[:mail_list_subject]
    @mail_open_window = confs[:mail_open_window]
    @mail_address_history = confs[:mail_address_history].blank? ? 10 : confs[:mail_address_history].to_i
    @label_confs = Gw::WebmailSetting.load_label_confs
    
    ## apply filters
    last_uid, recent, error = Gw::WebmailFilter.apply_recents
    reset_mailboxes([:all]) if recent
    if @mailbox.name == "INBOX"
      @filter += ["UID", "1:#{last_uid}"] # slows a little
    end
    if error
      flash.now[:notice] ||= ""
      flash.now[:notice]  += "（フィルタ処理がタイムアウトしました。）"
    end
    
    ## search
    filter = make_search_filter
    
    @s_params = make_search_params
    
    @mailboxes = load_mailboxes
    @quota = load_quota
    @addr_histories = load_address_histories(@mail_address_history) if @mail_address_history != 0
    
    @items = Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => filter,
      :sort => @sort, :page => params[:page], :limit => @limit)
    
    if params[:sort_starred] == '1'
      @starred_items = Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => filter + " FLAGGED",
        :sort => @sort, :page => params[:page], :limit => @limit)
      if @starred_items.size < @limit
        @unstarred_items = Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => filter + " UNFLAGGED",
          :sort => @sort, :page => params[:page], :limit => @limit - @starred_items.size)
      else
        @unstarred_items = []
      end
    end
  end
  
  def show
    @item  = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return error_auth unless @item
    
    confs = Gw::WebmailSetting.user_config_values([:mail_attachment_view, :mail_address_history])
    @mail_attachment_view = confs[:mail_attachment_view]
    @mail_address_history = confs[:mail_address_history].blank? ? 10 : confs[:mail_address_history].to_i
    @label_confs = Gw::WebmailSetting.load_label_confs
    
    if params[:download] == "eml"
      filename = @item.subject + ".eml"
      filename = filename.gsub(/[\/\<\>\|:"\?\*\\]/, '_') 
      filename = URI::escape(filename) if request.env['HTTP_USER_AGENT'] =~ /MSIE/
      msg = @item.rfc822 || @item.mail.to_s
      return send_data(msg, :filename => filename,
        :type => 'message/rfc822', :disposition => 'attachment')
    elsif params[:download] == 'all'
      return download_all_attachments
    elsif params[:download]
      return download_attachment(params[:download])
    elsif params[:header]
      msg = @item.rfc822 || @item.mail.to_s
      msg = msg.slice(0, msg.index("\r\n\r\n"))
      return send_data(msg.gsub(/\r\n/m, "\n"),
        :type => 'text/plain; charset=utf-8', :disposition => 'inline')
    elsif params[:source]
      msg = @item.rfc822 || @item.mail.to_s
      return send_data(msg.gsub(/\r\n/m, "\n"),
        :type => 'text/plain; charset=utf-8', :disposition => 'inline')
    elsif params[:show_html_image]
      return http_error(404) unless @item.html_mail?
      return respond_to do |format|
        format.xml { render :action => 'show_html' }
      end
    elsif params[:show_thumbnail_image]
      return render :action => 'show_thumbnail'
    end
    
    Core.title += " - #{@item.subject} - #{Core.current_user.email}"
    
    if @item.html_mail?
      @html_mail_view = Gw::WebmailSetting.user_config_value(:html_mail_view, 'html')
    end

    if from = @item.parse_address(@item.friendly_from_addr).first
      @from_addr = CGI.escapeHTML(from.address)
      @from_name = ::NKF::nkf('-wx --cp932', from.name).gsub(/\0/, "") if from.name rescue nil
      @from_name = CGI.escapeHTML(@from_name || @from_addr)
    end rescue nil
    
    
    if @item.draft? && @item.mail.header[:bcc].blank? && @item.node
      @item.mail.header[:bcc] = @item.node.bcc
    end
    
    if @item.unseen?
      changed_mailboxes = []
      mailbox_uids = get_mailbox_uids(@mailbox, @item.uid)
      mailbox_uids.each do |mailbox, uids|
        num = Gw::WebmailMail.seen_all(mailbox, uids)
        if num > 0
          changed_mailboxes << mailbox
        end
      end
      reset_mailboxes(changed_mailboxes)
      
      @seen_flagged = true
      
      if @item.has_disposition_notification_to? && !@item.notified? && !@mailbox.draft_box?(:all) && !@mailbox.sent_box?(:all)
        @mdnRequest = mdn_request_mode
        if @mdnRequest && @mdnRequest == :auto
          begin
            send_mdn_message(@mdnRequest)
          rescue => e
            flash.now[:notice] = "開封確認メールの自動送信に失敗しました。"
          end
        end
      end
    end
    
    @mailboxes  = load_mailboxes
    
    filter = make_search_filter
    
    @s_params = make_search_params
    
    cond        = { :select => @mailbox.name, :conditions => filter, :sort => @sort, :sort_starred => params[:sort_starred] }
    @pagination = @item.single_pagination(params[:id], cond)
    
    @addr_histories = load_address_histories(@mail_address_history) if @mail_address_history != 0
    
    _show @item
  end
  
  def download_all_attachments
    zipdata = ""
    Zip::Archive.open_buffer(zipdata, Zip::CREATE, Zip::NO_COMPRESSION) do |ar|
      filenames = @item.attachments.map {|at| at.name}
      filenames = unique_filenames(filenames)
      @item.attachments.each_with_index do |at, i|
        begin
          filename = filenames[i]
          filename = filename.gsub(/[\/\<\>\|:;"\?\*\\]/, '_')
          filename = filename.encode(Encoding::Windows_31J, :invalid => :replace, :undef => :replace, :replace => '_') if request.user_agent =~ /Windows/
          ar.add_buffer(filename, at.body)
        rescue Zip::Error => e
          # e
        end
      end
    end
    
    subject = @item.subject.gsub(/[\/\<\>\|:;"\?\*\\\r\n]/, '_')
    subject = subject.match(/^.{100}/).to_s if subject.length > 100
    subject = URI::escape(subject) if request.user_agent =~ /MSIE/
    filename = sprintf("%07d_%s.zip", @item.uid, subject)
    send_data(zipdata, :type => 'application/zip', :filename => filename, :disposition => 'attachment')
  end
  
  def download_attachment(no)
    return http_error(404) unless no =~ /^[0-9]+$/
    return http_error(404) unless @file = @item.attachments[no.to_i]
    #return http_error(404) unless @file.name == params[:filename]
    
    filedata     = @file.body
    content_type = @file.content_type
    disposition  = params[:disposition] ? params[:disposition] : (@file.image? ? 'inline' : 'attachment')
    if !params[:thumbnail].blank? && data = @file.thumbnail(:width => params[:width] || 64, :height => params[:height] || 64, :format => :JPEG, :quality=> 70)
      filedata = data
      content_type = 'image/jpeg'
    end
    
    filename = convert_to_download_filename(@file.name)
    
    send_data(filedata, :type => content_type, :filename => filename, :disposition => disposition)
  end
  
  def new
    return false if no_email?
    @form_action = "create"
    
    @item = Gw::WebmailMail.new
    @item.tmp_id  = Sys::File.new_tmp_id
    if default_template
      @item.in_to      = default_template.to
      @item.in_cc      = default_template.cc
      @item.in_bcc     = default_template.bcc
      @item.in_subject = default_template.subject
      @item.in_body    = default_template.body
    end
    if default_sign_body
      @item.in_body  ||= ""
      @item.in_body   += "\n\n#{default_sign_body}"
    end
    
    load_address_from_flash
    
    @item.in_to      = NKF::nkf('-w', params[:to]) if params[:to]
    @item.in_cc      = NKF::nkf('-w', params[:cc]) if params[:cc]
    @item.in_bcc     = NKF::nkf('-w', params[:bcc]) if params[:bcc]
    @item.in_subject = NKF::nkf('-w', params[:subject]) if params[:subject]
    @item.in_body    = "#{NKF::nkf('-w', params[:body])}\n\n#{@item.in_body}" if params[:body]
    
    @item.in_format = Gw::WebmailMail::FORMAT_TEXT 
    
    #@mailboxes  = load_mailboxes
  end
  
  def edit
    return false if no_email?
    @form_action = "update"
    @form_method = "put"
    
    @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return http_error(404) unless @ref
    ref_node = @ref.find_node
    
    @item = Gw::WebmailMail.new(params[:item])
    @item.tmp_id     = Sys::File.new_tmp_id
    @item.in_to      = @ref.friendly_to_addrs.join(',')
    @item.in_cc      = @ref.friendly_cc_addrs.join(',')
    @item.in_bcc     = @ref.friendly_bcc_addrs.join(',')
    @item.in_bcc     = ref_node.bcc if @item.in_bcc.blank? && ref_node 
    @item.in_subject = @ref.subject
    if params[:mail_view] == Gw::WebmailMail::FORMAT_HTML && @ref.html_mail?
      @item.in_html_body = @ref.html_body_for_edit
      @item.in_format    = Gw::WebmailMail::FORMAT_HTML         
    else
      @item.in_body      = @ref.text_body
      @item.in_format    = Gw::WebmailMail::FORMAT_TEXT     
    end
    @item.request_mdn = 1 if @ref.has_disposition_notification_to?
    
    load_address_from_flash
    
    load_attachments(@ref, @item)
    
    #@mailboxes  = load_mailboxes
    render(:action => :new)
  end
  
  def answer
    return false if no_email?
    
    @form_action = "answer"
    
    @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return http_error(404) unless @ref
    
    @item = Gw::WebmailMail.new(params[:item])
    @item.reference = @ref
    
    if request.post?
      return send_message(@item, @ref) do
        mailbox_uids = get_mailbox_uids(@mailbox, @ref.uid)
        mailbox_uids.each do |mailbox, uids|
          Core.imap.select(mailbox)
          Core.imap.uid_store(uids, "+FLAGS", [:Answered])
        end
      end
    end
    
    @item.tmp_id     = Sys::File.new_tmp_id
    @item.in_to      = @ref.friendly_reply_to_addrs(!params[:all].blank?).join(', ')
    @item.in_subject = "Re: " + @ref.subject
    
    if params[:mail_view] == Gw::WebmailMail::FORMAT_HTML && @ref.html_mail?
      quot_body = "<p style=\"margin:0px; padding:0px;\"></p>#{@ref.referenced_html_body}" if params[:qt]
      sign_body = Util::String.text_to_html("\n" + default_sign_body) if default_sign_body
      @item.in_html_body = concat_mail_body(quot_body, sign_body)
      @item.in_format = Gw::WebmailMail::FORMAT_HTML
    else
      quot_body = "\n\n#{@ref.referenced_body}" if params[:qt]
      sign_body = "\n\n#{default_sign_body}" if default_sign_body
      @item.in_body = concat_mail_body(quot_body, sign_body)
      @item.in_format = Gw::WebmailMail::FORMAT_TEXT
    end
    
    if params[:all]
      @item.in_cc = @ref.friendly_cc_addrs.join(', ')
    end
    
    load_address_from_flash
    
    #@mailboxes  = load_mailboxes
    render(:action => :new)
  end
  
  def forward
    return false if no_email?
    
    @form_action = "forward"
    
    @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return http_error(404) unless @ref
    
    @item = Gw::WebmailMail.new(params[:item])
    
    if request.post?
      return send_message(@item, @ref) do
        mailbox_uids = get_mailbox_uids(@mailbox, @ref.uid)
        mailbox_uids.each do |mailbox, uids|
          Core.imap.select(mailbox)
          Core.imap.uid_store(uids, "+FLAGS", "$Forwarded")
        end
      end
    end
    
    @item.tmp_id      = Sys::File.new_tmp_id
    @item.in_subject  = "Fw: " + @ref.subject
    
    if params[:mail_view] == Gw::WebmailMail::FORMAT_HTML && @ref.html_mail?
      quot_body = "<p style=\"margin:0px; padding:0px;\"></p>#{@ref.referenced_html_body(:forward)}"
      sign_body = Util::String.text_to_html("\n" + default_sign_body) if default_sign_body  
      @item.in_html_body = concat_mail_body(quot_body, sign_body)
      @item.in_format = Gw::WebmailMail::FORMAT_HTML    
    else
      quot_body = "\n\n#{@ref.referenced_body(:forward)}"
      sign_body = "\n\n#{default_sign_body}" if default_sign_body
      @item.in_body = concat_mail_body(quot_body, sign_body) 
      @item.in_format = Gw::WebmailMail::FORMAT_TEXT      
    end
    
    load_address_from_flash
    
    load_attachments(@ref, @item)
    
    #@mailboxes  = load_mailboxes
    render(:action => :new)
  end

  def resend
    return false if no_email?
    
    @form_action = "create"
    
    @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return http_error(404) unless @ref
    
    @item = Gw::WebmailMail.new
    @item.tmp_id     = Sys::File.new_tmp_id
    @item.in_to      = @ref.friendly_to_addrs.join(', ')
    @item.in_cc      = @ref.friendly_cc_addrs.join(', ')
    @item.in_bcc     = @ref.friendly_bcc_addrs.join(', ')
    @item.in_subject = @ref.subject
    if params[:mail_view] == Gw::WebmailMail::FORMAT_HTML && @ref.html_mail?
      @item.in_html_body = @ref.html_body
      @item.in_format = Gw::WebmailMail::FORMAT_HTML
    else
      @item.in_body = @ref.text_body
      @item.in_format = Gw::WebmailMail::FORMAT_TEXT
    end
    @item.request_mdn = 1 if @ref.has_disposition_notification_to?
    
    load_address_from_flash
    
    load_attachments(@ref, @item)
    
    render(:action => :new)
  end

  def create
    return false if no_email?
    @form_action = "create"
    
    if params[:id] && params[:id] != '0' 
      @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
      return http_error(404) unless @ref
    end
    
    @item = Gw::WebmailMail.new(params[:item])
    send_message(@item, @ref) do
      if !params[:remain_draft] && @ref && (@mailbox.draft_box?(:all) || @mailbox.star_box?)
        mailbox_uids = get_mailbox_uids(@mailbox, @ref.uid)
        mailbox_uids.each do |mailbox, uids|
          num = Gw::WebmailMail.delete_all(mailbox, uids, true)
          if num > 0
            Gw::WebmailMailNode.delete_nodes(mailbox, uids)
          end
        end
      end
    end
  end
  
  def update
    return false if no_email?
    @form_action = "update"
    @form_method = "put"
    
    @ref = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return http_error(404) unless @ref
    
    @item = Gw::WebmailMail.new(params[:item])
    send_message(@item, @ref) do
      Gw::WebmailMailNode.delete_nodes(@mailbox.name, @ref.uid)
      @ref.destroy(true)
    end
  end
  
  def send_message(item, ref, &block)
    config = Gw::WebmailSetting.user_config_value(:mail_from)
    ma = Mail::Address.new
    ma.address      = Core.current_user.email
    ma.display_name = Core.current_user.name if config != "only_address"
    item.in_from = ma.to_s
    
    ## submit/file
    if !params[:commit_file].blank?
      item.valid?(:file)
      return render(:action => :new)
    end
    
    ## submit/destroy
    if !params[:commit_destroy].blank?
      item.delete_tmp_attachments
      return redirect_to(:action => :close)
    end
    
    
    ## submit/draft
    if !params[:commit_draft].blank?
      unless item.valid?(:draft)
        #@mailboxes  = load_mailboxes
        return render(:action => :new)
      end
      return save_as_draft(item, ref, &block)
    end
    
    ## submit/send
    unless item.valid?(:send)
      #@mailboxes  = load_mailboxes
      return render(:action => :new)
    end
    
    begin
      mail = item.prepare_mail(request)
      mail.delivery_method(:smtp, ActionMailer::Base.smtp_settings)
      sent = mail.deliver
      item.delete_tmp_attachments
      item.save_address_history
      #flash[:notice] = 'メールを送信しました。'.html_safe
    rescue => e
      #@mailboxes  = load_mailboxes
      flash.now[:error] = "メールの送信に失敗しました。（#{e}）"
      respond_to do |format|
        format.html { render :action => :new }
        format.xml  { render :xml => item.errors, :status => :unprocessable_entity }
      end
      return
    end
    
    yield if block_given?
    
    ## save to 'Sent'
    begin
      imap = Core.imap
      imap.create("Sent") unless imap.list("", "Sent") rescue nil
      #imap.create("Sent") unless Gw::WebmailMailbox.exist?("Sent") rescue nil
      item.mail = sent
      timeout(60) { imap.append("Sent", item.for_save.to_s, [:Seen], Time.now) }
    rescue => e
      #flash[:notice] += "<br />送信トレイへの保存に失敗しました。（#{e}）".html_safe
      flash[:error] = "メールは送信できましたが、送信トレイへの保存に失敗しました。（#{e}）"
    end
    
    status         = params[:_created_status] || :created
    location       = url_for(:action => :close)
    respond_to do |format|
      format.html { redirect_to(location) }
      format.xml  { render :xml => item.to_xml(:dasherize => false), :status => status, :location => location }
    end
  end
  
  def save_as_draft(item, ref, &block)
    begin
      mail = item.prepare_mail(request)
      imap = Core.imap
      imap.create("Drafts") unless imap.list("", "Drafts") rescue nil
      #imap.create("Drafts") unless Gw::WebmailMailbox.exist?("Drafts") rescue nil
      #next_uid = imap.status("Drafts", ["UIDNEXT"])["UIDNEXT"]
      item.mail = mail
      flags = [:Seen, :Draft]
      flags << :Flagged if ref && ref.starred?
      timeout(30) { imap.append("Drafts", item.for_save.to_s, flags, Time.now) }
      item.delete_tmp_attachments
      
      ## save bcc
      #if mail = Gw::WebmailMail.find(:all, :select => "Drafts", :conditions => ["UID", next_uid]).first
      #  if mail.node.subject == item.in_subject && !item.in_bcc.blank?
      #    mail.node.bcc = item.in_bcc
      #    mail.node.save
      #  end
      #end
      
      yield if block_given?
    rescue => error
      #@mailboxes  = load_mailboxes
      item.errors.add :base, "下書き保存に失敗しました。（#{error}）"
      flash.now[:notice] = "下書き保存に失敗しました。（#{error}）"
      respond_to do |format|
        format.html { render :action => :new }
        format.xml  { render :xml => item.errors, :status => :unprocessable_entity }
      end
      return
    end
    
    #flash[:notice] = '下書きに保存しました。'
    status         = params[:_created_status] || :created
    location       = url_for(:action => :close)
    respond_to do |format|
      format.html { redirect_to(location) }
      format.xml  { render :xml => item.to_xml(:dasherize => false), :status => status, :location => location }
    end
  end
  
  def destroy
    @item  = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return error_auth unless @item
    
    changed_num = 0
    changed_mailbox_uids = {}
    
    mailbox_uids = get_mailbox_uids(@mailbox, @item.uid)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.delete_all(mailbox, uids)
      if num > 0
        Gw::WebmailMailNode.delete_nodes(mailbox, uids)
        changed_mailbox_uids['Trash'] = [:all]
      end
      changed_num += num if mailbox !~ /^(Star)$/
    end
    
    if changed_num > 0
      reset_mailboxes([:all])
      reset_starred_mails(changed_mailbox_uids) if @item.starred?
      
      flash[:notice] = 'メールを削除しました。' unless @new_window
      respond_to do |format|
        format.html do
          action = @new_window ? :close : :index
          redirect_to url_for(:action => action)
        end
        format.xml  { head :ok }
      end
    else
      flash[:error] = 'メールの削除に失敗しました。'
      respond_to do |format|
        format.html do
          action = @new_window ? :close : :index
          redirect_to url_for(:action => action)
        end
        format.xml  { render :xml => @item.errors, :status => :unprocessable_entity }
      end
    end
  end
  
  ## move_all or move_one
  def move
    if !params[:item] || !params[:item][:ids]
      return redirect_to(url_for(:action => :index, :page => params[:page]))
    end
    
    uids = params[:item][:ids].collect{|k, v| k.to_s =~ /^[0-9]+$/ ? k.to_i : nil }
    cond = ["UID", uids] + @filter
    
    if !params[:item][:mailbox]
      @items = Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => cond)
      @mailboxes = load_mailboxes
      
      confs = Gw::WebmailSetting.user_config_values([:mail_address_history])
      @mail_address_history = confs[:mail_address_history].blank? ? 10 : confs[:mail_address_history].to_i
      @addr_histories = load_address_histories(@mail_address_history) if @mail_address_history != 0
      
      return render :template => 'gw/admin/webmail/mails/move'
    end
    
    changed_num = 0
    changed_mailbox_uids = {}
    include_starred_uid = Gw::WebmailMail.include_starred_uid?(@mailbox.name, uids)
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      if mailbox =~ /^(Star)$/
        num = 0
        if params[:copy].blank? #move
          num = Gw::WebmailMail.delete_all(mailbox, uids, true)
          Gw::WebmailMailNode.delete_nodes(mailbox, uids) if num > 0
        end
      else
        if params[:copy].blank? #move
          num = Gw::WebmailMail.move_all(mailbox, params[:item][:mailbox], uids)
          Gw::WebmailMailNode.delete_nodes(mailbox, uids) if num > 0
        else
          num = Gw::WebmailMail.copy_all(mailbox, params[:item][:mailbox], uids)
        end
        changed_num += num
      end
      if num > 0
        changed_mailbox_uids[params[:item][:mailbox]] = [:all]
      end
    end
    
    reset_mailboxes([:all])
    reset_starred_mails(changed_mailbox_uids) if include_starred_uid
    
#    num = 0
#    Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => cond).each do |item|
#      num += 1 if item.move(params[:item][:mailbox])
#    end
    
    label = params[:copy].blank? ? '移動' : 'コピー'
    flash[:notice] = "#{changed_num}件のメールを#{label}しました。".force_encoding('utf-8') unless @new_window
    action = @new_window ? :close : :index
    redirect_to url_for(:action => action, :page => params[:page])
  end
  
  ## destroy_all
  def delete
    if !params[:item] || !params[:item][:ids]
      return redirect_to url_for(:action => :index, :page => params[:page])
    end
    
    uids = params[:item][:ids].collect{|k, v| k.to_s =~ /^[0-9]+$/ ? k.to_i : nil }
    
    changed_num = 0
    changed_mailbox_uids = {}
    include_starred_uid = Gw::WebmailMail.include_starred_uid?(@mailbox.name, uids)
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.delete_all(mailbox, uids)
      if num > 0
        Gw::WebmailMailNode.delete_nodes(mailbox, uids)
        changed_mailbox_uids['Trash'] = [:all]
      end
      changed_num += num if mailbox !~ /^(Star)$/
    end
    
    reset_mailboxes([:all])
    reset_starred_mails(changed_mailbox_uids) if include_starred_uid
    
#    Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => cond).each do |item|
#      num += 1 if item.destroy
#    end
    
    flash[:notice] = "#{changed_num}件のメールを削除しました。".force_encoding('utf-8')
    redirect_to url_for(:action => :index, :page => 1) #params[:page]
  end
  
  def seen
    if !params[:item] || !params[:item][:ids]
      return redirect_to url_for(:action => :index, :page => params[:page])
    end
    
    uids = params[:item][:ids].collect{|k, v| k.to_s =~ /^[0-9]+$/ ? k.to_i : nil }
    
    changed_num = 0
    changed_mailboxes = []
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.seen_all(mailbox, uids)
      if num > 0
        changed_mailboxes << mailbox
        changed_mailboxes << 'Star'
      end
      changed_num += num if mailbox !~ /^(Star)$/
    end
    
    reset_mailboxes(changed_mailboxes)
    
    flash[:notice] = "#{changed_num}件のメールを既読にしました。".force_encoding('utf-8')
    redirect_to url_for(:action => :index, :page => params[:page])
  end
  
  def unseen
    if !params[:item] || !params[:item][:ids]
      return redirect_to url_for(:action => :index, :page => params[:page])
    end
    
    uids = params[:item][:ids].collect{|k, v| k.to_s =~ /^[0-9]+$/ ? k.to_i : nil }
    
    changed_num = 0
    changed_mailboxes = []
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.unseen_all(mailbox, uids)
      if num > 0
        changed_mailboxes << mailbox
      end
      changed_num += num if mailbox !~ /^(Star)$/
    end
    
    reset_mailboxes(changed_mailboxes)
    
    flash[:notice] = "#{changed_num}件のメールを未読にしました。".force_encoding('utf-8')
    redirect_to url_for(:action => :index, :page => params[:page])
  end
  
  def empty
    reset_mailboxes([:all])
    changed_mailbox_uids = {}
    
    mailboxes = load_mailboxes
    mailboxes.reverse.each do |box|
      if box.trash_box?(:children)
        begin
          Gw::WebmailMailNode.delete_nodes(box.name)
          Core.imap.delete(box.name)
          
          uids = Gw::WebmailMailNode.find_ref_nodes(box.name).map{|x| x.uid}
          num = Gw::WebmailMail.delete_all('Star', uids)
          if num > 0
            Gw::WebmailMailNode.delete_ref_nodes(box.name)
            changed_mailbox_uids[box.name] = [:all]
          end
        rescue => e
        end
      end
    end
    
    Core.imap.select(@mailbox.name)
    uids = Core.imap.uid_search(@filter, "utf-8")
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.delete_all(mailbox, uids, true)
      if num > 0
        Gw::WebmailMailNode.delete_nodes(mailbox, uids)
        changed_mailbox_uids[mailbox] = [:all]
      end
    end
    
    reset_mailboxes([:all])
    reset_starred_mails(changed_mailbox_uids)
    
    flash[:notice] = "ごみ箱を空にしました。"
    respond_to do |format|
      format.html { redirect_to url_for(:action => :index) }
      format.xml  { head :ok }
    end
  end
  
  def send_mdn
    @item = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return error_auth unless @item && @item.has_disposition_notification_to?

    if params[:mobile]
      begin
        send_mdn_message(params[:send_mode])
        flash[:notice] = "開封確認メールを送信しました。"
      rescue => e
        flash[:notice] = "開封確認メールの送信に失敗しました。"
      end
      return redirect_to url_for(:action => :show)
    else
      send_mdn_message(params[:send_mode])
    end
  end
  
  def reset_address_history
    Gw::WebmailMailAddressHistory.delete_all(:user_id => Core.current_user.id)
    
    flash[:notice] = 'クイックアドレス帳をリセットしました。'
    redirect_to url_for(:action => :index, :page => params[:page])
  end
  
  def register_spam
    if !params[:item] || !params[:item][:ids]
      return redirect_to url_for(:action => :index, :page => params[:page])
    end
    
    uids = params[:item][:ids].collect{|k, v| k.to_s =~ /^[0-9]+$/ ? k.to_i : nil }
    cond = ["UID", uids] + @filter
    items = Gw::WebmailMail.find(:all, :select => @mailbox.name, :conditions => cond, :sort => @sort)
    
    if items.count == 0
      return redirect_to url_for(:action => :index, :page => params[:page])
    end
    
    Gw::WebmailFilter.register_spams(items)
    
    changed_num = 0
    changed_mailbox_uids = {}
    include_starred_uid = Gw::WebmailMail.include_starred_uid?(@mailbox.name, uids)
    
    mailbox_uids = get_mailbox_uids(@mailbox, uids)
    mailbox_uids.each do |mailbox, uids|
      num = Gw::WebmailMail.delete_all(mailbox, uids)
      if num > 0
        Gw::WebmailMailNode.delete_nodes(mailbox, uids)
        changed_mailbox_uids['Trash'] = [:all]
      end
      changed_num += num if mailbox !~ /^(Star)$/
    end
    
    reset_mailboxes([:all])
    reset_starred_mails(changed_mailbox_uids) if include_starred_uid
    
    flash[:notice] = "#{items.count}件のメールを迷惑メールに登録しました。"
    redirect_to url_for(:action => :index, :page => params[:page])
  end
  
  def star
    @item  = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return error_auth unless @item
    
    starred = @item.starred?
    changed_mailbox_uids = {}
    
    mailbox_uids = get_mailbox_uids(@mailbox, @item.uid)
    mailbox_uids.each do |mailbox, uids|
      if starred
        num = Gw::WebmailMail.unstar_all(mailbox, uids)
      else
        num = Gw::WebmailMail.star_all(mailbox, uids)
      end
      if num > 0
        changed_mailbox_uids[mailbox] = uids
      end
    end
    
    reset_mailboxes([:all])
    reset_starred_mails(changed_mailbox_uids)
    
    if request.mobile? && !request.smart_phone?
      s_params = make_search_params
      if params[:from] == 'list' || @mailbox.name =~ /^(Star)$/
        redirect_to url_for(s_params.merge(:action => :index, :id => params[:id], :mailbox => @mailbox.name, :mobile => :list))
      else
        redirect_to url_for(s_params.merge(:action => :show, :id => params[:id], :mailbox => @mailbox.name))
      end
    else
      render :text => "OK"
    end
  end
  
  def label
    @item  = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    return error_auth unless @item
    
    @label_confs = Gw::WebmailSetting.load_label_confs
    
    label = params[:label].to_i
    labeled = @item.labeled?(label)
    
    mailbox_uids = get_mailbox_uids(@mailbox, @item.uid)
    mailbox_uids.each do |mailbox, uids|
      if label == 0
        Gw::WebmailMail.unlabel_all(mailbox, uids)
      elsif labeled
        Gw::WebmailMail.unlabel_all(mailbox, uids, label)
      else
        Gw::WebmailMail.label_all(mailbox, uids, label)
      end
    end
    
    @item  = Gw::WebmailMail.find_by_uid(params[:id], :select => @mailbox.name, :conditions => @filter)
    render :layout => false
  end
  
  def status
    imap_settings = Joruri.config.imap_settings
    smtp_settings = ActionMailer::Base.smtp_settings
    
    imap_sock = TCPSocket.open(imap_settings[:address], imap_settings[:port])
    smtp_sock = TCPSocket.open(smtp_settings[:address], smtp_settings[:port])
    if imap_sock && smtp_sock
      @status = "OK"
      if protect_against_forgery? && form_authenticity_token != form_authenticity_param
        @status = "NG TokenError"
      end
    end
    
  rescue => e
    @status = "NG"
  ensure
    imap_sock.close if imap_sock
    smtp_sock.close if smtp_sock
  end
  
protected

  def select_layout
    layout = "admin/gw/webmail"
    case params[:action].to_sym
    when :new, :edit, :answer, :forward, :close, :create, :update, :resend
      layout = "admin/gw/mail_form"
    when :show, :move
      unless params[:new_window].blank?
        layout = "admin/gw/mail_form"
      end
    end
    layout
  end
  
  def no_email?
    if Core.current_user.email.blank?
      error = "メールアドレスが登録されていません。"
      render(:text => error, :layout => true)
      return true
    end
    return nil
  end
  
  def default_sign_body
    return @default_sign.body if @default_sign
    if request.mobile?
      @default_sign = Gw::WebmailSign.new
    else
      @default_sign = (Gw::WebmailSign.default_sign || Gw::WebmailSign.new)
    end
    @default_sign.body
  end
  
  def default_template
    return @default_template if @default_template
    if request.mobile?
      @default_template = Gw::WebmailTemplate.new
    else
      @default_template = (Gw::WebmailTemplate.default_template || Gw::WebmailTemplate.new)
    end
    @default_template
  end
  
  def load_attachments(ref, item)
    if ref.has_attachments?
      ref.attachments.each do |f|
        file = Gw::WebmailMailAttachment.new({
          :tmp_id => item.tmp_id,
        })
        tmpfile = Sys::Lib::File::Tempfile.new({
          :data     => f.body,
          :filename => f.name
        })
        file.save_file(tmpfile) # pass the errors
      end
    end
  end
  
  def mdn_request_mode
    mdnRequest = :manual
    domain = Core.config['mail_domain']
    addrs = @item.disposition_notification_to_addrs
    begin
      if !domain.blank? && addrs && addrs.size > 0 &&
        addrs[0].address =~ /[@\.]#{Regexp.escape(domain)}$/i
        mdnRequest = :auto  
      end          
    rescue => e
      #Disposition-Notification-Toのパースエラー対策
      error_log(e)
      mdnRequest = nil
    end
    mdnRequest
  end
  
  def send_mdn_message(mdn_mode)
    mdn = Gw::WebmailMail.new
    mdn.in_from ||= %Q(#{Core.current_user.name} <#{Core.current_user.email}>)
    mail = mdn.prepare_mdn(@item, mdn_mode.to_s, request)
    mail.delivery_method(:smtp, ActionMailer::Base.smtp_settings)
    mail.deliver
    
    Core.imap.uid_store(@item.uid, "+FLAGS", "$Notified")
    @item.flags << "$Notified"
  end
  
  def load_address_from_flash
    @item.in_to  = flash[:mail_to] if flash[:mail_to]
    @item.in_cc  = flash[:mail_cc] if flash[:mail_cc]
    @item.in_bcc = flash[:mail_bcc] if flash[:mail_bcc]
    @item.in_subject = flash[:mail_subject] if flash[:mail_subject]
    @item.in_body = flash[:mail_body] if flash[:mail_body]
  end
  
  def concat_mail_body(quot_body, sign_body)
    sign_position = Gw::WebmailSetting.user_config_value(:sign_position)
    if sign_position.blank?
      "#{sign_body}#{quot_body}"
    else
      "#{quot_body}#{sign_body}"
    end
  end
  
  def get_sort_params(mailbox_name)
    key = params[:sort_key]
    order = params[:sort_order]
    
    unless key
      key = 'date'
      order = 'reverse'
    end
    
    params[:sort_key] = key
    params[:sort_order] = order
    
    sort_params = []
    sort_params += [order.upcase] if order.upcase != ""
    sort_params += [key.upcase]
    sort_params += ['REVERSE', 'DATE'] if key != 'date'
    sort_params
  end
  
  def make_search_params
    s_params = params.dup
    [:controller, :action, :mailbox].each {|n| s_params.delete(n) }
    s_params
  end
  
  def make_search_filter
    filter = @filter
    
    if params[:search]
      if !params[:s_status].blank?
        filter += ["UNSEEN"] if params[:s_status] == "unseen"
        filter += ["SEEN"]   if params[:s_status] == "seen"
      end
      if !params[:s_column].blank? && !params[:s_keyword].strip.blank?
        #keywords = []
        params[:s_keyword].gsub("　", " ").split(/ +/).each do |w|
          next if w.strip.blank?
          #keywords << %Q(#{params[:s_column]} "#{w.gsub('"', '\\"')}")
          filter << "#{params[:s_column].upcase}"
          filter << "\"#{w.gsub('"', '\\"')}\""
        end
        #filter = filter.join(' ') + " " + keywords.join(' ')
      end
      if !params[:s_label].blank?
        filter += ["KEYWORD $label#{params[:s_label]}"]
      end
    end
    
    if !params[:s_flag].blank?
      filter += ["FLAGGED"]   if params[:s_flag] == "starred"
      filter += ["UNFLAGGED"] if params[:s_flag] == "unstarred"
    end
    
    if params[:s_from]
      begin
        from_addr = nil
        from = Gw::WebmailMail.new.parse_address(params[:s_from]).first
        from_addr = from.address if from
      rescue => ex
        from_addr = nil
      end
      field = @mailbox.name =~ /^(Sent|Drafts)(\.|$)/ ? "TO" : "FROM"
      filter += [field, "\"#{from_addr.gsub(/"/, '')}\""] if from_addr
    end
    
    filter.join(' ')
  end
  
  def unique_filenames(filenames)
    uniques = []
    filenames.each do |filename|
      if uniques.include?(filename)
        for n in 1..255
          seq_filename = "#{File.basename(filename, ".*")}_#{n}#{File.extname(filename)}"
          unless uniques.include?(seq_filename)
            filename = seq_filename
            break
          end
        end
      end
      uniques << filename
    end
    return uniques
  end
  
  def parse_mailto(uri)
    mailto_params = Hash.new
    if uri
      begin
        [:to, :cc, :bcc, :subject, :body].each{|k| uri += "&#{k}=#{params[k]}" if params[k]}
        mailto = URI.parse(URI.escape(NKF::nkf('-w', uri)))
        if mailto.is_a?(URI::MailTo)
          mailto_params[:to] = URI.unescape(mailto.to)
          mailto.headers.each do |header|
            mailto_params[header[0].to_sym] = URI.unescape(header[1])
          end
        end
      rescue
      end
    end
    mailto_params
  end
  
  def load_address_histories(history_count)
    histories = Gw::WebmailMailAddressHistory.find(:all, 
      :select => 'count(*) as cnt, address, friendly_address', 
      :conditions => {:user_id => Core.current_user.id}, 
      :group => :address, :limit => history_count, :order => 'cnt DESC, created_at DESC')
    
    emails = histories.map{|x| x.address}
    
    domain = Core.config['mail_domain'] || ''
    sys_emails = histories.select{|x| x.address =~ /[@\.]#{Regexp.escape(domain)}$/i}.map{|x| x.address}
    
    addresses = Gw::WebmailAddress.find(:all, 
      :select => "email, name", :conditions => {:email => emails, :user_id => Core.current_user.id})
    sys_addresses = Sys::User.find(:all, 
      :select => "email, name", :conditions => {:email => sys_emails})
    
    histories.each do |history|
      if addr = addresses.find{|x| x.email == history.address}
        history.display_name = addr.name
      elsif addr = sys_addresses.find{|x| x.email == history.address}
        history.display_name = addr.name
      end
    end
    
    histories
  end
  
  def get_mailbox_uids(mailbox, uids)
    mailbox_uids = {}
    uids = [uids] if uids.is_a?(Fixnum)
    if mailbox.star_box?
      nodes = Gw::WebmailMailNode.find_nodes(mailbox.name, uids)
      nodes = nodes.select{|x| x.ref_mailbox && x.ref_uid}.group_by(&:ref_mailbox)
      nodes.each do |k,v| 
        mailbox_uids[k] = v.map{|x| x.ref_uid}
      end
    else
      nodes = Gw::WebmailMailNode.find_ref_nodes(mailbox.name, uids)
      nodes = nodes.group_by(&:mailbox)
      nodes.each do |k,v| 
        mailbox_uids[k] = v.map{|x| x.uid}
      end
    end
    mailbox_uids[mailbox.name] = uids
    mailbox_uids
  end
  
  def rescue_mail(e)
    @mailbox = Gw::WebmailMailbox.find(:first, :conditions => {:user_id => Core.current_user.id, :name => params[:mailbox] || 'INBOX'})
    raise e unless @mailbox
    
    if params[:mobile] && params[:mobile].is_a?(Hash)
      action = params[:mobile][:form_action]
    else
      action = params[:action]
    end
    
    case action
    when 'create'
      @form_action = "create"
    when 'update'
      @form_action = "update"
      @form_method = "put"
    when 'answer'
      @form_action = "answer"
    when 'forward'
      @form_action = "forward"
    when 'resend'
      @form_action = "create"
    else
      raise e
    end
    
    @item = Gw::WebmailMail.new(params[:item])
    flash.now[:error] = "エラーが発生しました。#{e}"
    render :action => :new
  end
end